#ifndef FLUTTER_PRINT_PRINT_SETTINGS_H_
#define FLUTTER_PRINT_PRINT_SETTINGS_H_

#include <gtk/gtk.h>

#include "flutter_print_plugin_private.h"

// Fills in the print dialog |settings| and |page_setup| from |options| (may
// be null).
void print_settings_fill(FlutterPrintPrintOptions* options,
                         GtkPrintSettings* settings, GtkPageSetup* page_setup);

// GTK expects the app to draw the pages, but this plugin sends the file as
// is. So this adds the choices that GTK leaves to the app as CUPS options:
// page ranges, orientation, and |color| (1, 0, or -1 when unset) when the
// driver has no colour choice. It also shrinks an |image| larger than the page,
// and sets the text size. GTK sends the "cups-" settings to CUPS.
void print_settings_add_job_options(GtkPrintSettings* settings,
                                    GtkPageSetup* page_setup, int color,
                                    bool image);

#endif  // FLUTTER_PRINT_PRINT_SETTINGS_H_
