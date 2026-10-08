#ifndef FLUTTER_PRINT_PRINT_FILE_H_
#define FLUTTER_PRINT_PRINT_FILE_H_

#include <glib.h>

// A file ready for CUPS. CUPS can't print WebP or HEIC images, so they become
// a temp PNG.
typedef struct PrintFile PrintFile;

// Checks that |path| exists and converts it when needed. On error, returns
// null and sets |error_code| and |error_message| (free it with g_free).
PrintFile* print_file_prepare(const char* path, const char** error_code,
                              gchar** error_message);

// Returns the path to send to CUPS.
const char* print_file_path(const PrintFile* file);

// Deletes the temp PNG and frees |file|.
void print_file_free(PrintFile* file);

#endif  // FLUTTER_PRINT_PRINT_FILE_H_
