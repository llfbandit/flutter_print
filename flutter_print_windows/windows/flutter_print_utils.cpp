#include "flutter_print_utils.h"

#include <shellapi.h>
#include <winspool.h>

#include <iterator>

namespace flutter_print {

std::wstring MultiByteToWide(std::string_view s, UINT codepage, DWORD flags) {
  const int len = static_cast<int>(s.size());
  const int n = MultiByteToWideChar(codepage, flags, s.data(), len, nullptr, 0);
  if (n <= 0) return {};
  std::wstring w(n, L'\0');
  MultiByteToWideChar(codepage, flags, s.data(), len, &w[0], n);
  return w;
}

std::wstring Utf8ToWide(const std::string& s) {
  return MultiByteToWide(s, CP_UTF8);
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

DWORD ShellRun(const wchar_t* verb, const std::wstring& path,
               const wchar_t* params, int show, HANDLE* process) {
  // Some verbs run in COM handlers, e.g. packaged apps.
  ComScope com;
  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  // NOASYNC: finish any DDE talk before returning, as the caller pumps no
  // messages. FLAG_NO_UI: show no shell error dialog.
  sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI |
              (process ? SEE_MASK_NOCLOSEPROCESS : 0);
  sei.lpVerb       = verb;
  sei.lpFile       = path.c_str();
  sei.lpParameters = params;
  sei.nShow        = show;
  if (!ShellExecuteExW(&sei)) {
    const DWORD e = GetLastError();
    return e ? e : ERROR_GEN_FAILURE;
  }
  if (process) *process = sei.hProcess;
  return 0;
}

SerialWorker::SerialWorker() : thread_([this] { Run(); }) {}

SerialWorker::~SerialWorker() { Stop(); }

void SerialWorker::Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mtx_);
    if (stopping_) return;
    tasks_.push_back(std::move(task));
  }
  cv_.notify_one();
}

void SerialWorker::Stop(std::function<void()> last) {
  {
    std::lock_guard<std::mutex> lock(mtx_);
    if (stopping_) return;
    stopping_ = true;
    tasks_.clear();
    if (last) tasks_.push_back(std::move(last));
  }
  cv_.notify_one();
  thread_.join();
}

void SerialWorker::Run() {
  ComScope com;
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mtx_);
      cv_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
      if (tasks_.empty()) return;
      task = std::move(tasks_.front());
      tasks_.pop_front();
    }
    task();
  }
}

}  // namespace flutter_print
