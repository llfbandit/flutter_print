#ifndef FLUTTER_PRINT_PRINTER_LIST_H_
#define FLUTTER_PRINT_PRINTER_LIST_H_

#include "flutter_print_plugin_private.h"

// Lists the CUPS printers and answers |response_handle|. The work runs on a
// worker thread, because CUPS may query network printers.
void printer_list_start(FlutterPrintFlutterPrintApiResponseHandle* response_handle);

#endif  // FLUTTER_PRINT_PRINTER_LIST_H_
