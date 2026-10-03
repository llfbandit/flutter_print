#pragma once

#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "messages.h"

namespace flutter_print {

// 1-based, inclusive page ranges, e.g. {{2, 6}, {9, 9}}. Empty means all pages.
using PageRanges = std::vector<std::pair<int, int>>;

enum class FileKind {
  kPdf,
  kImage,     // Any format WIC decodes. TIFF frames are pages.
  kMetafile,  // EMF or WMF, printed as vectors.
  kText,
  kOther,     // Printed by the default app.
};

// Detects the kind from the file content, not the extension.
FileKind DetectFileKind(const std::wstring& path);

// Prints |wPath| to |hdc|. |kind| must not be kOther.
// |copies| is the number of copies to draw (see CreatePrinterDC).
// Returns INVALID_PAGE_RANGE when |ranges| selects no page.
std::optional<FlutterError> RenderToDC(HDC hdc, const std::wstring& wPath,
                                       FileKind kind, int copies,
                                       const PageRanges& ranges);

// Prints |wPath| with its default app, on |printerName| when not empty.
// The app ignores the print options.
std::optional<FlutterError> ShellPrint(const std::wstring& wPath,
                                       const std::wstring& printerName);

class Document;

// A file laid out like print for a printer, kept open while the dialog shows
// it. Use it from one thread.
class Preview {
 public:
  // Opens |path| for the printer and paper of |ic| (see CreatePrinterIC), and
  // takes |ic|. Returns null on error.
  static std::unique_ptr<Preview> Open(HDC ic, const std::wstring& path,
                                       FileKind kind);
  ~Preview();
  Preview(const Preview&) = delete;
  Preview& operator=(const Preview&) = delete;

  int PageCount() const;

  // Renders a page (0-based) as the printer prints it: the sheet fitted in
  // |maxWidth| x |maxHeight| pixels, as PNG bytes. |region|, in the pixels of
  // that sheet, renders only that part of it: to zoom in without rendering
  // the whole sheet. Returns {} on error.
  std::vector<uint8_t> RenderPage(int index, int maxWidth, int maxHeight,
                                  const RECT* region = nullptr);

 private:
  Preview(HDC ic, std::unique_ptr<Document> doc);

  HDC ic_;
  std::unique_ptr<Document> doc_;
};

}  // namespace flutter_print
