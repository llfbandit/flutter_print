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

}  // namespace flutter_print
