#include "print_file.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <cstring>
#include <unistd.h>

struct PrintFile {
  gchar* path;
  gchar* temp_png;  // Null when the file needs no conversion.
};

// Returns true for the image formats CUPS can't print.
static bool needs_conversion(const char* path) {
  const char* dot = strrchr(path, '.');
  if (!dot) return false;
  return g_ascii_strcasecmp(dot, ".webp") == 0 ||
         g_ascii_strcasecmp(dot, ".heic") == 0 ||
         g_ascii_strcasecmp(dot, ".heif") == 0;
}

// Decodes the image with GDK-Pixbuf and saves it as a temp PNG. Returns the
// PNG path, or null and sets |error|. GDK_PIXBUF_ERROR_UNKNOWN_TYPE means
// no loader for the format is installed.
static gchar* convert_to_png(const char* path, GError** error) {
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_file(path, error);
  if (!pixbuf) return nullptr;

  // g_file_open_tmp creates a new file with a random name, so another user
  // can't plant a symlink at the path.
  g_autofree gchar* png = nullptr;
  int fd = g_file_open_tmp("flutter_print_XXXXXX.png", &png, error);
  if (fd < 0) return nullptr;
  close(fd);
  if (!gdk_pixbuf_save(pixbuf, png, "png", error, nullptr)) {
    g_remove(png);
    return nullptr;
  }
  return static_cast<gchar*>(g_steal_pointer(&png));
}

PrintFile* print_file_prepare(const char* path, const char** error_code,
                              gchar** error_message) {
  if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
    *error_code = "FILE_NOT_FOUND";
    *error_message = g_strdup_printf("File not found: %s", path);
    return nullptr;
  }

  gchar* temp_png = nullptr;
  if (needs_conversion(path)) {
    g_autoptr(GError) err = nullptr;
    temp_png = convert_to_png(path, &err);
    if (!temp_png) {
      bool unsupported =
          g_error_matches(err, GDK_PIXBUF_ERROR, GDK_PIXBUF_ERROR_UNKNOWN_TYPE);
      *error_code = unsupported ? "UNSUPPORTED_FILE" : "PRINT_ERROR";
      *error_message =
          g_strdup_printf("Cannot convert %s: %s", path, err->message);
      return nullptr;
    }
  }

  PrintFile* file = g_new0(PrintFile, 1);
  file->path = g_strdup(path);
  file->temp_png = temp_png;
  return file;
}

const char* print_file_path(const PrintFile* file) {
  return file->temp_png ? file->temp_png : file->path;
}

void print_file_free(PrintFile* file) {
  if (!file) return;
  if (file->temp_png) g_remove(file->temp_png);
  g_free(file->temp_png);
  g_free(file->path);
  g_free(file);
}
