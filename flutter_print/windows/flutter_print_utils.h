#pragma once

#include <windows.h>
#include <objbase.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

namespace flutter_print {

// Converts |s| from |codepage|. Returns {} on error, e.g. invalid characters
// with MB_ERR_INVALID_CHARS.
std::wstring MultiByteToWide(std::string_view s, UINT codepage,
                             DWORD flags = 0);
std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const WCHAR* w);

// The default printer's name, or empty when there is none.
std::wstring DefaultPrinterName();

// Runs the shell |verb| on |path| with no error UI. Returns 0 or the error
// code. When |process| is not null, it gets the started process, if any; the
// caller closes it.
DWORD ShellRun(const wchar_t* verb, const std::wstring& path,
               const wchar_t* params, int show, HANDLE* process = nullptr);

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

// Runs tasks in order on its own thread, with COM on.
class SerialWorker {
 public:
  SerialWorker();
  ~SerialWorker();  // Drops the queued tasks.
  SerialWorker(const SerialWorker&) = delete;
  SerialWorker& operator=(const SerialWorker&) = delete;

  void Post(std::function<void()> task);

  // Drops the queued tasks, runs |last| on the thread, and waits for it to
  // end. Later tasks are dropped.
  void Stop(std::function<void()> last = nullptr);

 private:
  void Run();

  std::mutex mtx_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;  // Last: it starts once the rest is ready.
};

}  // namespace flutter_print
