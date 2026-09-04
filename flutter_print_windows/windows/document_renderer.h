#pragma once

#define NOMINMAX
#include <windows.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "messages.h"

namespace flutter_print {

// One or more 1-based, inclusive page ranges (e.g. {{2, 6}, {9, 9}} for pages
// 2–6 and 9). An empty vector means "all pages".
using PageRanges = std::vector<std::pair<int, int>>;

// ---------------------------------------------------------------------------
// Print rendering — to a printer DC
// ---------------------------------------------------------------------------

// Renders |wPath| to |hdc| with the renderer for |mime|, which must satisfy
// IsRenderableMime. Caller retains ownership of |hdc|.
// |copies| is the number of copies the driver could NOT replicate natively and
// that must therefore be emitted in software (1 when the driver handles them).
// |ranges| restricts which pages are printed (all pages when empty); returns
// INVALID_PAGE_RANGE when it selects no page.
std::optional<FlutterError> RenderToDC(HDC hdc, const std::wstring& wPath,
                                       const std::string& mime, int copies,
                                       const PageRanges& ranges);

// Hands |wPath| to its associated application via the shell "print" verb, or
// "printto" |printerName| when non-empty. Print options are not honoured.
std::optional<FlutterError> ShellPrint(const std::wstring& wPath,
                                       const std::wstring& printerName);

// ---------------------------------------------------------------------------
// Preview rendering — for the Flutter Windows print dialog
// ---------------------------------------------------------------------------

// Read |path| as text, decode bytes honouring UTF-16 LE/BE, UTF-8 (BOM or
// plain), and the system ANSI code page (CP_ACP). Returns {} on read error.
std::wstring ReadTextFile(const std::wstring& path);

// Returns the number of pages in the PDF at |path|, or 0 on error.
// Thread-safe; PDFium access is serialised internally.
int GetPdfPageCount(const std::wstring& path);

// Renders page |pageIndex| (0-based) of the PDF at |path| at |dpi| resolution
// and returns the result as a PNG-encoded byte vector. Returns {} on error.
// Thread-safe; PDFium access is serialised internally.
std::vector<uint8_t> RenderPdfPageToPng(const std::wstring& path,
                                         int pageIndex,
                                         double dpi);

}  // namespace flutter_print
