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

// Prints |wPath| to |hdc|. |mime| must pass IsRenderableMime.
// |copies| is the number of copies to draw (see CreatePrinterDC).
// Returns INVALID_PAGE_RANGE when |ranges| selects no page.
std::optional<FlutterError> RenderToDC(HDC hdc, const std::wstring& wPath,
                                       const std::string& mime, int copies,
                                       const PageRanges& ranges);

// Prints |wPath| with its default app, on |printerName| when not empty.
// The app ignores the print options.
std::optional<FlutterError> ShellPrint(const std::wstring& wPath,
                                       const std::wstring& printerName);

// Reads a text file in UTF-16, UTF-8 or the ANSI code page. Returns {} on
// error.
std::wstring ReadTextFile(const std::wstring& path);

// Returns the PDF page count, or 0 on error. Thread-safe.
int GetPdfPageCount(const std::wstring& path);

// Renders a PDF page (0-based) to PNG bytes at |dpi|. Returns {} on error.
// Thread-safe.
std::vector<uint8_t> RenderPdfPageToPng(const std::wstring& path,
                                         int pageIndex,
                                         double dpi);

}  // namespace flutter_print
