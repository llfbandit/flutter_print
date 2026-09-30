#include "flutter_print_plugin.h"

#include "document_renderer.h"
#include "flutter_print_utils.h"
#include "printer_setup.h"

#include <shellapi.h>
#include <algorithm>
#include <climits>
#include <thread>
#include <unordered_set>

#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "shell32.lib")

namespace flutter_print {

namespace {

using WinResult =
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

// Returns the page ranges of |options|. Empty means all pages.
PageRanges ExtractPageRanges(const PrintOptions* options) {
  PageRanges ranges;
  const flutter::EncodableList* list =
      options ? options->page_ranges() : nullptr;
  if (!list) return ranges;
  // Clamp so huge values don't wrap in an int.
  const auto clamp = [](int64_t v) {
    return static_cast<int>(std::clamp<int64_t>(v, 0, INT_MAX));
  };
  for (const auto& item : *list) {
    const auto* custom = std::get_if<flutter::CustomEncodableValue>(&item);
    if (!custom) continue;
    const auto& pr = std::any_cast<const PageRange&>(*custom);
    ranges.emplace_back(clamp(pr.start()), clamp(pr.end()));
  }
  return ranges;
}

// Fills |buf| with PRINTER_INFO_2W entries. Returns the entry count.
DWORD EnumPrinterInfos(std::vector<BYTE>& buf) {
  constexpr DWORD kFlags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
  // Retry when a printer is added between the size query and the read.
  for (int attempt = 0; attempt < 5; ++attempt) {
    DWORD needed = 0, returned = 0;
    EnumPrintersW(kFlags, nullptr, 2, nullptr, 0, &needed, &returned);
    if (needed == 0) return 0;
    buf.resize(needed);
    if (EnumPrintersW(kFlags, nullptr, 2, buf.data(), needed, &needed,
                      &returned))
      return returned;
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) return 0;
  }
  return 0;
}

// True for the ports of virtual printers: PORTPROMPT: (Print to PDF, XPS…),
// nul: (OneNote) and NULPORT:.
bool IsVirtualPort(const WCHAR* port) {
  if (!port) return false;
  for (const WCHAR* name : {L"PORTPROMPT:", L"nul:", L"NULPORT:"}) {
    if (_wcsicmp(port, name) == 0) return true;
  }
  return false;
}

ColorCapability QueryColor(const WCHAR* name, const WCHAR* port) {
  // Virtual printers report color like real ones: check the port first.
  if (IsVirtualPort(port)) return ColorCapability::kEnforced;

  const DWORD r = DeviceCapabilitiesW(name, port, DC_COLORDEVICE, nullptr, nullptr);
  if (r == 1) return ColorCapability::kSupported;
  if (r != 0) return ColorCapability::kUnknown;
  // A few virtual printers report monochrome but set DM_COLOR.
  const std::vector<BYTE> dm = GetDefaultDevMode(name);
  if (!dm.empty() &&
      (reinterpret_cast<const DEVMODE*>(dm.data())->dmFields & DM_COLOR))
    return ColorCapability::kEnforced;
  return ColorCapability::kMonochrome;
}

PrinterCapabilities QueryCapabilities(const WCHAR* name, const WCHAR* port) {
  constexpr DWORD kUnsupported = static_cast<DWORD>(-1);

  std::optional<bool> duplex;
  if (DWORD r = DeviceCapabilitiesW(name, port, DC_DUPLEX, nullptr, nullptr);
      r != kUnsupported)
    duplex = r == 1;

  std::optional<int64_t> maxCopies;
  if (DWORD r = DeviceCapabilitiesW(name, port, DC_COPIES, nullptr, nullptr);
      r != kUnsupported && r > 0)
    maxCopies = r;

  flutter::EncodableList pageSizes;
  const DWORD count = DeviceCapabilitiesW(name, port, DC_PAPERS, nullptr, nullptr);
  if (count != kUnsupported && count > 0) {
    std::vector<WORD> papers(count);
    DeviceCapabilitiesW(name, port, DC_PAPERS,
                        reinterpret_cast<LPWSTR>(papers.data()), nullptr);
    const std::unordered_set<WORD> supported(papers.begin(), papers.end());
    for (const auto& [id, paperName] : kKnownPapers) {
      if (supported.count(id))
        pageSizes.push_back(flutter::EncodableValue(std::string(paperName)));
    }
  }

  return PrinterCapabilities(QueryColor(name, port),
                             duplex ? &*duplex : nullptr,
                             maxCopies ? &*maxCopies : nullptr, pageSizes);
}

// Returns args[key] when it holds a T, else null.
template <typename T>
const T* GetArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : std::get_if<T>(&it->second);
}

// Returns the "filePath" argument, or reports INVALID_ARGS and returns nullopt.
std::optional<std::wstring> GetFilePathArg(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>& result) {
  const auto* path = GetArg<std::string>(args, "filePath");
  if (!path) {
    result.Error("INVALID_ARGS", "Missing filePath");
    return std::nullopt;
  }
  return Utf8ToWide(*path);
}

// Runs |work| on a worker thread and replies with the value it returns.
template <typename Work>
void ReplyAsync(std::shared_ptr<std::atomic<bool>> alive, WinResult result,
                Work work) {
  std::thread([alive = std::move(alive), result = std::move(result),
               work = std::move(work)]() mutable {
    const flutter::EncodableValue value = work();
    if (alive->load()) result->Success(value);
  }).detach();
}

}  // namespace

// static
void FlutterPrintPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<FlutterPrintPlugin>();
  FlutterPrintApi::SetUp(registrar->messenger(), plugin.get());

  // Windows channel, next to the Pigeon one.
  plugin->windows_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_print_windows",
          &flutter::StandardMethodCodec::GetInstance());
  plugin->windows_channel_->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleWindowsMethod(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterPrintPlugin::FlutterPrintPlugin()
    : alive_(std::make_shared<std::atomic<bool>>(true)) {}

FlutterPrintPlugin::~FlutterPrintPlugin() {
  *alive_ = false;
}

// ---------------------------------------------------------------------------
// FlutterPrintApi
// ---------------------------------------------------------------------------

void FlutterPrintPlugin::Print(
    const std::string& file_path, const PrintOptions* options,
    std::function<void(std::optional<FlutterError> reply)> result) {
  // Print off the platform thread to keep the UI responsive. Copy |options|:
  // the caller frees it on return.
  std::optional<PrintOptions> optionsCopy;
  if (options) optionsCopy = *options;
  std::thread([this, file_path, optionsCopy = std::move(optionsCopy),
               result = std::move(result), alive = alive_]() mutable {
    auto reply = PrintInternal(file_path,
                               optionsCopy ? &*optionsCopy : nullptr);
    if (alive->load()) result(std::move(reply));
  }).detach();
}

std::optional<FlutterError> FlutterPrintPlugin::PrintInternal(
    const std::string& file_path, const PrintOptions* options) {
  const std::wstring wPath = Utf8ToWide(file_path);
  if (GetFileAttributesW(wPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    return FlutterError("FILE_NOT_FOUND", "File not found: " + file_path);

  const std::string* pn = options ? options->printer_address() : nullptr;
  std::wstring wPrinter = (pn && !pn->empty()) ? Utf8ToWide(*pn) : std::wstring{};

  // Other file types go to their default app.
  const FileKind kind = DetectFileKind(wPath);
  if (kind == FileKind::kOther) return ShellPrint(wPath, wPrinter);

  if (wPrinter.empty()) wPrinter = DefaultPrinterName();
  if (wPrinter.empty())
    return FlutterError("PRINTER_ERROR", "No printer available");

  // Null |options| keeps the printer defaults.
  int softwareCopies = 1;
  HDC hdc = CreatePrinterDC(wPrinter, options, &softwareCopies);
  if (!hdc)
    return FlutterError("PRINTER_ERROR",
                        "Cannot create printer DC for: " +
                            WideToUtf8(wPrinter.c_str()));
  auto err = RenderToDC(hdc, wPath, kind, softwareCopies,
                        ExtractPageRanges(options));
  DeleteDC(hdc);
  return err;
}

void FlutterPrintPlugin::PrintPreview(
    const std::string& /*file_path*/, const PrintOptions* /*options*/,
    std::function<void(std::optional<FlutterError> reply)> result) {
  // Dart shows the preview dialog.
  result(std::nullopt);
}

void FlutterPrintPlugin::PickPrinter(
    std::function<void(ErrorOr<std::optional<PrinterInfo>>)> result) {
  result(std::optional<PrinterInfo>(std::nullopt));
}

void FlutterPrintPlugin::ListPrinters(
    std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  // Enumerate off the platform thread: network printers can block.
  std::thread([result = std::move(result), alive = alive_]() {
    std::vector<BYTE> buf;
    const DWORD count = EnumPrinterInfos(buf);
    const auto* info = reinterpret_cast<const PRINTER_INFO_2W*>(buf.data());
    const std::wstring defaultPrinter = DefaultPrinterName();

    flutter::EncodableList printers;
    for (DWORD i = 0; i < count; ++i) {
      const WCHAR* name = info[i].pPrinterName;
      if (!name) continue;

      std::string details;
      if (info[i].pComment) details = WideToUtf8(info[i].pComment);
      const std::string nameUtf8 = WideToUtf8(name);
      const bool available = !(info[i].Status & PRINTER_STATUS_OFFLINE);
      printers.push_back(flutter::CustomEncodableValue(PrinterInfo(
          nameUtf8, &nameUtf8, details.empty() ? nullptr : &details,
          name == defaultPrinter, QueryCapabilities(name, info[i].pPortName),
          &available)));
    }
    if (alive->load()) result(std::move(printers));
  }).detach();
}

// ---------------------------------------------------------------------------
// Windows channel
// ---------------------------------------------------------------------------

void FlutterPrintPlugin::HandleWindowsMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call, WinResult result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }

  const std::string& method = call.method_name();
  if (method == "getFileKind")        return HandleGetFileKind(*args, std::move(result));
  if (method == "getPageCount")       return HandleGetPageCount(*args, std::move(result));
  if (method == "renderPageToPng")    return HandleRenderPageToPng(*args, std::move(result));
  if (method == "decodeTextFile")     return HandleDecodeTextFile(*args, std::move(result));
  if (method == "getMinimumMargins")  return HandleGetMinimumMargins(*args, std::move(result));
  if (method == "openInDefaultApp")   return HandleOpenInDefaultApp(*args, std::move(result));
  result->NotImplemented();
}

void FlutterPrintPlugin::HandleGetFileKind(const flutter::EncodableMap& args,
                                           WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  ReplyAsync(alive_, std::move(result), [wPath = std::move(*wPath)] {
    // Dart previews metafiles like images.
    switch (DetectFileKind(wPath)) {
      case FileKind::kPdf:      return flutter::EncodableValue("pdf");
      case FileKind::kImage:
      case FileKind::kMetafile: return flutter::EncodableValue("image");
      case FileKind::kText:     return flutter::EncodableValue("text");
      default:                  return flutter::EncodableValue("other");
    }
  });
}

void FlutterPrintPlugin::HandleGetPageCount(const flutter::EncodableMap& args,
                                            WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  ReplyAsync(alive_, std::move(result), [wPath = std::move(*wPath)] {
    return flutter::EncodableValue(GetPageCount(wPath, DetectFileKind(wPath)));
  });
}

void FlutterPrintPlugin::HandleRenderPageToPng(
    const flutter::EncodableMap& args, WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  const auto* pageIndex = GetArg<int32_t>(args, "pageIndex");
  const auto* dpi = GetArg<double>(args, "dpi");
  ReplyAsync(alive_, std::move(result),
             [wPath = std::move(*wPath), pageIndex = pageIndex ? *pageIndex : 0,
              dpi = dpi ? *dpi : 150.0] {
               auto png = RenderPageToPng(wPath, DetectFileKind(wPath),
                                          pageIndex, dpi);
               return png.empty() ? flutter::EncodableValue()
                                  : flutter::EncodableValue(std::move(png));
             });
}

void FlutterPrintPlugin::HandleDecodeTextFile(const flutter::EncodableMap& args,
                                              WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  ReplyAsync(alive_, std::move(result), [wPath = std::move(*wPath)] {
    return flutter::EncodableValue(WideToUtf8(ReadTextFile(wPath).c_str()));
  });
}

void FlutterPrintPlugin::HandleGetMinimumMargins(
    const flutter::EncodableMap& args, WinResult result) {
  const auto* printer = GetArg<std::string>(args, "printerName");
  if (!printer) {
    result->Error("INVALID_ARGS", "Missing printerName");
    return;
  }
  const auto* paperName = GetArg<std::string>(args, "paperSizeName");
  const auto* width = GetArg<double>(args, "paperWidth");
  const auto* height = GetArg<double>(args, "paperHeight");
  ReplyAsync(alive_, std::move(result),
             [wPrinter = Utf8ToWide(*printer),
              paperName = paperName ? *paperName : std::string{},
              width = width ? *width : 0.0, height = height ? *height : 0.0] {
               auto m = GetMinimumMargins(wPrinter, paperName, width, height);
               if (!m) return flutter::EncodableValue();
               return flutter::EncodableValue(flutter::EncodableMap{
                   {flutter::EncodableValue("left"),   flutter::EncodableValue(m->left)},
                   {flutter::EncodableValue("top"),    flutter::EncodableValue(m->top)},
                   {flutter::EncodableValue("right"),  flutter::EncodableValue(m->right)},
                   {flutter::EncodableValue("bottom"), flutter::EncodableValue(m->bottom)},
               });
             });
}

void FlutterPrintPlugin::HandleOpenInDefaultApp(const flutter::EncodableMap& args,
                                                WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  // Open the file with the shell "open" verb. Don't wait for the app.
  std::thread([result = std::move(result), wPath = std::move(*wPath),
               alive = alive_]() mutable {
    SHELLEXECUTEINFOW sei = {};
    sei.cbSize = sizeof(sei);
    sei.fMask  = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    sei.lpVerb = L"open";
    sei.lpFile = wPath.c_str();
    sei.nShow  = SW_SHOWNORMAL;
    const bool ok = ShellExecuteExW(&sei);
    const DWORD e = ok ? 0 : GetLastError();
    if (!alive->load()) return;
    if (ok) {
      result->Success();
    } else {
      result->Error("SHELL_ERROR",
                    "Failed to open file (error " + std::to_string(e) + ")");
    }
  }).detach();
}

}  // namespace flutter_print
