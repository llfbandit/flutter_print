#pragma once

#include <windows.h>

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

// Reads a text file in UTF-16, UTF-8 or the ANSI code page. Returns {} on
// error.
std::wstring ReadTextFile(const std::wstring& path);

// Returns the page count of a PDF, image or metafile, or 0 on error.
// Thread-safe.
int GetPageCount(const std::wstring& path, FileKind kind);

// Renders a page (0-based) of a PDF, image or metafile to PNG bytes on white.
// |dpi| sets the PDF scale. Images and metafiles fit in a 12-inch square at
// |dpi|, but bitmaps are never enlarged. Returns {} on error. Thread-safe.
std::vector<uint8_t> RenderPageToPng(const std::wstring& path, FileKind kind,
                                     int pageIndex, double dpi);

}  // namespace flutter_print
