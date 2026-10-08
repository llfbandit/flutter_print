#include "print_dialog.h"

#include <cups/cups.h>
#include <gtk/gtkunixprint.h>

#include "cups_options.h"
#include "print_file.h"

// Lives until the user cancels the dialog or the job is sent.
typedef struct {
  gchar* file_path;  // Opened by the Preview button.
  PrintFile* file;   // Sent to the printer.
  int color;         // The caller's colour option: 1, 0, or -1 when unset.
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
} DialogRequest;

static void dialog_request_free(gpointer data) {
  DialogRequest* request = static_cast<DialogRequest*>(data);
  print_file_free(request->file);
  g_free(request->file_path);
  g_object_unref(request->response_handle);
  g_free(request);
}

static void dialog_request_fail(DialogRequest* request, const char* code,
                                const gchar* message) {
  flutter_print_flutter_print_api_respond_error_print_preview(
      request->response_handle, code, message, nullptr);
  dialog_request_free(request);
}

// Fills in the dialog |settings| and |page_setup| from |options|.
static void apply_options(FlutterPrintPrintOptions* options,
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

  // GTK ignores the use-color setting. Select the colour choice of the
  // printer driver instead. GTK opens on the same default printer as CUPS.
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

  // GTK horizontal duplex is the CUPS long edge (DuplexNoTumble).
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

  // GTK counts pages from 0.
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

  FlutterPrintPageSize* page_size =
      flutter_print_print_options_get_page_size(options);
  pwg_media_t* media = page_size ? page_size_media(page_size) : nullptr;
  if (media) {
    // PWG sizes are in hundredths of a millimetre. GTK takes points.
    GtkPaperSize* paper = gtk_paper_size_new_from_ipp(
        media->pwg, media->width * 72.0 / 2540.0,
        media->length * 72.0 / 2540.0);
    gtk_page_setup_set_paper_size(page_setup, paper);
    gtk_print_settings_set_paper_size(settings, paper);
    gtk_paper_size_free(paper);
  }
}

// GTK expects the app to draw the pages, but this plugin sends the file as
// is. So add the choices that GTK leaves to the app as CUPS options. GTK
// sends the "cups-" settings to CUPS.
static void add_job_options(GtkPrintSettings* settings,
                            GtkPageSetup* page_setup, int color) {
  // GTK counts pages from 0. CUPS counts from 1.
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

  // A driver without a ColorModel option shows no colour choice. Send the
  // caller's colour instead.
  if (color >= 0 && !gtk_print_settings_has_key(settings, "cups-ColorModel")) {
    gtk_print_settings_set(settings, "cups-print-color-mode",
                           color ? "color" : "monochrome");
  }
}

static void dialog_job_sent(GtkPrintJob* job, gpointer user_data,
                            const GError* error) {
  DialogRequest* request = static_cast<DialogRequest*>(user_data);
  if (error) {
    flutter_print_flutter_print_api_respond_error_print_preview(
        request->response_handle, "PRINT_ERROR", error->message, nullptr);
  } else {
    flutter_print_flutter_print_api_respond_print_preview(
        request->response_handle);
  }
}

// Opens the file in the default viewer. The dialog stays open.
static void show_preview(GtkWindow* dialog, DialogRequest* request) {
  g_autoptr(GError) err = nullptr;
  g_autofree gchar* uri = g_filename_to_uri(request->file_path, nullptr, &err);
  if (!uri || !gtk_show_uri_on_window(dialog, uri, GDK_CURRENT_TIME, &err)) {
    g_warning("flutter_print: cannot open %s: %s", request->file_path,
              err ? err->message : "(unknown)");
  }
}

// Sends the file to the printer with the dialog settings.
static void send_job(GtkPrintUnixDialog* dialog, DialogRequest* request) {
  g_autoptr(GtkPrintSettings) settings =
      gtk_print_unix_dialog_get_settings(dialog);
  GtkPageSetup* page_setup = gtk_print_unix_dialog_get_page_setup(dialog);
  add_job_options(settings, page_setup, request->color);
  g_autoptr(GtkPrintJob) job = gtk_print_job_new(
      "Flutter Print Job", gtk_print_unix_dialog_get_selected_printer(dialog),
      settings, page_setup);

  g_autoptr(GError) err = nullptr;
  if (!gtk_print_job_set_source_file(job, print_file_path(request->file),
                                     &err)) {
    dialog_request_fail(request, "PRINT_ERROR", err->message);
    return;
  }
  // The job keeps a ref while it sends. It frees the request when done.
  gtk_print_job_send(job, dialog_job_sent, request, dialog_request_free);
}

static void dialog_response(GtkDialog* dialog, gint response,
                            gpointer user_data) {
  DialogRequest* request = static_cast<DialogRequest*>(user_data);
  if (response == GTK_RESPONSE_APPLY) {
    show_preview(GTK_WINDOW(dialog), request);
    return;
  }

  if (response == GTK_RESPONSE_OK) {
    send_job(GTK_PRINT_UNIX_DIALOG(dialog), request);
  } else {
    // Report a cancel as success, like on macOS and iOS.
    flutter_print_flutter_print_api_respond_print_preview(
        request->response_handle);
    dialog_request_free(request);
  }
  gtk_widget_destroy(GTK_WIDGET(dialog));
}

void print_dialog_show(GtkWindow* parent, const gchar* file_path,
                       FlutterPrintPrintOptions* options,
                       FlutterPrintFlutterPrintApiResponseHandle* response_handle) {
  DialogRequest* request = g_new0(DialogRequest, 1);
  request->file_path = g_strdup(file_path);
  const gboolean* color =
      options ? flutter_print_print_options_get_color(options) : nullptr;
  request->color = color ? *color : -1;
  // The caller frees the handle when this returns, so keep a ref.
  request->response_handle =
      FLUTTER_PRINT_FLUTTER_PRINT_API_RESPONSE_HANDLE(g_object_ref(response_handle));

  const char* code = nullptr;
  g_autofree gchar* message = nullptr;
  request->file = print_file_prepare(file_path, &code, &message);
  if (!request->file) {
    dialog_request_fail(request, code, message);
    return;
  }

  GtkWidget* dialog = gtk_print_unix_dialog_new(nullptr, parent);
  GtkPrintUnixDialog* print_dialog = GTK_PRINT_UNIX_DIALOG(dialog);
  g_autoptr(GtkPrintSettings) settings = gtk_print_settings_new();
  g_autoptr(GtkPageSetup) page_setup = gtk_page_setup_new();
  apply_options(options, settings, page_setup);
  gtk_print_unix_dialog_set_settings(print_dialog, settings);
  gtk_print_unix_dialog_set_page_setup(print_dialog, page_setup);
  // Show paper and orientation in the dialog. CUPS applies the other options,
  // so this code only handles Preview.
  gtk_print_unix_dialog_set_embed_page_setup(print_dialog, TRUE);
  gtk_print_unix_dialog_set_manual_capabilities(print_dialog,
                                                GTK_PRINT_CAPABILITY_PREVIEW);

  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  g_signal_connect(dialog, "response", G_CALLBACK(dialog_response), request);
  gtk_widget_show(dialog);
}
