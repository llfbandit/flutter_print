#ifndef FLUTTER_PRINT_PRINT_PORTAL_H_
#define FLUTTER_PRINT_PRINT_PORTAL_H_

#include <gtk/gtk.h>

#include "flutter_print_plugin_private.h"

// Returns true when the app runs in a Flatpak or Snap sandbox, or when
// GTK_USE_PORTAL=1. A sandbox may block CUPS, so the print portal of the
// desktop must show the dialog and print.
bool print_portal_should_use();

// Shows the print dialog of the desktop portal for |file_path|, filled in
// from |options| (may be null), and answers |response_handle| when the user
// prints or cancels. |parent| may be null.
void print_portal_show(GtkWindow* parent, const gchar* file_path,
                       FlutterPrintPrintOptions* options,
                       FlutterPrintFlutterPrintApiResponseHandle* response_handle);

#endif  // FLUTTER_PRINT_PRINT_PORTAL_H_
