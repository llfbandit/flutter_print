#pragma once

#include <windows.h>
#include <objbase.h>

#include <string>

namespace flutter_print {

std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const WCHAR* w);

// The default printer's name, or empty when there is none.
std::wstring DefaultPrinterName();

// Initializes COM on this thread until the end of the scope.
class ComScope {
 public:
  ComScope()
      : ok_(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {}
  ~ComScope() { if (ok_) CoUninitialize(); }
  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  bool ok_;
};

}  // namespace flutter_print
