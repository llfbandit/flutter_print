#include "include/flutter_print/flutter_print_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gtk/gtkunixprint.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/pwg.h>

#include "messages.h"

// ---------------------------------------------------------------------------
// GObject boilerplate
// ---------------------------------------------------------------------------

#define FLUTTER_PRINT_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_print_plugin_get_type(), \
                              FlutterPrintPlugin))

struct _FlutterPrintPlugin {
  GObject parent_instance;
  // Gives the Flutter view, to parent the print dialog.
  FlPluginRegistrar* registrar;
};

G_DEFINE_TYPE(FlutterPrintPlugin, flutter_print_plugin, g_object_get_type())

static void flutter_print_plugin_dispose(GObject* object) {
  g_clear_object(&FLUTTER_PRINT_PLUGIN(object)->registrar);
  G_OBJECT_CLASS(flutter_print_plugin_parent_class)->dispose(object);
}

static void flutter_print_plugin_class_init(FlutterPrintPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_print_plugin_dispose;
}

static void flutter_print_plugin_init(FlutterPrintPlugin* self) {}

// Returns true for formats CUPS typically cannot rasterise natively.
static bool needs_transcode(const char* path) {
  const char* dot = strrchr(path, '.');
  if (!dot) return false;
  return g_ascii_strcasecmp(dot, ".webp") == 0 ||
         g_ascii_strcasecmp(dot, ".heic") == 0 ||
         g_ascii_strcasecmp(dot, ".heif") == 0;
}

// Decode the image with GDK-Pixbuf and save it as a temporary PNG.
// Returns a heap-allocated file path on success (caller must g_free + unlink),
// or nullptr and sets |error|. GDK_PIXBUF_ERROR_UNKNOWN_TYPE means the
// pixbuf loader for the format is not installed.
static gchar* transcode_to_png(const char* path, GError** error) {
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_file(path, error);
  if (!pixbuf) return nullptr;

  // g_file_open_tmp creates a new file with a random name, so another user
  // can't plant a symlink at the path.
  g_autofree gchar* tmp = nullptr;
  int fd = g_file_open_tmp("flutter_print_XXXXXX.png", &tmp, error);
  if (fd < 0) return nullptr;
  close(fd);
  if (!gdk_pixbuf_save(pixbuf, tmp, "png", error, nullptr)) {
    g_remove(tmp);
    return nullptr;
  }
  return static_cast<gchar*>(g_steal_pointer(&tmp));
}

// ---------------------------------------------------------------------------
// Print / PrintPreview
// ---------------------------------------------------------------------------

// The CUPS "sides" value for the duplex mode in |options|, or nullptr when
// unset.
static const char* duplex_sides(FlutterPrintPrintOptions* options) {
  FlutterPrintDuplexMode* mode =
      options ? flutter_print_print_options_get_duplex_mode(options) : nullptr;
  if (!mode) return nullptr;
  switch (*mode) {
    case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_NONE:
      return "one-sided";
    case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_LONG_EDGE:
      return "two-sided-long-edge";
    case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_SHORT_EDGE:
      return "two-sided-short-edge";
  }
  return nullptr;
}

// The PWG media for the width and height of |page_size|, or nullptr when they
// are unset. Prefer it to the name: names like "B4" or "DL" are ambiguous or
// unknown to CUPS. pwgMediaForSize returns the standard size, or a custom one.
static pwg_media_t* media_for_size(FlutterPrintPageSize* page_size) {
  double* width  = flutter_print_page_size_get_width(page_size);
  double* height = flutter_print_page_size_get_height(page_size);
  if (!width || !height || *width <= 0 || *height <= 0) return nullptr;
  return pwgMediaForSize((int)(*width * 100 + 0.5), (int)(*height * 100 + 0.5));
}

// Formats the pageRanges of |options| as a CUPS "page-ranges" value
// (e.g. "2-6,9,15"). Returns a newly-allocated string the caller must g_free,
// or nullptr when the selection is unset or empty (print all pages).
static gchar* build_page_ranges(FlutterPrintPrintOptions* options) {
  FlValue* list =
      options ? flutter_print_print_options_get_page_ranges(options) : nullptr;
  if (!list || fl_value_get_type(list) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(list) == 0) {
    return nullptr;
  }
  GString* out = g_string_new(nullptr);
  for (size_t i = 0; i < fl_value_get_length(list); i++) {
    FlValue* item = fl_value_get_list_value(list, i);
    auto* range = FLUTTER_PRINT_PAGE_RANGE(fl_value_get_custom_value_object(item));
    if (!range) continue;
    int64_t start = flutter_print_page_range_get_start(range);
    int64_t end = flutter_print_page_range_get_end(range);
    if (out->len > 0) g_string_append_c(out, ',');
    if (start == end) {
      g_string_append_printf(out, "%" G_GINT64_FORMAT, start);
    } else {
      g_string_append_printf(out, "%" G_GINT64_FORMAT "-%" G_GINT64_FORMAT,
                             start, end);
    }
  }
  return g_string_free(out, out->len == 0);
}

// A print request. The job runs on a worker thread and responds on the main
// thread, so slow conversions or CUPS servers don't freeze the app.
typedef struct {
  gchar* file_path;
  FlutterPrintPrintOptions* options;  // May be null.
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
  const char* error_code;  // Null on success.
  gchar* error_message;
} PrintJob;

static void print_job_free(gpointer data) {
  PrintJob* job = static_cast<PrintJob*>(data);
  g_free(job->file_path);
  g_clear_object(&job->options);
  g_object_unref(job->response_handle);
  g_free(job->error_message);
  g_free(job);
}

static void print_job_fail(PrintJob* job, const char* code, gchar* message) {
  job->error_code = code;
  job->error_message = message;
}

// Runs on a worker thread.
static void print_file(PrintJob* job) {
  const gchar* file_path = job->file_path;
  FlutterPrintPrintOptions* options = job->options;

  if (!g_file_test(file_path, G_FILE_TEST_EXISTS)) {
    print_job_fail(job, "FILE_NOT_FOUND",
                   g_strdup_printf("File not found: %s", file_path));
    return;
  }

  // For formats CUPS cannot rasterise (WebP, HEIC), transcode to PNG first
  // using GDK-Pixbuf, which supports these formats when the system pixbuf
  // loaders are installed (webp-pixbuf-loader, heif-pixbuf-loader).
  g_autofree gchar* transcoded = nullptr;
  if (needs_transcode(file_path)) {
    g_autoptr(GError) err = nullptr;
    transcoded = transcode_to_png(file_path, &err);
    if (!transcoded) {
      bool unsupported =
          g_error_matches(err, GDK_PIXBUF_ERROR, GDK_PIXBUF_ERROR_UNKNOWN_TYPE);
      print_job_fail(job, unsupported ? "UNSUPPORTED_FILE" : "PRINT_ERROR",
                     g_strdup_printf("Cannot convert %s: %s", file_path,
                                     err->message));
      return;
    }
  }
  const char* print_path = transcoded ? transcoded : file_path;

  // cupsGetNamedDest applies lpoptions: the user's default printer and the
  // options saved for it. A null name returns the default printer.
  const gchar* printer_address =
      options ? flutter_print_print_options_get_printer_address(options) : nullptr;
  if (printer_address && printer_address[0] == '\0') printer_address = nullptr;
  cups_dest_t* dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, printer_address,
                                       nullptr);
  if (!dest) {
    if (transcoded) g_remove(transcoded);
    print_job_fail(job, "PRINTER_ERROR",
                   printer_address
                       ? g_strdup_printf("Unknown printer: %s", printer_address)
                       : g_strdup("No default printer"));
    return;
  }

  // Start from the printer's saved options; the caller's options override them.
  // options may be null when the caller omits them; then the printer's
  // settings apply.
  int num_options = 0;
  cups_option_t* cups_opts = nullptr;
  for (int i = 0; i < dest->num_options; i++) {
    num_options = cupsAddOption(dest->options[i].name, dest->options[i].value,
                                num_options, &cups_opts);
  }

  const int64_t* copies =
      options ? flutter_print_print_options_get_copies(options) : nullptr;
  if (copies && *copies > 1) {
    g_autofree gchar* s = g_strdup_printf("%" G_GINT64_FORMAT, *copies);
    num_options = cupsAddOption("copies", s, num_options, &cups_opts);
  }

  // Use the IPP-standard attribute (3=portrait, 4=landscape) instead of the
  // legacy CUPS-only "landscape" shorthand.
  const gboolean* landscape =
      options ? flutter_print_print_options_get_landscape(options) : nullptr;
  if (landscape) {
    num_options = cupsAddOption("orientation-requested", *landscape ? "4" : "3",
                                num_options, &cups_opts);
  }

  // Send both values so a printer that defaults to mono still prints in colour.
  const gboolean* color =
      options ? flutter_print_print_options_get_color(options) : nullptr;
  if (color) {
    num_options = cupsAddOption("print-color-mode",
                                *color ? "color" : "monochrome",
                                num_options, &cups_opts);
  }

  if (const char* sides = duplex_sides(options)) {
    num_options = cupsAddOption("sides", sides, num_options, &cups_opts);
  }

  FlutterPrintPageSize* page_size =
      options ? flutter_print_print_options_get_page_size(options) : nullptr;
  if (page_size) {
    const gchar* size_name = flutter_print_page_size_get_name(page_size);
    pwg_media_t* media = media_for_size(page_size);
    if (media) {
      num_options = cupsAddOption("media", media->pwg, num_options, &cups_opts);
    } else if (size_name && size_name[0] != '\0') {
      num_options = cupsAddOption("media", size_name, num_options, &cups_opts);
    }
  }

  g_autofree gchar* page_ranges = build_page_ranges(options);
  if (page_ranges) {
    num_options = cupsAddOption("page-ranges", page_ranges, num_options,
                                &cups_opts);
  }

  int job_id = cupsPrintFile(dest->name, print_path, "Flutter Print Job",
                             num_options, cups_opts);
  cupsFreeOptions(num_options, cups_opts);
  cupsFreeDests(1, dest);

  if (transcoded) g_remove(transcoded);

  if (job_id == 0) {
    print_job_fail(job, "PRINT_ERROR", g_strdup(cupsLastErrorString()));
  }
}

static void print_thread(GTask* task, gpointer source_object,
                         gpointer task_data, GCancellable* cancellable) {
  print_file(static_cast<PrintJob*>(task_data));
  g_task_return_boolean(task, TRUE);
}

// Runs on the main thread when the job is done.
static void print_done(GObject* source_object, GAsyncResult* result,
                       gpointer user_data) {
  PrintJob* job = static_cast<PrintJob*>(g_task_get_task_data(G_TASK(result)));
  if (job->error_code) {
    flutter_print_flutter_print_api_respond_error_print(
        job->response_handle, job->error_code, job->error_message, nullptr);
  } else {
    flutter_print_flutter_print_api_respond_print(job->response_handle);
  }
}

static void handle_print(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  // The caller frees its arguments when this returns, so the job keeps its own.
  PrintJob* job = g_new0(PrintJob, 1);
  job->file_path = g_strdup(file_path);
  job->options = options ? FLUTTER_PRINT_PRINT_OPTIONS(g_object_ref(options))
                         : nullptr;
  job->response_handle =
      FLUTTER_PRINT_FLUTTER_PRINT_API_RESPONSE_HANDLE(g_object_ref(response_handle));

  g_autoptr(GTask) task = g_task_new(nullptr, nullptr, print_done, nullptr);
  g_task_set_task_data(task, job, print_job_free);
  g_task_run_in_thread(task, print_thread);
}

// A print dialog request. Lives until the dialog is cancelled or the job is
// sent.
typedef struct {
  gchar* file_path;
  gchar* transcoded;  // Temp PNG of a WebP or HEIC file, or null.
  int color;          // The caller's color option: 1, 0, or -1 when unset.
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
} PreviewRequest;

static void preview_request_free(gpointer data) {
  PreviewRequest* request = static_cast<PreviewRequest*>(data);
  if (request->transcoded) g_remove(request->transcoded);
  g_free(request->file_path);
  g_free(request->transcoded);
  g_object_unref(request->response_handle);
  g_free(request);
}

static void preview_request_fail(PreviewRequest* request, const char* code,
                                 const gchar* message) {
  flutter_print_flutter_print_api_respond_error_print_preview(
      request->response_handle, code, message, nullptr);
  preview_request_free(request);
}

// The ColorModel choice of |printer| for |color|, or nullptr when its driver
// has none. The dialog shows colour as this driver option, with names that
// vary by driver ("Gray", "grayscale", "RGB"…). Free with g_free.
static gchar* color_model_choice(const char* printer, bool color) {
  // GTK reads the same PPD; libcups marks the PPD API deprecated.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  const char* file = cupsGetPPD2(CUPS_HTTP_DEFAULT, printer);
  if (!file) return nullptr;
  ppd_file_t* ppd = ppdOpenFile(file);
  g_remove(file);
  if (!ppd) return nullptr;

  static const char* const kMono[] = {"gray", "grey", "mono", "black"};
  static const char* const kColor[] = {"color", "colour", "rgb", "cmy"};
  const char* const* words = color ? kColor : kMono;
  gchar* result = nullptr;
  ppd_option_t* option = ppdFindOption(ppd, "ColorModel");
  for (int i = 0; option && !result && i < option->num_choices; i++) {
    const ppd_choice_t& choice = option->choices[i];
    g_autofree gchar* name = g_ascii_strdown(choice.choice, -1);
    g_autofree gchar* text = g_ascii_strdown(choice.text, -1);
    for (int w = 0; w < 4 && !result; w++) {
      if (strstr(name, words[w]) || strstr(text, words[w])) {
        result = g_strdup(choice.choice);
      }
    }
  }
  ppdClose(ppd);
#pragma GCC diagnostic pop
  return result;
}

// Pre-fills the dialog's |settings| and |page_setup| from |options|.
static void apply_dialog_options(FlutterPrintPrintOptions* options,
                                 GtkPrintSettings* settings,
                                 GtkPageSetup* page_setup) {
  if (!options) return;

  const gchar* printer_address =
      flutter_print_print_options_get_printer_address(options);
  if (printer_address && printer_address[0] != '\0') {
    gtk_print_settings_set_printer(settings, printer_address);
  }

  const int64_t* copies = flutter_print_print_options_get_copies(options);
  if (copies && *copies > 0) gtk_print_settings_set_n_copies(settings, *copies);

  const gboolean* landscape = flutter_print_print_options_get_landscape(options);
  if (landscape) {
    GtkPageOrientation orientation = *landscape
        ? GTK_PAGE_ORIENTATION_LANDSCAPE : GTK_PAGE_ORIENTATION_PORTRAIT;
    gtk_print_settings_set_orientation(settings, orientation);
    gtk_page_setup_set_orientation(page_setup, orientation);
  }

  // Pre-select the colour choice of the initial printer's driver. GTK ignores
  // the use-color setting. GTK selects the same default printer as CUPS.
  const gboolean* color = flutter_print_print_options_get_color(options);
  if (color) {
    g_autofree gchar* printer = nullptr;
    if (printer_address && printer_address[0] != '\0') {
      printer = g_strdup(printer_address);
    } else if (cups_dest_t* dest =
                   cupsGetNamedDest(CUPS_HTTP_DEFAULT, nullptr, nullptr)) {
      printer = g_strdup(dest->name);
      cupsFreeDests(1, dest);
    }
    g_autofree gchar* choice =
        printer ? color_model_choice(printer, *color) : nullptr;
    if (choice) gtk_print_settings_set(settings, "cups-ColorModel", choice);
  }

  // GTK's horizontal duplex is CUPS' long edge (DuplexNoTumble).
  FlutterPrintDuplexMode* duplex =
      flutter_print_print_options_get_duplex_mode(options);
  if (duplex) {
    switch (*duplex) {
      case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_NONE:
        gtk_print_settings_set_duplex(settings, GTK_PRINT_DUPLEX_SIMPLEX);
        break;
      case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_LONG_EDGE:
        gtk_print_settings_set_duplex(settings, GTK_PRINT_DUPLEX_HORIZONTAL);
        break;
      case FLUTTER_PRINT_PLATFORM_INTERFACE_DUPLEX_MODE_SHORT_EDGE:
        gtk_print_settings_set_duplex(settings, GTK_PRINT_DUPLEX_VERTICAL);
        break;
    }
  }

  // GTK page ranges start at 0.
  FlValue* ranges = flutter_print_print_options_get_page_ranges(options);
  if (ranges && fl_value_get_type(ranges) == FL_VALUE_TYPE_LIST &&
      fl_value_get_length(ranges) > 0) {
    size_t count = fl_value_get_length(ranges);
    g_autofree GtkPageRange* gtk_ranges = g_new0(GtkPageRange, count);
    for (size_t i = 0; i < count; i++) {
      auto* range = FLUTTER_PRINT_PAGE_RANGE(
          fl_value_get_custom_value_object(fl_value_get_list_value(ranges, i)));
      gtk_ranges[i].start = flutter_print_page_range_get_start(range) - 1;
      gtk_ranges[i].end = flutter_print_page_range_get_end(range) - 1;
    }
    gtk_print_settings_set_print_pages(settings, GTK_PRINT_PAGES_RANGES);
    gtk_print_settings_set_page_ranges(settings, gtk_ranges, count);
  }

  // Select the paper by its size, or else by its name ("A4", "Letter"…).
  FlutterPrintPageSize* page_size =
      flutter_print_print_options_get_page_size(options);
  if (page_size) {
    pwg_media_t* media = media_for_size(page_size);
    const gchar* name = flutter_print_page_size_get_name(page_size);
    if (!media && name && name[0] != '\0') {
      media = pwgMediaForPPD(name);
      if (!media) media = pwgMediaForLegacy(name);
    }
    if (media) {
      // PWG sizes are in hundredths of a millimetre; GTK wants points.
      GtkPaperSize* paper = gtk_paper_size_new_from_ipp(
          media->pwg, media->width * 72.0 / 2540.0,
          media->length * 72.0 / 2540.0);
      gtk_page_setup_set_paper_size(page_setup, paper);
      gtk_print_settings_set_paper_size(settings, paper);
      gtk_paper_size_free(paper);
    }
  }
}

// Adds what GTK leaves to the app when it prints a file as is, as CUPS
// options: GTK forwards "cups-" settings to CUPS.
static void add_job_options(GtkPrintSettings* settings,
                            GtkPageSetup* page_setup, int color) {
  // GTK page ranges start at 0.
  if (gtk_print_settings_get_print_pages(settings) == GTK_PRINT_PAGES_RANGES) {
    gint count = 0;
    g_autofree GtkPageRange* ranges =
        gtk_print_settings_get_page_ranges(settings, &count);
    GString* value = g_string_new(nullptr);
    for (gint i = 0; i < count; i++) {
      if (value->len > 0) g_string_append_c(value, ',');
      g_string_append_printf(value, "%d-%d", ranges[i].start + 1,
                             ranges[i].end + 1);
    }
    if (value->len > 0) {
      gtk_print_settings_set(settings, "cups-page-ranges", value->str);
    }
    g_string_free(value, TRUE);
  }

  // IPP orientation-requested: 3 portrait, 4 landscape, 5 reverse landscape,
  // 6 reverse portrait.
  const char* orientation = "3";
  switch (gtk_page_setup_get_orientation(page_setup)) {
    case GTK_PAGE_ORIENTATION_PORTRAIT: orientation = "3"; break;
    case GTK_PAGE_ORIENTATION_LANDSCAPE: orientation = "4"; break;
    case GTK_PAGE_ORIENTATION_REVERSE_LANDSCAPE: orientation = "5"; break;
    case GTK_PAGE_ORIENTATION_REVERSE_PORTRAIT: orientation = "6"; break;
  }
  gtk_print_settings_set(settings, "cups-orientation-requested", orientation);

  // Without a ColorModel option the dialog has no colour choice: send the
  // caller's.
  if (color >= 0 && !gtk_print_settings_has_key(settings, "cups-ColorModel")) {
    gtk_print_settings_set(settings, "cups-print-color-mode",
                           color ? "color" : "monochrome");
  }
}

static void preview_job_sent(GtkPrintJob* job, gpointer user_data,
                             const GError* error) {
  PreviewRequest* request = static_cast<PreviewRequest*>(user_data);
  if (error) {
    flutter_print_flutter_print_api_respond_error_print_preview(
        request->response_handle, "PRINT_ERROR", error->message, nullptr);
  } else {
    flutter_print_flutter_print_api_respond_print_preview(
        request->response_handle);
  }
}

static void preview_dialog_response(GtkDialog* dialog, gint response,
                                    gpointer user_data) {
  PreviewRequest* request = static_cast<PreviewRequest*>(user_data);

  // Preview: show the file in the default viewer and keep the dialog open.
  if (response == GTK_RESPONSE_APPLY) {
    g_autoptr(GError) err = nullptr;
    g_autofree gchar* uri = g_filename_to_uri(request->file_path, nullptr, &err);
    if (!uri || !gtk_show_uri_on_window(GTK_WINDOW(dialog), uri,
                                        GDK_CURRENT_TIME, &err)) {
      g_warning("flutter_print: cannot open %s: %s", request->file_path,
                err ? err->message : "(unknown)");
    }
    return;
  }

  // Report a cancel as success, like on macOS and iOS.
  if (response != GTK_RESPONSE_OK) {
    flutter_print_flutter_print_api_respond_print_preview(
        request->response_handle);
    preview_request_free(request);
    gtk_widget_destroy(GTK_WIDGET(dialog));
    return;
  }

  GtkPrintUnixDialog* print_dialog = GTK_PRINT_UNIX_DIALOG(dialog);
  g_autoptr(GtkPrintSettings) settings =
      gtk_print_unix_dialog_get_settings(print_dialog);
  GtkPageSetup* page_setup = gtk_print_unix_dialog_get_page_setup(print_dialog);
  add_job_options(settings, page_setup, request->color);
  g_autoptr(GtkPrintJob) job = gtk_print_job_new(
      "Flutter Print Job", gtk_print_unix_dialog_get_selected_printer(print_dialog),
      settings, page_setup);
  gtk_widget_destroy(GTK_WIDGET(dialog));

  g_autoptr(GError) err = nullptr;
  const gchar* print_path =
      request->transcoded ? request->transcoded : request->file_path;
  if (!gtk_print_job_set_source_file(job, print_path, &err)) {
    preview_request_fail(request, "PRINT_ERROR", err->message);
    return;
  }
  // The job keeps a ref while sending, and frees the request when done.
  gtk_print_job_send(job, preview_job_sent, request, preview_request_free);
}

static void handle_print_preview(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  FlutterPrintPlugin* plugin = FLUTTER_PRINT_PLUGIN(user_data);

  PreviewRequest* request = g_new0(PreviewRequest, 1);
  request->file_path = g_strdup(file_path);
  const gboolean* color =
      options ? flutter_print_print_options_get_color(options) : nullptr;
  request->color = color ? *color : -1;
  // The caller frees the handle when this returns, so the request keeps a ref.
  request->response_handle =
      FLUTTER_PRINT_FLUTTER_PRINT_API_RESPONSE_HANDLE(g_object_ref(response_handle));

  if (!g_file_test(file_path, G_FILE_TEST_EXISTS)) {
    g_autofree gchar* msg = g_strdup_printf("File not found: %s", file_path);
    preview_request_fail(request, "FILE_NOT_FOUND", msg);
    return;
  }

  // CUPS cannot print WebP or HEIC: convert them to PNG, as for print.
  if (needs_transcode(file_path)) {
    g_autoptr(GError) err = nullptr;
    request->transcoded = transcode_to_png(file_path, &err);
    if (!request->transcoded) {
      bool unsupported =
          g_error_matches(err, GDK_PIXBUF_ERROR, GDK_PIXBUF_ERROR_UNKNOWN_TYPE);
      g_autofree gchar* msg =
          g_strdup_printf("Cannot convert %s: %s", file_path, err->message);
      preview_request_fail(request,
                           unsupported ? "UNSUPPORTED_FILE" : "PRINT_ERROR", msg);
      return;
    }
  }

  FlView* view = fl_plugin_registrar_get_view(plugin->registrar);
  GtkWindow* parent =
      view ? GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view))) : nullptr;
  GtkWidget* dialog = gtk_print_unix_dialog_new(nullptr, parent);
  GtkPrintUnixDialog* print_dialog = GTK_PRINT_UNIX_DIALOG(dialog);

  g_autoptr(GtkPrintSettings) settings = gtk_print_settings_new();
  g_autoptr(GtkPageSetup) page_setup = gtk_page_setup_new();
  apply_dialog_options(options, settings, page_setup);
  gtk_print_unix_dialog_set_settings(print_dialog, settings);
  gtk_print_unix_dialog_set_page_setup(print_dialog, page_setup);
  // Show paper and orientation in the dialog. CUPS applies the other options,
  // so only Preview is handled here.
  gtk_print_unix_dialog_set_embed_page_setup(print_dialog, TRUE);
  gtk_print_unix_dialog_set_manual_capabilities(print_dialog,
                                                GTK_PRINT_CAPABILITY_PREVIEW);

  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  g_signal_connect(dialog, "response", G_CALLBACK(preview_dialog_response),
                   request);
  gtk_widget_show(dialog);
}

// ---------------------------------------------------------------------------
// ListPrinters
// ---------------------------------------------------------------------------

// Runs on a worker thread, since CUPS may query network printers.
static void list_printers_thread(GTask* task, gpointer source_object,
                                 gpointer task_data, GCancellable* cancellable) {
  FlValue* list = fl_value_new_list();

  cups_dest_t* dests = nullptr;
  int num_dests = cupsGetDests(&dests);

  for (int i = 0; i < num_dests; i++) {
    const cups_dest_t& dest = dests[i];
    auto option = [&dest](const char* name) {
      return cupsGetOption(name, dest.num_options, dest.options);
    };

    // label: human-readable name (printer-info), fallback to queue name.
    const char* info_str = option("printer-info");
    const gchar* label = (info_str && info_str[0] != '\0')
                             ? info_str
                             : dest.name;

    // address: CUPS queue name — what gets passed to cupsPrintFile.
    const gchar* address = dest.name;

    // cupsGetDests doesn't return the supported values, and the colour and
    // duplex bits of printer-type don't match the driver. Ask the printer.
    // Both stay unknown when it doesn't answer.
    FlutterPrintColorCapability color_capability =
        FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_UNKNOWN;
    gboolean duplex_val = FALSE;
    gboolean* duplex_ptr = nullptr;
    cups_dinfo_t* info = cupsCopyDestInfo(CUPS_HTTP_DEFAULT, &dests[i]);
    if (info) {
      color_capability =
          cupsCheckDestSupported(CUPS_HTTP_DEFAULT, &dests[i], info,
                                 CUPS_PRINT_COLOR_MODE,
                                 CUPS_PRINT_COLOR_MODE_COLOR)
              ? FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_SUPPORTED
              : FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_MONOCHROME;
      duplex_val = cupsCheckDestSupported(CUPS_HTTP_DEFAULT, &dests[i], info,
                                          CUPS_SIDES,
                                          CUPS_SIDES_TWO_SIDED_PORTRAIT);
      duplex_ptr = &duplex_val;
      cupsFreeDestInfo(info);
    }

    // Build capabilities using the pigeon-generated constructor so the codec
    // serialises it as a positional list the Dart decoder expects.
    FlValue* page_sizes = fl_value_new_list();
    g_autoptr(FlutterPrintPrinterCapabilities) caps =
        flutter_print_printer_capabilities_new(color_capability, duplex_ptr,
                                               nullptr, page_sizes);
    fl_value_unref(page_sizes);

    // printer-state: 3=idle, 4=processing, 5=stopped/offline.
    gboolean avail_val = FALSE;
    gboolean* avail_ptr = nullptr;
    const char* state_str = option("printer-state");
    if (state_str) {
      int state = atoi(state_str);
      avail_val = (state == 3 || state == 4);
      avail_ptr = &avail_val;
    }

    // Build PrinterInfo — also uses the generated constructor.
    g_autoptr(FlutterPrintPrinterInfo) printer_info =
        flutter_print_printer_info_new(label, address, nullptr,
                                       dest.is_default != 0, caps,
                                       avail_ptr);

    fl_value_append_take(list,
        fl_value_new_custom_object(flutter_print_printer_info_type_id,
                                   G_OBJECT(printer_info)));
  }

  cupsFreeDests(num_dests, dests);

  g_task_return_pointer(task, list,
                        reinterpret_cast<GDestroyNotify>(fl_value_unref));
}

// Runs on the main thread when the list is ready.
static void list_printers_done(GObject* source_object, GAsyncResult* result,
                               gpointer user_data) {
  auto* response_handle = static_cast<FlutterPrintFlutterPrintApiResponseHandle*>(
      g_task_get_task_data(G_TASK(result)));
  g_autoptr(FlValue) list = static_cast<FlValue*>(
      g_task_propagate_pointer(G_TASK(result), nullptr));
  flutter_print_flutter_print_api_respond_list_printers(response_handle, list);
}

static void handle_pick_printer(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  flutter_print_flutter_print_api_respond_pick_printer(response_handle, nullptr);
}

static void handle_list_printers(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  // The caller frees the handle when this returns, so the task keeps a ref.
  g_autoptr(GTask) task =
      g_task_new(nullptr, nullptr, list_printers_done, nullptr);
  g_task_set_task_data(task, g_object_ref(response_handle), g_object_unref);
  g_task_run_in_thread(task, list_printers_thread);
}

// ---------------------------------------------------------------------------
// Plugin registration
// ---------------------------------------------------------------------------

static const FlutterPrintFlutterPrintApiVTable kApiVTable = {
    .print         = handle_print,
    .print_preview = handle_print_preview,
    .list_printers = handle_list_printers,
    .pick_printer  = handle_pick_printer,
};

void flutter_print_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterPrintPlugin* plugin = FLUTTER_PRINT_PLUGIN(
      g_object_new(flutter_print_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  flutter_print_flutter_print_api_set_method_handlers(
      messenger, nullptr, &kApiVTable, plugin, g_object_unref);
}
