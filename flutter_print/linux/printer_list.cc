#include "printer_list.h"

#include <cups/cups.h>
#include <cstdlib>

// The page size names of the plugin, in portrait millimetres (see
// PaperSizes).
static const struct {
  const char* name;
  double width;
  double height;
} kPageSizes[] = {
    {"A0", 841, 1189},        {"A1", 594, 841},       {"A2", 420, 594},
    {"A3", 297, 420},         {"A4", 210, 297},       {"A5", 148, 210},
    {"A6", 105, 148},         {"B4", 250, 353},       {"B5", 176, 250},
    {"Letter", 215.9, 279.4}, {"Legal", 215.9, 355.6}, {"Tabloid", 279.4, 431.8},
    {"Executive", 184.2, 266.7}, {"JIS B4", 257, 364}, {"JIS B5", 182, 257},
    {"C5", 162, 229},         {"DL", 110, 220},
};

// Returns the names of the page sizes the printer supports, matched by size
// within 1 mm.
static FlValue* supported_page_sizes(cups_dest_t* dest, cups_dinfo_t* dinfo) {
  bool supported[G_N_ELEMENTS(kPageSizes)] = {};
  int count = cupsGetDestMediaCount(CUPS_HTTP_DEFAULT, dest, dinfo, 0);
  for (int i = 0; i < count; i++) {
    cups_size_t size;
    if (!cupsGetDestMediaByIndex(CUPS_HTTP_DEFAULT, dest, dinfo, i, 0, &size)) {
      continue;
    }
    // CUPS sizes are in hundredths of a millimetre.
    for (size_t j = 0; j < G_N_ELEMENTS(kPageSizes); j++) {
      if (abs(size.width - (int)(kPageSizes[j].width * 100 + 0.5)) <= 100 &&
          abs(size.length - (int)(kPageSizes[j].height * 100 + 0.5)) <= 100) {
        supported[j] = true;
      }
    }
  }
  FlValue* list = fl_value_new_list();
  for (size_t j = 0; j < G_N_ELEMENTS(kPageSizes); j++) {
    if (supported[j]) {
      fl_value_append_take(list, fl_value_new_string(kPageSizes[j].name));
    }
  }
  return list;
}

// Returns the highest copies value the printer takes, or 0 when unknown.
static int max_copies(cups_dest_t* dest, cups_dinfo_t* dinfo) {
  ipp_attribute_t* copies =
      cupsFindDestSupported(CUPS_HTTP_DEFAULT, dest, dinfo, CUPS_COPIES);
  if (!copies || ippGetValueTag(copies) != IPP_TAG_RANGE) return 0;
  int upper = 0;
  ippGetRange(copies, 0, &upper);
  return upper;
}

// Builds the PrinterInfo of |dest|.
static FlValue* printer_info(cups_dest_t* dest) {
  // The label is printer-info, or else the queue name. The address is the
  // queue name, which cupsPrintFile takes.
  const char* info = cupsGetOption("printer-info", dest->num_options,
                                   dest->options);
  const gchar* label = (info && info[0] != '\0') ? info : dest->name;

  // cupsGetDests doesn't return the supported values, and the colour and
  // duplex bits of printer-type don't match the driver. So ask the printer.
  // All stay unknown when it doesn't answer.
  FlutterPrintColorCapability color_capability =
      FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_UNKNOWN;
  gboolean duplex = FALSE;
  gboolean* duplex_ptr = nullptr;
  int64_t copies = 0;
  int64_t* copies_ptr = nullptr;
  g_autoptr(FlValue) page_sizes = nullptr;
  cups_dinfo_t* dinfo = cupsCopyDestInfo(CUPS_HTTP_DEFAULT, dest);
  if (dinfo) {
    color_capability =
        cupsCheckDestSupported(CUPS_HTTP_DEFAULT, dest, dinfo,
                               CUPS_PRINT_COLOR_MODE,
                               CUPS_PRINT_COLOR_MODE_COLOR)
            ? FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_SUPPORTED
            : FLUTTER_PRINT_PLATFORM_INTERFACE_COLOR_CAPABILITY_MONOCHROME;
    duplex = cupsCheckDestSupported(CUPS_HTTP_DEFAULT, dest, dinfo, CUPS_SIDES,
                                    CUPS_SIDES_TWO_SIDED_PORTRAIT);
    duplex_ptr = &duplex;
    copies = max_copies(dest, dinfo);
    if (copies > 0) copies_ptr = &copies;
    page_sizes = supported_page_sizes(dest, dinfo);
    cupsFreeDestInfo(dinfo);
  }
  if (!page_sizes) page_sizes = fl_value_new_list();

  // Use the Pigeon constructors, so the codec writes what Dart expects.
  g_autoptr(FlutterPrintPrinterCapabilities) caps =
      flutter_print_printer_capabilities_new(color_capability, duplex_ptr,
                                             copies_ptr, page_sizes);

  // printer-state: 3 idle, 4 printing, 5 stopped.
  gboolean available = FALSE;
  gboolean* available_ptr = nullptr;
  const char* state = cupsGetOption("printer-state", dest->num_options,
                                    dest->options);
  if (state) {
    int value = atoi(state);
    available = value == 3 || value == 4;
    available_ptr = &available;
  }

  g_autoptr(FlutterPrintPrinterInfo) result = flutter_print_printer_info_new(
      label, dest->name, nullptr, dest->is_default != 0, caps, available_ptr);
  return fl_value_new_custom_object(flutter_print_printer_info_type_id,
                                    G_OBJECT(result));
}

// Runs on a worker thread.
static void printer_list_thread(GTask* task, gpointer source_object,
                                gpointer task_data, GCancellable* cancellable) {
  FlValue* list = fl_value_new_list();
  cups_dest_t* dests = nullptr;
  int num_dests = cupsGetDests(&dests);
  for (int i = 0; i < num_dests; i++) {
    fl_value_append_take(list, printer_info(&dests[i]));
  }
  cupsFreeDests(num_dests, dests);

  g_task_return_pointer(task, list,
                        reinterpret_cast<GDestroyNotify>(fl_value_unref));
}

// Runs on the main thread when the list is ready.
static void printer_list_done(GObject* source_object, GAsyncResult* result,
                              gpointer user_data) {
  auto* response_handle = static_cast<FlutterPrintFlutterPrintApiResponseHandle*>(
      g_task_get_task_data(G_TASK(result)));
  g_autoptr(FlValue) list = static_cast<FlValue*>(
      g_task_propagate_pointer(G_TASK(result), nullptr));
  flutter_print_flutter_print_api_respond_list_printers(response_handle, list);
}

void printer_list_start(FlutterPrintFlutterPrintApiResponseHandle* response_handle) {
  // The caller frees the handle when this returns, so the task keeps a ref.
  g_autoptr(GTask) task =
      g_task_new(nullptr, nullptr, printer_list_done, nullptr);
  g_task_set_task_data(task, g_object_ref(response_handle), g_object_unref);
  g_task_run_in_thread(task, printer_list_thread);
}
