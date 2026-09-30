#include "flutter_print_utils.h"

#include <winspool.h>

#include <iterator>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winspool.lib")

namespace flutter_print {

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

std::wstring DefaultPrinterName() {
  WCHAR buf[512] = {};
  DWORD sz = static_cast<DWORD>(std::size(buf));
  GetDefaultPrinterW(buf, &sz);
  return buf;
}

}  // namespace flutter_print
