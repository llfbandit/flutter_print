#include "include/flutter_print/flutter_print_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

#ifdef HAS_CUPS
#include <cups/cups.h>
#endif

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

static void flutter_print_plugin_dispose(GObject* object) {
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
// or nullptr if GDK-Pixbuf cannot load the format (codec not installed).
static gchar* transcode_to_png(const char* path) {
  GError* err = nullptr;
  GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, &err);
  if (!pixbuf) {
    g_warning("flutter_print: GDK-Pixbuf cannot decode %s: %s",
               path, err ? err->message : "(unknown)");
    g_clear_error(&err);
    return nullptr;
  }

  gchar* tmp = g_strdup_printf("%s/flutter_print_%d.png",
                                g_get_tmp_dir(), (int)getpid());
  if (!gdk_pixbuf_save(pixbuf, tmp, "png", &err, nullptr)) {
    g_warning("flutter_print: failed to save temp PNG: %s",
               err ? err->message : "(unknown)");
    g_clear_error(&err);
    g_object_unref(pixbuf);
    g_free(tmp);
    return nullptr;
  }

  g_object_unref(pixbuf);
  return tmp;
}

// ---------------------------------------------------------------------------
// Print / PrintPreview
// ---------------------------------------------------------------------------

static FlutterPrintFlutterPrintApiPrintResponse* handle_print(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    gpointer user_data) {

  if (!g_file_test(file_path, G_FILE_TEST_EXISTS)) {
    return flutter_print_flutter_print_api_print_response_new_error(
        "FILE_NOT_FOUND",
        g_strdup_printf("File not found: %s", file_path),
        nullptr);
  }

#ifdef HAS_CUPS
  const gchar* printer_address =
      flutter_print_print_options_get_printer_address(options);
  const gchar* dest = (printer_address && printer_address[0] != '\0')
                          ? printer_address
                          : cupsGetDefault();

  int num_options = 0;
  cups_option_t* cups_opts = nullptr;

  gint64 copies = flutter_print_print_options_get_copies(options);
  if (copies > 1) {
    gchar* s = g_strdup_printf("%" G_GINT64_FORMAT, copies);
    num_options = cupsAddOption("copies", s, num_options, &cups_opts);
    g_free(s);
  }

  // Use the IPP-standard attribute (3=portrait, 4=landscape) instead of the
  // legacy CUPS-only "landscape" shorthand.
  if (flutter_print_print_options_get_landscape(options)) {
    num_options = cupsAddOption("orientation-requested", "4",
                                num_options, &cups_opts);
  }

  if (!flutter_print_print_options_get_color(options)) {
    num_options = cupsAddOption("print-color-mode", "monochrome",
                                num_options, &cups_opts);
  }

  FlutterPrintDuplexMode* duplex_mode =
      flutter_print_print_options_get_duplex_mode(options);
  if (duplex_mode) {
    const char* sides = nullptr;
    switch (*duplex_mode) {
      case FLUTTER_PRINT_DUPLEX_MODE_NONE:
        sides = "one-sided";            break;
      case FLUTTER_PRINT_DUPLEX_MODE_LONG_EDGE:
        sides = "two-sided-long-edge";  break;
      case FLUTTER_PRINT_DUPLEX_MODE_SHORT_EDGE:
        sides = "two-sided-short-edge"; break;
    }
    if (sides)
      num_options = cupsAddOption("sides", sides, num_options, &cups_opts);
  }

  FlutterPrintPageSize* page_size =
      flutter_print_print_options_get_page_size(options);
  if (page_size) {
    const gchar* size_name = flutter_print_page_size_get_name(page_size);
    if (size_name && size_name[0] != '\0') {
      num_options = cupsAddOption("media", size_name, num_options, &cups_opts);
    } else {
      double* width  = flutter_print_page_size_get_width(page_size);
      double* height = flutter_print_page_size_get_height(page_size);
      if (width && height && *width > 0 && *height > 0) {
        int w_pts = (int)(*width  * 72.0 / 25.4 + 0.5);
        int h_pts = (int)(*height * 72.0 / 25.4 + 0.5);
        gchar* custom = g_strdup_printf("Custom.%dx%d", w_pts, h_pts);
        num_options = cupsAddOption("media", custom, num_options, &cups_opts);
        g_free(custom);
      }
    }
  }

  // For formats CUPS cannot rasterise (WebP, HEIC), transcode to PNG first
  // using GDK-Pixbuf, which supports these formats when the system pixbuf
  // loaders are installed (webp-pixbuf-loader, heif-pixbuf-loader).
  gchar* transcoded = needs_transcode(file_path)
                          ? transcode_to_png(file_path)
                          : nullptr;
  const char* print_path = transcoded ? transcoded : file_path;

  int job_id = cupsPrintFile(dest, print_path, "Flutter Print Job",
                              num_options, cups_opts);
  cupsFreeOptions(num_options, cups_opts);

  if (transcoded) {
    g_remove(transcoded);
    g_free(transcoded);
  }

  if (job_id == 0) {
    return flutter_print_flutter_print_api_print_response_new_error(
        "PRINT_ERROR", cupsLastErrorString(), nullptr);
  }

#else
  // No CUPS at build time: use the lp command-line tool.
  // Build argv safely — no shell, no injection risk.
  const gchar* printer_address =
      flutter_print_print_options_get_printer_address(options);
  gint64 copies = flutter_print_print_options_get_copies(options);

  // Heap-allocated strings that must outlive the spawn call.
  gchar* copies_str = copies > 1
      ? g_strdup_printf("%" G_GINT64_FORMAT, copies) : nullptr;

  FlutterPrintDuplexMode* duplex_mode =
      flutter_print_print_options_get_duplex_mode(options);
  const char* sides = nullptr;
  if (duplex_mode) {
    switch (*duplex_mode) {
      case FLUTTER_PRINT_DUPLEX_MODE_NONE:
        sides = "one-sided";            break;
      case FLUTTER_PRINT_DUPLEX_MODE_LONG_EDGE:
        sides = "two-sided-long-edge";  break;
      case FLUTTER_PRINT_DUPLEX_MODE_SHORT_EDGE:
        sides = "two-sided-short-edge"; break;
    }
  }

  GPtrArray* argv = g_ptr_array_new();
  g_ptr_array_add(argv, const_cast<gchar*>("lp"));
  if (printer_address && printer_address[0] != '\0') {
    g_ptr_array_add(argv, const_cast<gchar*>("-d"));
    g_ptr_array_add(argv, const_cast<gchar*>(printer_address));
  }
  if (copies_str) {
    g_ptr_array_add(argv, const_cast<gchar*>("-n"));
    g_ptr_array_add(argv, copies_str);
  }
  if (flutter_print_print_options_get_landscape(options)) {
    g_ptr_array_add(argv, const_cast<gchar*>("-o"));
    g_ptr_array_add(argv, const_cast<gchar*>("orientation-requested=4"));
  }
  if (!flutter_print_print_options_get_color(options)) {
    g_ptr_array_add(argv, const_cast<gchar*>("-o"));
    g_ptr_array_add(argv, const_cast<gchar*>("print-color-mode=monochrome"));
  }
  if (sides) {
    g_ptr_array_add(argv, const_cast<gchar*>("-o"));
    g_ptr_array_add(argv, const_cast<gchar*>(sides));
  }
  g_ptr_array_add(argv, const_cast<gchar*>(file_path));
  g_ptr_array_add(argv, nullptr);

  GError* err = nullptr;
  gint exit_status = 0;
  bool ok = g_spawn_sync(nullptr,
                         reinterpret_cast<gchar**>(argv->pdata),
                         nullptr,
                         G_SPAWN_SEARCH_PATH,
                         nullptr, nullptr,
                         nullptr, nullptr,
                         &exit_status, &err);
  g_ptr_array_free(argv, FALSE);
  g_free(copies_str);
  g_clear_error(&err);

  if (!ok || exit_status != 0) {
    return flutter_print_flutter_print_api_print_response_new_error(
        "PRINT_ERROR", "lp command failed", nullptr);
  }
#endif

  return flutter_print_flutter_print_api_print_response_new();
}

static FlutterPrintFlutterPrintApiPrintPreviewResponse* handle_print_preview(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    gpointer user_data) {
  g_autoptr(GError) err = nullptr;
  g_autoptr(GSubprocess) proc =
      g_subprocess_new(G_SUBPROCESS_FLAGS_NONE, &err, "xdg-open", file_path, nullptr);
  if (!proc) {
    g_warning("xdg-open failed: %s", err ? err->message : "(unknown)");
  }
  return flutter_print_flutter_print_api_print_preview_response_new();
}

// ---------------------------------------------------------------------------
// ListPrinters
// ---------------------------------------------------------------------------

typedef struct {
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
  FlValue* result_list;
} ListPrintersReply;

static gboolean list_printers_respond_idle(gpointer user_data) {
  ListPrintersReply* reply = static_cast<ListPrintersReply*>(user_data);
  flutter_print_flutter_print_api_respond_list_printers(reply->response_handle,
                                                         reply->result_list);
  fl_value_unref(reply->result_list);
  g_free(reply);
  return G_SOURCE_REMOVE;
}

static gpointer list_printers_worker(gpointer user_data) {
  ListPrintersReply* reply = static_cast<ListPrintersReply*>(user_data);
  FlValue* list = fl_value_new_list();

#ifdef HAS_CUPS
  cups_dest_t* dests = nullptr;
  int num_dests = cupsGetDests(&dests);

  for (int i = 0; i < num_dests; i++) {
    // label: human-readable name (printer-info), fallback to queue name.
    const char* info_str = cupsGetOption("printer-info",
                                          dests[i].num_options,
                                          dests[i].options);
    const gchar* label = (info_str && info_str[0] != '\0')
                             ? info_str
                             : dests[i].name;

    // address: CUPS queue name — what gets passed to cupsPrintFile / lp -d.
    const gchar* address = dests[i].name;

    // supportsColor
    gboolean color_val = FALSE;
    gboolean* color_ptr = nullptr;
    const char* color_str = cupsGetOption("color-supported",
                                           dests[i].num_options,
                                           dests[i].options);
    if (color_str) {
      color_val = (strcmp(color_str, "true") == 0);
      color_ptr = &color_val;
    }

    // supportsDuplex: check sides-supported attribute.
    gboolean duplex_val = FALSE;
    gboolean* duplex_ptr = nullptr;
    const char* sides_str = cupsGetOption("sides-supported",
                                           dests[i].num_options,
                                           dests[i].options);
    if (sides_str) {
      duplex_val = (strstr(sides_str, "two-sided") != nullptr);
      duplex_ptr = &duplex_val;
    }

    // Build capabilities using the pigeon-generated constructor so the codec
    // serialises it as a positional list the Dart decoder expects.
    FlValue* page_sizes = fl_value_new_list();
    g_autoptr(FlutterPrintPrinterCapabilities) caps =
        flutter_print_printer_capabilities_new(color_ptr, duplex_ptr,
                                               nullptr, page_sizes);
    fl_value_unref(page_sizes);

    // Build PrinterInfo — also uses the generated constructor.
    g_autoptr(FlutterPrintPrinterInfo) printer_info =
        flutter_print_printer_info_new(label, address, nullptr,
                                       dests[i].is_default != 0, caps);

    fl_value_append_take(list,
        fl_value_new_custom_object(flutter_print_printer_info_type_id,
                                   G_OBJECT(printer_info)));
  }

  cupsFreeDests(num_dests, dests);
#endif

  reply->result_list = list;
  g_idle_add(list_printers_respond_idle, reply);
  return nullptr;
}

static void handle_pick_printer(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  flutter_print_flutter_print_api_respond_pick_printer(response_handle, nullptr);
}

static void handle_list_printers(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  ListPrintersReply* reply = g_new0(ListPrintersReply, 1);
  reply->response_handle = response_handle;
  g_thread_new("flutter_print_list_printers", list_printers_worker, reply);
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
