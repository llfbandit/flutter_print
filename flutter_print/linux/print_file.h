#ifndef FLUTTER_PRINT_PRINT_FILE_H_
#define FLUTTER_PRINT_PRINT_FILE_H_

#include <glib.h>

// A file ready for CUPS. Images become a temp PDF.
typedef struct PrintFile PrintFile;

// Checks that |path| exists and converts it when needed. On error, returns
// null and sets |error_code| and |error_message| (free it with g_free).
PrintFile* print_file_prepare(const char* path, const char** error_code,
                              gchar** error_message);

// Returns the path to send to CUPS.
const char* print_file_path(const PrintFile* file);

// Returns true when the file is an image. Send it with print-scaling=fit, so
// it fills the page.
bool print_file_is_image(const PrintFile* file);

// Deletes the temp PDF and frees |file|.
void print_file_free(PrintFile* file);

#endif  // FLUTTER_PRINT_PRINT_FILE_H_
