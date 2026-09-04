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

static void flutter_print_plugin_class_init(FlutterPrintPluginClass* klass) {}

static void flutter_print_plugin_init(FlutterPrintPlugin* self) {}

#ifdef HAS_CUPS
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
  g_autoptr(GError) err = nullptr;
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_file(path, &err);
  if (!pixbuf) {
    g_warning("flutter_print: GDK-Pixbuf cannot decode %s: %s",
               path, err ? err->message : "(unknown)");
    return nullptr;
  }

  g_autofree gchar* tmp = g_strdup_printf("%s/flutter_print_%d.png",
                                           g_get_tmp_dir(), (int)getpid());
  if (!gdk_pixbuf_save(pixbuf, tmp, "png", &err, nullptr)) {
    g_warning("flutter_print: failed to save temp PNG: %s",
               err ? err->message : "(unknown)");
    return nullptr;
  }
  return static_cast<gchar*>(g_steal_pointer(&tmp));
}
#endif

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

static void handle_print(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {

  if (!g_file_test(file_path, G_FILE_TEST_EXISTS)) {
    g_autofree gchar* msg = g_strdup_printf("File not found: %s", file_path);
    flutter_print_flutter_print_api_respond_error_print(
        response_handle, "FILE_NOT_FOUND", msg, nullptr);
    return;
  }

#ifdef HAS_CUPS
  // options may be null when the caller omits them; in that case no CUPS
  // options are added and the printer's default settings apply.
  const gchar* printer_address =
      options ? flutter_print_print_options_get_printer_address(options) : nullptr;
  const gchar* dest = (printer_address && printer_address[0] != '\0')
                          ? printer_address
                          : cupsGetDefault();

  int num_options = 0;
  cups_option_t* cups_opts = nullptr;

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
  if (landscape && *landscape) {
    num_options = cupsAddOption("orientation-requested", "4",
                                num_options, &cups_opts);
  }

  const gboolean* color =
      options ? flutter_print_print_options_get_color(options) : nullptr;
  if (color && !*color) {
    num_options = cupsAddOption("print-color-mode", "monochrome",
                                num_options, &cups_opts);
  }

  if (const char* sides = duplex_sides(options)) {
    num_options = cupsAddOption("sides", sides, num_options, &cups_opts);
  }

  FlutterPrintPageSize* page_size =
      options ? flutter_print_print_options_get_page_size(options) : nullptr;
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
        g_autofree gchar* custom = g_strdup_printf("Custom.%dx%d", w_pts, h_pts);
        num_options = cupsAddOption("media", custom, num_options, &cups_opts);
      }
    }
  }

  g_autofree gchar* page_ranges = build_page_ranges(options);
  if (page_ranges) {
    num_options = cupsAddOption("page-ranges", page_ranges, num_options,
                                &cups_opts);
  }

  // For formats CUPS cannot rasterise (WebP, HEIC), transcode to PNG first
  // using GDK-Pixbuf, which supports these formats when the system pixbuf
  // loaders are installed (webp-pixbuf-loader, heif-pixbuf-loader).
  g_autofree gchar* transcoded = needs_transcode(file_path)
                                     ? transcode_to_png(file_path)
                                     : nullptr;
  const char* print_path = transcoded ? transcoded : file_path;

  int job_id = cupsPrintFile(dest, print_path, "Flutter Print Job",
                              num_options, cups_opts);
  cupsFreeOptions(num_options, cups_opts);

  if (transcoded) g_remove(transcoded);

  if (job_id == 0) {
    flutter_print_flutter_print_api_respond_error_print(
        response_handle, "PRINT_ERROR", cupsLastErrorString(), nullptr);
    return;
  }

#else
  // No CUPS at build time: use the lp command-line tool.
  // Build argv safely — no shell, no injection risk.
  // options may be null when the caller omits them; in that case no lp options
  // are passed and the printer's default settings apply.
  const gchar* printer_address =
      options ? flutter_print_print_options_get_printer_address(options) : nullptr;
  const int64_t* copies =
      options ? flutter_print_print_options_get_copies(options) : nullptr;
  const gboolean* landscape =
      options ? flutter_print_print_options_get_landscape(options) : nullptr;
  const gboolean* color =
      options ? flutter_print_print_options_get_color(options) : nullptr;

  // Heap-allocated strings that must outlive the spawn call.
  g_autofree gchar* copies_str = (copies && *copies > 1)
      ? g_strdup_printf("%" G_GINT64_FORMAT, *copies) : nullptr;

  g_autofree gchar* page_ranges = build_page_ranges(options);
  g_autofree gchar* page_ranges_opt = page_ranges
      ? g_strdup_printf("page-ranges=%s", page_ranges) : nullptr;

  const char* sides = duplex_sides(options);

  g_autoptr(GPtrArray) argv = g_ptr_array_new();
  auto add = [&](const gchar* flag, const gchar* value) {
    g_ptr_array_add(argv, const_cast<gchar*>(flag));
    g_ptr_array_add(argv, const_cast<gchar*>(value));
  };
  g_ptr_array_add(argv, const_cast<gchar*>("lp"));
  if (printer_address && printer_address[0] != '\0') add("-d", printer_address);
  if (copies_str) add("-n", copies_str);
  if (landscape && *landscape) add("-o", "orientation-requested=4");
  if (color && !*color) add("-o", "print-color-mode=monochrome");
  if (sides) add("-o", sides);
  if (page_ranges_opt) add("-o", page_ranges_opt);
  g_ptr_array_add(argv, const_cast<gchar*>(file_path));
  g_ptr_array_add(argv, nullptr);

  g_autoptr(GError) err = nullptr;
  gint exit_status = 0;
  bool ok = g_spawn_sync(nullptr,
                         reinterpret_cast<gchar**>(argv->pdata),
                         nullptr,
                         G_SPAWN_SEARCH_PATH,
                         nullptr, nullptr,
                         nullptr, nullptr,
                         &exit_status, &err);

  if (!ok || exit_status != 0) {
    flutter_print_flutter_print_api_respond_error_print(
        response_handle, "PRINT_ERROR", "lp command failed", nullptr);
    return;
  }
#endif

  flutter_print_flutter_print_api_respond_print(response_handle);
}

static void handle_print_preview(
    const gchar* file_path,
    FlutterPrintPrintOptions* options,
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
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

#ifdef HAS_CUPS
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

    // address: CUPS queue name — what gets passed to cupsPrintFile / lp -d.
    const gchar* address = dest.name;

    // colorCapability
    FlutterPrintColorCapability color_capability =
        FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_UNKNOWN;
    const char* color_str = option("color-supported");
    if (color_str) {
      color_capability = (strcmp(color_str, "true") == 0)
          ? FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_SUPPORTED
          : FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_MONOCHROME;
    }

    // supportsDuplex: check sides-supported attribute.
    gboolean duplex_val = FALSE;
    gboolean* duplex_ptr = nullptr;
    const char* sides_str = option("sides-supported");
    if (sides_str) {
      duplex_val = (strstr(sides_str, "two-sided") != nullptr);
      duplex_ptr = &duplex_val;
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

  reply->result_list = list;
  g_idle_add(list_printers_respond_idle, reply);
  return nullptr;
}
#endif  // HAS_CUPS

static void handle_pick_printer(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
  flutter_print_flutter_print_api_respond_pick_printer(response_handle, nullptr);
}

static void handle_list_printers(
    FlutterPrintFlutterPrintApiResponseHandle* response_handle,
    gpointer user_data) {
#ifdef HAS_CUPS
  ListPrintersReply* reply = g_new0(ListPrintersReply, 1);
  reply->response_handle = response_handle;
  g_thread_new("flutter_print_list_printers", list_printers_worker, reply);
#else
  FlValue* list = fl_value_new_list();
  flutter_print_flutter_print_api_respond_list_printers(response_handle, list);
  fl_value_unref(list);
#endif
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
