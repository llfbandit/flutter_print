#pragma once

#define NOMINMAX
#include <windows.h>

#include <string>

namespace flutter_print {

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const WCHAR* w);

// ---------------------------------------------------------------------------
// File-type detection
// ---------------------------------------------------------------------------

std::string GetMimeType(const std::wstring& path);

// True for the types the plugin renders itself: images, PDF and text.
bool IsRenderableMime(const std::string& mime);

// ---------------------------------------------------------------------------
// Printers
// ---------------------------------------------------------------------------

// The default printer's name, or empty when there is none.
std::wstring DefaultPrinterName();

}  // namespace flutter_print
