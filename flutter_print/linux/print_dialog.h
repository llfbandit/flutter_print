#ifndef FLUTTER_PRINT_PRINT_DIALOG_H_
#define FLUTTER_PRINT_PRINT_DIALOG_H_

#include <gtk/gtk.h>

#include "flutter_print_plugin_private.h"

// Shows the GTK print dialog for |file_path|, filled in from |options| (may
// be null), and answers |response_handle| when the user prints or cancels.
// |parent| may be null.
void print_dialog_show(GtkWindow* parent, const gchar* file_path,
                       FlutterPrintPrintOptions* options,
                       FlutterPrintFlutterPrintApiResponseHandle* response_handle);

#endif  // FLUTTER_PRINT_PRINT_DIALOG_H_
