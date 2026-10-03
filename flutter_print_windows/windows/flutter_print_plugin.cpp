#include "flutter_print_plugin.h"

#include "document_renderer.h"
#include "flutter_print_utils.h"
#include "printer_setup.h"

#include <algorithm>
#include <climits>
#include <thread>
#include <unordered_set>

namespace flutter_print {

namespace {

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

ColorCapability QueryColor(const PRINTER_INFO_2W& info) {
  // Virtual printers report color like real ones: check the port first.
  if (IsVirtualPort(info.pPortName)) return ColorCapability::kEnforced;

  const DWORD r = DeviceCapabilitiesW(info.pPrinterName, info.pPortName,
                                      DC_COLORDEVICE, nullptr, nullptr);
  if (r == 1) return ColorCapability::kSupported;
  if (r != 0) return ColorCapability::kUnknown;
  // A few virtual printers report monochrome but set DM_COLOR. Printer
  // connections can come without a DEVMODE: ask the driver then.
  std::vector<BYTE> driverDm;
  const DEVMODEW* dm = info.pDevMode;
  if (!dm && !(driverDm = GetDefaultDevMode(info.pPrinterName)).empty())
    dm = reinterpret_cast<const DEVMODEW*>(driverDm.data());
  return dm && (dm->dmFields & DM_COLOR) ? ColorCapability::kEnforced
                                         : ColorCapability::kMonochrome;
}

PrinterCapabilities QueryCapabilities(const PRINTER_INFO_2W& info) {
  constexpr DWORD kUnsupported = static_cast<DWORD>(-1);
  const WCHAR* name = info.pPrinterName;
  const WCHAR* port = info.pPortName;

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

  return PrinterCapabilities(QueryColor(info), duplex ? &*duplex : nullptr,
                             maxCopies ? &*maxCopies : nullptr, pageSizes);
}

// Channel names of the file kinds.
constexpr std::pair<FileKind, const char*> kKindNames[] = {
    {FileKind::kPdf, "pdf"},   {FileKind::kImage, "image"},
    {FileKind::kMetafile, "metafile"}, {FileKind::kText, "text"},
    {FileKind::kOther, "other"},
};

// Returns args[key] when it holds a T, else null.
template <typename T>
const T* GetArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : std::get_if<T>(&it->second);
}

// Returns the "kind" argument, or nullopt when it is missing or unknown.
std::optional<FileKind> GetKindArg(const flutter::EncodableMap& args) {
  if (const auto* name = GetArg<std::string>(args, "kind")) {
    for (const auto& [kind, known] : kKindNames) {
      if (*name == known) return kind;
    }
  }
  return std::nullopt;
}

// Returns the "filePath" argument, or reports INVALID_ARGS and returns nullopt.
std::optional<std::wstring> GetFilePathArg(const flutter::EncodableMap& args,
                                           WinResult& result) {
  const auto* path = GetArg<std::string>(args, "filePath");
  if (!path) {
    result->Error("INVALID_ARGS", "Missing filePath");
    return std::nullopt;
  }
  return Utf8ToWide(*path);
}

// Runs |work| on a worker thread, then passes its value to |reply| if the
// plugin still exists.
template <typename Work, typename Reply>
void RunAsync(std::shared_ptr<std::atomic<bool>> alive, Work work,
              Reply reply) {
  std::thread([alive = std::move(alive), work = std::move(work),
               reply = std::move(reply)]() mutable {
    auto value = work();
    if (alive->load()) reply(std::move(value));
  }).detach();
}

// Runs |work| on a worker thread and replies with the value it returns.
template <typename Work>
void ReplyAsync(std::shared_ptr<std::atomic<bool>> alive, WinResult result,
                Work work) {
  RunAsync(std::move(alive), std::move(work),
           [result = std::move(result)](const flutter::EncodableValue& value) {
             result->Success(value);
           });
}

// Printer and paper the preview lays pages out for.
struct PageLayout {
  std::wstring printer;
  PrintOptions options;
};

// Reads the "printerName", "paperSizeName", "paperWidth", "paperHeight" and
// "landscape" arguments, as the print options hold them.
PageLayout GetLayoutArgs(const flutter::EncodableMap& args) {
  PageLayout layout;
  if (const auto* printer = GetArg<std::string>(args, "printerName"))
    layout.printer = Utf8ToWide(*printer);
  if (const auto* name = GetArg<std::string>(args, "paperSizeName")) {
    PageSize size(*name);
    size.set_width(GetArg<double>(args, "paperWidth"));
    size.set_height(GetArg<double>(args, "paperHeight"));
    layout.options.set_page_size(size);
  }
  if (const auto* landscape = GetArg<bool>(args, "landscape"))
    layout.options.set_landscape(*landscape);
  return layout;
}

// Returns a printer IC for |layout|, on the default printer when it names
// none, or null.
HDC CreateLayoutIC(const PageLayout& layout) {
  const std::wstring printer =
      layout.printer.empty() ? DefaultPrinterName() : layout.printer;
  return printer.empty() ? nullptr : CreatePrinterIC(printer, &layout.options);
}

// Returns args[key] when it holds an integer, else nullopt.
std::optional<int64_t> GetIntArg(const flutter::EncodableMap& args,
                                 const char* key) {
  if (const auto* v = GetArg<int32_t>(args, key)) return *v;
  if (const auto* v = GetArg<int64_t>(args, key)) return *v;
  return std::nullopt;
}

// Keep a few previews at most: a dialog that never closes its preview, e.g.
// after a hot restart, doesn't leak.
constexpr size_t kMaxPreviews = 4;

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
  // Close the previews on their own thread.
  preview_worker_.Stop([this] { previews_.clear(); });
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
  RunAsync(
      alive_,
      [this, file_path, optionsCopy = std::move(optionsCopy)] {
        return PrintInternal(file_path, optionsCopy ? &*optionsCopy : nullptr);
      },
      std::move(result));
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
  RunAsync(
      alive_,
      [] {
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
              name == defaultPrinter, QueryCapabilities(info[i]),
              &available)));
        }
        return printers;
      },
      std::move(result));
}

// ---------------------------------------------------------------------------
// Windows channel
// ---------------------------------------------------------------------------

void FlutterPrintPlugin::HandleWindowsMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call, WinResult result) {
  const std::string& method = call.method_name();
  if (method == "getAccentColors") return HandleGetAccentColors(std::move(result));

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }

  if (method == "getFileKind")         return HandleGetFileKind(*args, std::move(result));
  if (method == "openPreview")         return HandleOpenPreview(*args, std::move(result));
  if (method == "renderPreviewPage")   return HandleRenderPreviewPage(*args, std::move(result));
  if (method == "closePreview")        return HandleClosePreview(*args, std::move(result));
  if (method == "getDefaultPaperSize") return HandleGetDefaultPaperSize(*args, std::move(result));
  if (method == "openInDefaultApp")    return HandleOpenInDefaultApp(*args, std::move(result));
  result->NotImplemented();
}

void FlutterPrintPlugin::HandleGetFileKind(const flutter::EncodableMap& args,
                                           WinResult result) {
  auto wPath = GetFilePathArg(args, result);
  if (!wPath) return;
  ReplyAsync(alive_, std::move(result), [wPath = std::move(*wPath)] {
    const FileKind kind = DetectFileKind(wPath);
    for (const auto& [known, name] : kKindNames) {
      if (kind == known) return flutter::EncodableValue(name);
    }
    return flutter::EncodableValue("other");
  });
}

// The preview handlers run on the preview worker, which owns |previews_|.
void FlutterPrintPlugin::PostPreviewTask(
    WinResult result, std::function<flutter::EncodableValue()> work) {
  // Share the result: std::function needs a copyable task.
  auto reply = std::shared_ptr(std::move(result));
  preview_worker_.Post([alive = alive_, reply, work = std::move(work)] {
    const flutter::EncodableValue value = work();
    if (alive->load()) reply->Success(value);
  });
}

void FlutterPrintPlugin::HandleOpenPreview(const flutter::EncodableMap& args,
                                           WinResult result) {
  auto wPath = GetFilePathArg(args, result);
  if (!wPath) return;
  PostPreviewTask(std::move(result), [this, wPath = std::move(*wPath),
                                      kind = GetKindArg(args),
                                      layout = GetLayoutArgs(args)] {
    HDC ic = CreateLayoutIC(layout);
    auto preview =
        ic ? Preview::Open(ic, wPath, kind ? *kind : DetectFileKind(wPath))
           : nullptr;
    if (!preview) return flutter::EncodableValue();
    while (previews_.size() >= kMaxPreviews) previews_.erase(previews_.begin());
    const int64_t id = ++last_preview_id_;
    const int pageCount = preview->PageCount();
    previews_[id] = std::move(preview);
    return flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("id"), flutter::EncodableValue(id)},
        {flutter::EncodableValue("pageCount"), flutter::EncodableValue(pageCount)},
    });
  });
}

void FlutterPrintPlugin::HandleRenderPreviewPage(
    const flutter::EncodableMap& args, WinResult result) {
  const auto id = GetIntArg(args, "id");
  const auto page = GetIntArg(args, "pageIndex");
  const auto width = GetIntArg(args, "maxWidth");
  const auto height = GetIntArg(args, "maxHeight");
  if (!id || !page || !width || !height) {
    result->Error("INVALID_ARGS", "Missing id, pageIndex, maxWidth or maxHeight");
    return;
  }
  const auto toInt = [](int64_t v) {
    return static_cast<int>(std::clamp<int64_t>(v, INT_MIN, INT_MAX));
  };
  // Optional: the part of the sheet to render, in its pixels.
  std::optional<RECT> region;
  const auto left = GetIntArg(args, "regionLeft");
  const auto top = GetIntArg(args, "regionTop");
  const auto right = GetIntArg(args, "regionRight");
  const auto bottom = GetIntArg(args, "regionBottom");
  if (left && top && right && bottom)
    region = RECT{toInt(*left), toInt(*top), toInt(*right), toInt(*bottom)};
  PostPreviewTask(std::move(result), [this, id = *id, page = toInt(*page),
                                      width = toInt(*width),
                                      height = toInt(*height), region] {
    auto it = previews_.find(id);
    auto png = it == previews_.end()
                   ? std::vector<uint8_t>{}
                   : it->second->RenderPage(page, width, height,
                                            region ? &*region : nullptr);
    return png.empty() ? flutter::EncodableValue()
                       : flutter::EncodableValue(std::move(png));
  });
}

void FlutterPrintPlugin::HandleClosePreview(const flutter::EncodableMap& args,
                                            WinResult result) {
  const auto id = GetIntArg(args, "id");
  PostPreviewTask(std::move(result), [this, id] {
    if (id) previews_.erase(*id);
    return flutter::EncodableValue();
  });
}

void FlutterPrintPlugin::HandleGetDefaultPaperSize(
    const flutter::EncodableMap& args, WinResult result) {
  const auto* printer = GetArg<std::string>(args, "printerName");
  if (!printer) {
    result->Error("INVALID_ARGS", "Missing printerName");
    return;
  }
  ReplyAsync(alive_, std::move(result), [wPrinter = Utf8ToWide(*printer)] {
    const std::string name = DefaultPaperName(wPrinter);
    return name.empty() ? flutter::EncodableValue()
                        : flutter::EncodableValue(name);
  });
}

void FlutterPrintPlugin::HandleGetAccentColors(WinResult result) {
  // 8 RGBX colors, lightest first. The last one is unused.
  BYTE palette[32] = {};
  DWORD size = sizeof(palette);
  if (RegGetValueW(HKEY_CURRENT_USER,
                   L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
                   L"AccentPalette", RRF_RT_REG_BINARY, nullptr, palette,
                   &size) != ERROR_SUCCESS ||
      size != sizeof(palette)) {
    result->Success();
    return;
  }
  flutter::EncodableList colors;
  for (int i = 0; i < 7; ++i) {
    const BYTE* c = palette + i * 4;
    const int64_t argb = 0xFF000000LL | (c[0] << 16) | (c[1] << 8) | c[2];
    colors.push_back(flutter::EncodableValue(argb));
  }
  result->Success(flutter::EncodableValue(colors));
}

void FlutterPrintPlugin::HandleOpenInDefaultApp(const flutter::EncodableMap& args,
                                                WinResult result) {
  auto wPath = GetFilePathArg(args, result);
  if (!wPath) return;
  // Don't wait for the app: it stays open for the user.
  RunAsync(
      alive_,
      [wPath = std::move(*wPath)] {
        return ShellRun(L"open", wPath, nullptr, SW_SHOWNORMAL);
      },
      [result = std::move(result)](DWORD error) {
        if (error == 0) return result->Success();
        result->Error("SHELL_ERROR",
                      "Failed to open file (error " + std::to_string(error) + ")");
      });
}

}  // namespace flutter_print
