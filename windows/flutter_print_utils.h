#pragma once

#define NOMINMAX
#include <windows.h>
#include <winspool.h>

#include <optional>
#include <string>

#include "messages.h"

namespace flutter_print {

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const WCHAR* w);

// ---------------------------------------------------------------------------
// File-type detection
// ---------------------------------------------------------------------------

bool EndsWithIgnoreCase(const std::wstring& path, const wchar_t* ext);
bool IsImageFile(const std::wstring& path);
bool IsPdfFile(const std::wstring& path);

// ---------------------------------------------------------------------------
// DEVMODE / printer
// ---------------------------------------------------------------------------

int     NameToDMPaper(const std::string& name);
void    ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options);

// Returns a GlobalAlloc'd DEVMODE initialised from the printer's native
// settings with |options| overlaid. Caller must GlobalFree the handle.
HGLOBAL BuildDevMode(const std::wstring& printerName, const PrintOptions& options);

// Creates a printer DC for |printerName| with |options| applied.
// Caller must DeleteDC the returned handle.
HDC     CreatePrinterDC(const std::wstring& printerName, const PrintOptions& options);

// Builds a GlobalAlloc'd DEVNAMES block that pre-selects |printerName| in
// a print dialog. Caller must GlobalFree the handle.
HGLOBAL BuildDevNames(const std::wstring& printerName);

// Pair of GlobalAlloc'd handles ready to pass directly to PrintDlg / PrintDlgEx.
// - If options.printer_name() is set, hDevNames pre-selects that printer and
//   hDevMode is its native DEVMODE with options overlaid.
// - Otherwise hDevNames is nullptr (dialog picks the system default) and
//   hDevMode is a bare DEVMODE with options applied.
// Caller must GlobalFree both handles (nullptr handles are safe to free).
struct PrintDialogHandles {
  HGLOBAL hDevMode  = nullptr;
  HGLOBAL hDevNames = nullptr;
};
PrintDialogHandles BuildDialogHandles(const PrintOptions& options);

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Render an image file to an open printer DC using GDI+, scaled to fit.
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderImageToDC(HDC hdc, const std::wstring& path);

// Render all pages of a PDF file to an open printer DC using PDFium.
// Caller retains ownership of |hdc|.
std::optional<FlutterError> RenderPdfToDC(HDC hdc, const std::wstring& path);

// Routes |wPath| to the appropriate renderer based on file extension, or
// falls back to ShellExecuteW "printto" for unsupported types.
// Takes ownership of |hdc| — always calls DeleteDC before returning.
std::optional<FlutterError> RenderOrFallback(HDC hdc,
                                              const std::wstring& wPath,
                                              const std::wstring& printerName);

}  // namespace flutter_print
