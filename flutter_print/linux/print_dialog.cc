#include "print_dialog.h"

#include <gtk/gtkunixprint.h>

#include "print_file.h"
#include "print_settings.h"

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
  print_settings_add_job_options(settings, page_setup, request->color);
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
  print_settings_fill(options, settings, page_setup);
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
