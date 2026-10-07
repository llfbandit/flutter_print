#include "include/flutter_print/flutter_print_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <cups/cups.h>
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
};

G_DEFINE_TYPE(FlutterPrintPlugin, flutter_print_plugin, g_object_get_type())

static void flutter_print_plugin_class_init(FlutterPrintPluginClass* klass) {}

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
    // Prefer the size: names like "B4" or "DL" are ambiguous or unknown to
    // CUPS. pwgMediaForSize returns the standard PWG name, or a custom size.
    const gchar* size_name = flutter_print_page_size_get_name(page_size);
    double* width  = flutter_print_page_size_get_width(page_size);
    double* height = flutter_print_page_size_get_height(page_size);
    pwg_media_t* media = (width && height && *width > 0 && *height > 0)
        ? pwgMediaForSize((int)(*width * 100 + 0.5), (int)(*height * 100 + 0.5))
        : nullptr;
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

static void handle_print_preview(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  if (!g_file_test(file_path, G_FILE_TEST_EXISTS)) {
    g_autofree gchar* msg = g_strdup_printf("File not found: %s", file_path);
    flutter_print_flutter_print_api_respond_error_print_preview(
        response_handle, "FILE_NOT_FOUND", msg, nullptr);
    return;
  }

  g_autoptr(GError) err = nullptr;
  g_autoptr(GSubprocess) proc =
      g_subprocess_new(G_SUBPROCESS_FLAGS_NONE, &err, "xdg-open", file_path, nullptr);
  if (!proc) {
    g_autofree gchar* msg =
        g_strdup_printf("xdg-open failed: %s", err ? err->message : "(unknown)");
    g_warning("%s", msg);
    flutter_print_flutter_print_api_respond_error_print_preview(
        response_handle, "PREVIEW_ERROR", msg, nullptr);
    return;
  }
  flutter_print_flutter_print_api_respond_print_preview(response_handle);
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

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  flutter_print_flutter_print_api_set_method_handlers(
      messenger, nullptr, &kApiVTable, plugin, g_object_unref);
}
