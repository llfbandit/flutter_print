#include "flutter_print_utils.h"

#include <urlmon.h>
#include <winspool.h>
#pragma comment(lib, "urlmon.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winspool.lib")

namespace flutter_print {

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 1) return {};
  std::wstring w(n - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

std::string WideToUtf8(const WCHAR* w) {
  if (!w || w[0] == L'\0') return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return {};
  std::string s(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

// ---------------------------------------------------------------------------
// File-type detection
// ---------------------------------------------------------------------------

std::string GetMimeType(const std::wstring& path) {
  BYTE header[256] = {};
  DWORD bytesRead = 0;
  HANDLE hFile = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hFile != INVALID_HANDLE_VALUE) {
    ReadFile(hFile, header, sizeof(header), &bytesRead, nullptr);
    CloseHandle(hFile);
  }

  LPWSTR mimeW = nullptr;
  HRESULT hr = FindMimeFromData(
      nullptr,
      path.c_str(),
      bytesRead > 0 ? header : nullptr,
      bytesRead,
      nullptr,
      FMFD_DEFAULT,
      &mimeW,
      0);

  if (FAILED(hr) || !mimeW) return "application/octet-stream";
  std::string mime = WideToUtf8(mimeW);
  CoTaskMemFree(mimeW);
  return mime;
}

bool IsRenderableMime(const std::string& mime) {
  return mime.rfind("image/", 0) == 0 || mime == "application/pdf" ||
         mime.rfind("text/", 0) == 0;
}

// ---------------------------------------------------------------------------
// Printers
// ---------------------------------------------------------------------------

std::wstring DefaultPrinterName() {
  WCHAR buf[512] = {};
  DWORD sz = static_cast<DWORD>(sizeof(buf) / sizeof(WCHAR));
  GetDefaultPrinterW(buf, &sz);
  return buf;
}

}  // namespace flutter_print
