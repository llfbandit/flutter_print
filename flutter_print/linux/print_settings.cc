#include "print_settings.h"

#include <cups/cups.h>

#include "cups_options.h"

void print_settings_fill(FlutterPrintPrintOptions* options,
                         GtkPrintSettings* settings, GtkPageSetup* page_setup) {
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

  // The portals read use-color, but the GTK dialog ignores it. So also select
  // the colour choice of the printer driver. GTK opens on the same default
  // printer as CUPS.
  const gboolean* color = flutter_print_print_options_get_color(options);
  if (color) {
    gtk_print_settings_set_use_color(settings, *color);
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

void print_settings_add_job_options(GtkPrintSettings* settings,
                                    GtkPageSetup* page_setup, int color,
                                    bool image) {
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

  // Same as in print_job.cc.
  if (image) gtk_print_settings_set(settings, "cups-print-scaling", "fit");
  gtk_print_settings_set(settings, "cups-cpi", "12");
  gtk_print_settings_set(settings, "cups-lpi", "7");
}
