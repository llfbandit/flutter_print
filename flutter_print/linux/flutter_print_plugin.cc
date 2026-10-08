#include "flutter_print_plugin_private.h"

#include <gtk/gtk.h>

#include "print_dialog.h"
#include "print_job.h"
#include "printer_list.h"

#define FLUTTER_PRINT_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_print_plugin_get_type(), \
                              FlutterPrintPlugin))

struct _FlutterPrintPlugin {
  GObject parent_instance;
  // Gives the Flutter view, the parent of the print dialog.
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

static void handle_print(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  print_job_start(file_path, options, response_handle);
}

static void handle_print_preview(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  FlutterPrintPlugin* plugin = FLUTTER_PRINT_PLUGIN(user_data);
  FlView* view = fl_plugin_registrar_get_view(plugin->registrar);
  GtkWindow* parent =
      view ? GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view))) : nullptr;
  print_dialog_show(parent, file_path, options, response_handle);
}

static void handle_list_printers(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  printer_list_start(response_handle);
}

// Linux has no printer picker.
static void handle_pick_printer(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  flutter_print_flutter_print_api_respond_pick_printer(response_handle, nullptr);
}

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
