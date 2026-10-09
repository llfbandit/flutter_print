#include "print_file.h"

#include <cairo-pdf.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gdk/gdk.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <unistd.h>

struct PrintFile {
  gchar* path;
  gchar* temp_pdf;  // The image as a PDF, or null for other files.
};

// Returns the content type of |path|, from its name and first bytes.
static gchar* content_type(const char* path) {
  guchar data[4096];
  gsize size = 0;
  FILE* file = fopen(path, "rb");
  if (file) {
    size = fread(data, 1, sizeof(data), file);
    fclose(file);
  }
  return g_content_type_guess(path, data, size, nullptr);
}

// Draws the image at |path| on a one-page PDF of the same size, upright
// from its EXIF data. Returns the PDF path, or null and sets |error|.
// GDK_PIXBUF_ERROR_UNKNOWN_TYPE means no loader for the format is installed.
static gchar* convert_to_pdf(const char* path, bool jpeg, GError** error) {
  g_autoptr(GdkPixbuf) loaded = gdk_pixbuf_new_from_file(path, error);
  if (!loaded) return nullptr;
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_apply_embedded_orientation(loaded);
  int width = gdk_pixbuf_get_width(pixbuf);
  int height = gdk_pixbuf_get_height(pixbuf);

  // g_file_open_tmp creates a new file with a random name, so another user
  // can't plant a symlink at the path.
  g_autofree gchar* pdf = nullptr;
  int fd = g_file_open_tmp("flutter_print_XXXXXX.pdf", &pdf, error);
  if (fd < 0) return nullptr;
  close(fd);

  // One pixel is one point. CUPS scales the page to the paper.
  cairo_surface_t* surface = cairo_pdf_surface_create(pdf, width, height);
  cairo_surface_t* image =
      gdk_cairo_surface_create_from_pixbuf(pixbuf, 1, nullptr);
  // Keep a JPEG as JPEG in the PDF, unless EXIF turned it.
  gchar* data = nullptr;
  gsize size = 0;
  if (jpeg && pixbuf == loaded && g_file_get_contents(path, &data, &size,
                                                      nullptr)) {
    cairo_surface_set_mime_data(image, CAIRO_MIME_TYPE_JPEG,
                                reinterpret_cast<unsigned char*>(data), size,
                                g_free, data);
  }
  cairo_t* cr = cairo_create(surface);
  cairo_set_source_surface(cr, image, 0, 0);
  cairo_paint(cr);
  cairo_destroy(cr);
  cairo_surface_destroy(image);
  cairo_surface_finish(surface);
  cairo_status_t status = cairo_surface_status(surface);
  cairo_surface_destroy(surface);

  if (status != CAIRO_STATUS_SUCCESS) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s",
                cairo_status_to_string(status));
    g_remove(pdf);
    return nullptr;
  }
  return static_cast<gchar*>(g_steal_pointer(&pdf));
}

PrintFile* print_file_prepare(const char* path, const char** error_code,
                              gchar** error_message) {
  if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
    *error_code = "FILE_NOT_FOUND";
    *error_message = g_strdup_printf("File not found: %s", path);
    return nullptr;
  }

  // Print images as a PDF. CUPS sends some images (JPEG) to the printer as
  // is, and many printers then ignore the orientation and scaling. CUPS also
  // can't print some formats (WebP, HEIC, GIF, BMP).
  gchar* temp_pdf = nullptr;
  g_autofree gchar* type = content_type(path);
  g_autofree gchar* mime = g_content_type_get_mime_type(type);
  if (mime && g_str_has_prefix(mime, "image/")) {
    g_autoptr(GError) err = nullptr;
    temp_pdf = convert_to_pdf(path, g_strcmp0(mime, "image/jpeg") == 0, &err);
    if (!temp_pdf) {
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
  file->temp_pdf = temp_pdf;
  return file;
}

const char* print_file_path(const PrintFile* file) {
  return file->temp_pdf ? file->temp_pdf : file->path;
}

bool print_file_is_image(const PrintFile* file) {
  return file->temp_pdf != nullptr;
}

void print_file_free(PrintFile* file) {
  if (!file) return;
  if (file->temp_pdf) g_remove(file->temp_pdf);
  g_free(file->temp_pdf);
  g_free(file->path);
  g_free(file);
}
