#ifndef FLUTTER_PRINT_PRINT_JOB_H_
#define FLUTTER_PRINT_PRINT_JOB_H_

#include "flutter_print_plugin_private.h"

// Sends |file_path| to CUPS with |options| (may be null) and answers
// |response_handle|. The work runs on a worker thread, so a slow conversion
// or CUPS server doesn't freeze the app.
void print_job_start(const gchar* file_path, FlutterPrintPrintOptions* options,
                     FlutterPrintFlutterPrintApiResponseHandle* response_handle);

#endif  // FLUTTER_PRINT_PRINT_JOB_H_
