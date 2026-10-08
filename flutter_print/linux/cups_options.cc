#include "cups_options.h"

#include <cups/cups.h>
#include <cups/ppd.h>
#include <glib/gstdio.h>
#include <cstring>

const char* duplex_sides(FlutterPrintPrintOptions* options) {
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

pwg_media_t* page_size_media(FlutterPrintPageSize* page_size) {
  // pwgMediaForSize takes hundredths of a millimetre. It returns a standard
  // size, or a custom one.
  double* width = flutter_print_page_size_get_width(page_size);
  double* height = flutter_print_page_size_get_height(page_size);
  if (width && height && *width > 0 && *height > 0) {
    return pwgMediaForSize((int)(*width * 100 + 0.5),
                           (int)(*height * 100 + 0.5));
  }

  const gchar* name = flutter_print_page_size_get_name(page_size);
  if (!name || name[0] == '\0') return nullptr;
  pwg_media_t* media = pwgMediaForPPD(name);
  return media ? media : pwgMediaForLegacy(name);
}

gchar* build_page_ranges(FlutterPrintPrintOptions* options) {
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

gchar* color_model_choice(const char* printer, bool color) {
  // GTK reads the same PPD file. libcups marks the PPD functions deprecated.
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
