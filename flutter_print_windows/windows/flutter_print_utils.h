#pragma once

#include <windows.h>

#include <string>

namespace flutter_print {

std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const WCHAR* w);

// Detects the MIME type from the file content and extension.
std::string GetMimeType(const std::wstring& path);

// True for the types the plugin renders itself: images, PDF and text.
bool IsRenderableMime(const std::string& mime);

// The default printer's name, or empty when there is none.
std::wstring DefaultPrinterName();

}  // namespace flutter_print
