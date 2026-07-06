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
// Print rendering — image and PDF to a printer DC
// ---------------------------------------------------------------------------

// Render an image file to an open printer DC using GDI+ (falls back to WIC
// for formats GDI+ does not support, e.g. WebP, HEIC). |copies| is the number
// of copies to emit in software (>= 1); see RenderOrFallback. An image is a
// single page: it is emitted only when |ranges| is empty or includes page 1.
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderImageToDC(HDC hdc, const std::wstring& path,
                                            int copies = 1,
                                            const PageRanges& ranges = {});

// Render a PDF file to an open printer DC using PDFium. Only pages selected by
// |ranges| are emitted (all pages when empty). |copies| is the number of copies
// to emit in software (>= 1).
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderPdfToDC(HDC hdc, const std::wstring& path,
                                          int copies = 1,
                                          const PageRanges& ranges = {});

// Convert |path| (plain-text file) to a PDF in memory and render it to |hdc|.
// Only pages selected by |ranges| are emitted (all pages when empty). |copies|
// is the number of copies to emit in software (>= 1).
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderTextToDC(HDC hdc, const std::wstring& path,
                                           int copies = 1,
                                           const PageRanges& ranges = {});

// Routes |wPath| to the appropriate renderer based on file extension, or
// falls back to ShellExecuteW "printto" for unsupported types.
// Takes ownership of |hdc| — always calls DeleteDC before returning.
// |copies| is the number of copies the driver could NOT replicate natively and
// that must therefore be emitted in software (1 when the driver handles them).
// |ranges| restricts which pages are printed (all pages when empty).
// The ShellExecuteW fallback path honours neither |copies| nor |ranges|.
std::optional<FlutterError> RenderOrFallback(HDC hdc,
                                              const std::wstring& wPath,
                                              const std::string& mime,
                                              const std::wstring& printerName,
                                              int copies = 1,
                                              const PageRanges& ranges = {});

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
