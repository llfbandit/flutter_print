#pragma once

#define NOMINMAX
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "messages.h"

namespace flutter_print {

// ---------------------------------------------------------------------------
// Print rendering — image and PDF to a printer DC
// ---------------------------------------------------------------------------

// Render an image file to an open printer DC using GDI+ (falls back to WIC
// for formats GDI+ does not support, e.g. WebP, HEIC). |copies| is the number
// of copies to emit in software (>= 1); see RenderOrFallback.
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderImageToDC(HDC hdc, const std::wstring& path,
                                            int copies = 1);

// Render all pages of a PDF file to an open printer DC using PDFium.
// |copies| is the number of copies to emit in software (>= 1).
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderPdfToDC(HDC hdc, const std::wstring& path,
                                          int copies = 1);

// Convert |path| (plain-text file) to a PDF in memory and render it to |hdc|.
// |copies| is the number of copies to emit in software (>= 1).
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderTextToDC(HDC hdc, const std::wstring& path,
                                           int copies = 1);

// Routes |wPath| to the appropriate renderer based on file extension, or
// falls back to ShellExecuteW "printto" for unsupported types.
// Takes ownership of |hdc| — always calls DeleteDC before returning.
// |copies| is the number of copies the driver could NOT replicate natively and
// that must therefore be emitted in software (1 when the driver handles them).
// The ShellExecuteW fallback path does not honour |copies|.
std::optional<FlutterError> RenderOrFallback(HDC hdc,
                                              const std::wstring& wPath,
                                              const std::wstring& printerName,
                                              int copies = 1);

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
