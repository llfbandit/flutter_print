#define NOMINMAX  // must precede flutter_print_plugin.h's <windows.h>
#include "flutter_print_plugin.h"
#include "flutter_print_utils.h"
#include "printer_setup.h"
#include "document_renderer.h"

#include <thread>
#include <unordered_set>

#pragma comment(lib, "winspool.lib")

namespace flutter_print {

// ---------------------------------------------------------------------------
// C API — called by the Flutter engine at startup
// ---------------------------------------------------------------------------

void FlutterPrintPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlutterPrintPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

// ---------------------------------------------------------------------------
// FlutterPrintPlugin
// ---------------------------------------------------------------------------

// static
void FlutterPrintPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  HWND hwnd = registrar->GetView()
                  ? reinterpret_cast<HWND>(registrar->GetView()->GetNativeWindow())
                  : nullptr;
  auto plugin = std::make_unique<FlutterPrintPlugin>(hwnd);
  FlutterPrintApi::SetUp(registrar->messenger(), plugin.get());

  // Windows-specific method channel: PDF preview rendering for the Flutter
  // print dialog. Lives alongside the Pigeon channel.
  auto* plugin_ptr = plugin.get();
  auto win_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_print_windows",
          &flutter::StandardMethodCodec::GetInstance());
  win_channel->SetMethodCallHandler(
      [plugin_ptr](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        plugin_ptr->HandleWindowsMethod(call, std::move(result));
      });
  plugin->windows_channel_ = std::move(win_channel);

  registrar->AddPlugin(std::move(plugin));
}

FlutterPrintPlugin::FlutterPrintPlugin(HWND hwnd)
    : hwnd_(hwnd), alive_(std::make_shared<std::atomic<bool>>(true)) {}

FlutterPrintPlugin::~FlutterPrintPlugin() {
  *alive_ = false;
}

// ---------------------------------------------------------------------------
// FlutterPrintApi — Print / PrintPreview
// ---------------------------------------------------------------------------

std::optional<FlutterError> FlutterPrintPlugin::Print(
    const std::string& file_path, const PrintOptions* options) {
  const std::wstring wPath = Utf8ToWide(file_path);
  if (GetFileAttributesW(wPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    return FlutterError("FILE_NOT_FOUND", "File not found: " + file_path);

  static const PrintOptions kDefaults(1, false, true);
  const PrintOptions& opts = options ? *options : kDefaults;

  const std::string mime = GetMimeType(wPath);
  if (mime.rfind("image/", 0) == 0 || mime == "application/pdf" ||
      mime.rfind("text/", 0) == 0) {
    std::wstring wPrinter;
    const std::string* pn = opts.printer_address();
    if (pn && !pn->empty()) {
      wPrinter = Utf8ToWide(*pn);
    } else {
      WCHAR buf[512] = {};
      DWORD sz = static_cast<DWORD>(sizeof(buf) / sizeof(WCHAR));
      GetDefaultPrinterW(buf, &sz);
      wPrinter = buf;
    }
    if (wPrinter.empty())
      return FlutterError("PRINTER_ERROR", "No printer available");

    HDC hdc = CreatePrinterDC(wPrinter, opts);
    if (!hdc)
      return FlutterError("PRINTER_ERROR",
                          "Cannot create printer DC for: " +
                              WideToUtf8(wPrinter.c_str()));
    return RenderOrFallback(hdc, wPath, wPrinter);
  }

  // Other file types: delegate to the file's associated application.
  const std::string* pn = opts.printer_address();
  const std::wstring wPrinter = (pn && !pn->empty()) ? Utf8ToWide(*pn) : std::wstring{};
  return RenderOrFallback(nullptr, wPath, wPrinter);
}

std::optional<FlutterError> FlutterPrintPlugin::PrintPreview(
    const std::string& /*file_path*/, const PrintOptions* /*options*/) {
  // Preview is handled entirely in Dart via showWindowsPrintDialog.
  return std::nullopt;
}

// ---------------------------------------------------------------------------
// FlutterPrintApi — ListPrinters / PickPrinter
// ---------------------------------------------------------------------------

void FlutterPrintPlugin::PickPrinter(
    std::function<void(ErrorOr<std::optional<PrinterInfo>>)> result) {
  result(std::optional<PrinterInfo>(std::nullopt));
}

void FlutterPrintPlugin::ListPrinters(
    std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  // EnumPrintersW can block while resolving network printers.
  std::thread([result = std::move(result), alive = alive_]() {
    auto reply = [&](flutter::EncodableList list) {
      if (alive->load()) result(std::move(list));
    };

    DWORD needed = 0, returned = 0;
    std::vector<BYTE> buf;
    bool ok = false;
    for (int attempt = 0; attempt < 5 && !ok; ++attempt) {
      needed = 0; returned = 0;
      EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2,
                    nullptr, 0, &needed, &returned);
      if (needed == 0) { reply(flutter::EncodableList{}); return; }
      buf.resize(needed);
      ok = !!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr,
                           2, buf.data(), needed, &needed, &returned);
      if (!ok && GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        reply(flutter::EncodableList{}); return;
      }
      // ERROR_INSUFFICIENT_BUFFER: a printer was added between the two calls; retry.
    }
    if (!ok) { reply(flutter::EncodableList{}); return; }

    WCHAR defName[512] = {};
    DWORD defSize = static_cast<DWORD>(sizeof(defName) / sizeof(WCHAR));
    GetDefaultPrinterW(defName, &defSize);
    const std::wstring defaultPrinter(defName);

    auto* info = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
    flutter::EncodableList printers;

    // Paper-size IDs mapped to the well-known names the Dart layer uses.
    static const std::pair<WORD, const char*> kKnownPapers[] = {
        {static_cast<WORD>(DMPAPER_A3),        "A3"},
        {static_cast<WORD>(DMPAPER_A4),        "A4"},
        {static_cast<WORD>(DMPAPER_A5),        "A5"},
        {static_cast<WORD>(DMPAPER_A6),        "A6"},
        {static_cast<WORD>(DMPAPER_LETTER),    "Letter"},
        {static_cast<WORD>(DMPAPER_LEGAL),     "Legal"},
        {static_cast<WORD>(DMPAPER_TABLOID),   "Tabloid"},
        {static_cast<WORD>(DMPAPER_EXECUTIVE), "Executive"},
        {static_cast<WORD>(DMPAPER_B4),        "JIS B4"},
        {static_cast<WORD>(DMPAPER_B5),        "JIS B5"},
        {static_cast<WORD>(DMPAPER_ENV_DL),    "DL"},
        {static_cast<WORD>(DMPAPER_ENV_C5),    "C5"},
    };

    for (DWORD i = 0; i < returned; ++i) {
      const WCHAR* name = info[i].pPrinterName;
      if (!name) continue;
      const WCHAR* port = info[i].pPortName;

      // Color support.
      // DC_COLORDEVICE is unreliable for virtual/software printers on modern
      // Windows — they return 1 (colour) just like physical colour printers.
      // Detect them first by port name: virtual printers use well-known
      // file-output ports (PORTPROMPT:, nul:) while physical printers use
      // hardware ports (USB, WSD-*, LPT#, etc.).
      ColorCapability colorCap = ColorCapability::kUnknown;
      {
        // Case-insensitive port-name comparison (port names are always ASCII).
        auto portEq = [](const WCHAR* a, const WCHAR* b) -> bool {
          return a && _wcsicmp(a, b) == 0;
        };
        // Detect virtual/software printers by port name before querying
        // DC_COLORDEVICE — on modern Windows virtual printers return 1 (colour)
        // indistinguishably from physical colour printers.
        //   PORTPROMPT: — Microsoft Print to PDF, XPS Document Writer, Adobe PDF, etc.
        //   nul:        — OneNote (Desktop) and other null-sink drivers
        //   NULPORT:    — alternate null-port name used by some virtual drivers
        const bool isVirtualPort = portEq(port, L"PORTPROMPT:")
                                || portEq(port, L"nul:")
                                || portEq(port, L"NULPORT:");

        if (isVirtualPort) {
          colorCap = ColorCapability::kEnforced;
        } else {
          DWORD r = DeviceCapabilitiesW(name, port, DC_COLORDEVICE, nullptr, nullptr);
          if (r == 1) {
            colorCap = ColorCapability::kSupported;
          } else if (r == 0) {
            // DC_COLORDEVICE reports monochrome; default to kMonochrome so any
            // probe failure leaves us with the authoritative DC_COLORDEVICE answer.
            colorCap = ColorCapability::kMonochrome;
            // Verify via DEVMODE — a small number of drivers carry DM_COLOR in
            // dmFields despite reporting 0, indicating a virtual/software printer.
            HANDLE hPrinter = nullptr;
            if (OpenPrinterW(const_cast<LPWSTR>(name), &hPrinter, nullptr)) {
              LONG sz = DocumentPropertiesW(nullptr, hPrinter,
                                            const_cast<LPWSTR>(name),
                                            nullptr, nullptr, 0);
              if (sz > 0) {
                std::vector<BYTE> dmBuf(static_cast<size_t>(sz));
                auto* dm = reinterpret_cast<DEVMODE*>(dmBuf.data());
                if (DocumentPropertiesW(nullptr, hPrinter,
                                         const_cast<LPWSTR>(name),
                                         dm, nullptr, DM_OUT_BUFFER) == IDOK) {
                  if (dm->dmFields & DM_COLOR)
                    colorCap = ColorCapability::kEnforced;  // DM_COLOR despite r==0 → virtual
                }
              }
              ClosePrinter(hPrinter);
            }
          } else {
            // r == -1: DC_COLORDEVICE not implemented — capability unknown.
            colorCap = ColorCapability::kUnknown;
          }
        }
      }

      // Duplex support
      const bool* duplexPtr = nullptr;
      bool duplexBool = false;
      {
        DWORD r = DeviceCapabilitiesW(name, port, DC_DUPLEX, nullptr, nullptr);
        if (r != (DWORD)-1) { duplexBool = (r == 1); duplexPtr = &duplexBool; }
      }

      // Maximum copies
      const int64_t* copiesPtr = nullptr;
      int64_t copiesVal = 0;
      {
        DWORD r = DeviceCapabilitiesW(name, port, DC_COPIES, nullptr, nullptr);
        if (r != (DWORD)-1 && r > 0) { copiesVal = static_cast<int64_t>(r); copiesPtr = &copiesVal; }
      }

      // Supported paper sizes
      flutter::EncodableList pageSizes;
      {
        DWORD count = DeviceCapabilitiesW(name, port, DC_PAPERS, nullptr, nullptr);
        if (count != (DWORD)-1 && count > 0) {
          std::vector<WORD> papers(count);
          DeviceCapabilitiesW(name, port, DC_PAPERS,
                              reinterpret_cast<LPWSTR>(papers.data()), nullptr);
          std::unordered_set<WORD> supported(papers.begin(), papers.end());
          for (const auto& [id, pname] : kKnownPapers) {
            if (supported.count(id)) {
              pageSizes.push_back(flutter::EncodableValue(std::string(pname)));
            }
          }
        }
      }

      PrinterCapabilities caps(colorCap, duplexPtr, copiesPtr, pageSizes);

      std::string detailsStr;
      const std::string* detailsPtr = nullptr;
      if (info[i].pComment && info[i].pComment[0]) {
        detailsStr = WideToUtf8(info[i].pComment);
        detailsPtr = &detailsStr;
      }
      const std::string nameUtf8 = WideToUtf8(name);
      bool avail = !(info[i].Status & PRINTER_STATUS_OFFLINE);
      printers.push_back(flutter::CustomEncodableValue(PrinterInfo(
          nameUtf8, &nameUtf8, detailsPtr, std::wstring(name) == defaultPrinter,
          caps, &avail)));
    }
    reply(std::move(printers));
  }).detach();
}

// ---------------------------------------------------------------------------
// Windows-specific method channel — PDF preview rendering
// ---------------------------------------------------------------------------

namespace {
// Extracts "filePath" from |args|, reports INVALID_ARGS on |result| and
// returns nullopt if missing.
std::optional<std::wstring> GetFilePathArg(const flutter::EncodableMap& args, flutter::MethodResult<flutter::EncodableValue>& result) {
  auto it = args.find(flutter::EncodableValue("filePath"));
  if (it == args.end()) {
    result.Error("INVALID_ARGS", "Missing filePath");
    return std::nullopt;
  }
  return Utf8ToWide(std::get<std::string>(it->second));
}
}  // namespace

void FlutterPrintPlugin::HandleWindowsMethod(const flutter::MethodCall<flutter::EncodableValue>& call, WinResult result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }

  const std::string& method = call.method_name();
  if (method == "getMimeType")        return HandleGetMimeType(*args, std::move(result));
  if (method == "getPdfPageCount")    return HandleGetPdfPageCount(*args, std::move(result));
  if (method == "renderPdfPageToPng") return HandleRenderPdfPageToPng(*args, std::move(result));
  if (method == "decodeTextFile")     return HandleDecodeTextFile(*args, std::move(result));
  result->NotImplemented();
}

void FlutterPrintPlugin::HandleGetMimeType(const flutter::EncodableMap& args, WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  std::thread([result = std::move(result), wPath = std::move(*wPath),
               alive = alive_]() mutable {
    if (alive->load())
      result->Success(flutter::EncodableValue(GetMimeType(wPath)));
  }).detach();
}

void FlutterPrintPlugin::HandleGetPdfPageCount(const flutter::EncodableMap& args, WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  std::thread([result = std::move(result), wPath = std::move(*wPath),
               alive = alive_]() mutable {
    if (alive->load())
      result->Success(flutter::EncodableValue(GetPdfPageCount(wPath)));
  }).detach();
}

void FlutterPrintPlugin::HandleRenderPdfPageToPng(const flutter::EncodableMap& args, WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;

  int pageIndex = 0;
  if (auto it = args.find(flutter::EncodableValue("pageIndex"));
      it != args.end()) {
    if (auto* i32 = std::get_if<int32_t>(&it->second)) pageIndex = *i32;
    else if (auto* i64 = std::get_if<int64_t>(&it->second))
      pageIndex = static_cast<int>(*i64);
  }

  double dpi = 150.0;
  if (auto it = args.find(flutter::EncodableValue("dpi")); it != args.end()) {
    if (auto* d = std::get_if<double>(&it->second)) dpi = *d;
  }

  std::thread([result = std::move(result), wPath = std::move(*wPath),
               pageIndex, dpi, alive = alive_]() mutable {
    auto png = RenderPdfPageToPng(wPath, pageIndex, dpi);
    if (!alive->load()) return;
    result->Success(png.empty() ? flutter::EncodableValue()
                                : flutter::EncodableValue(png));
  }).detach();
}

void FlutterPrintPlugin::HandleDecodeTextFile(const flutter::EncodableMap& args, WinResult result) {
  auto wPath = GetFilePathArg(args, *result);
  if (!wPath) return;
  std::thread([result = std::move(result), wPath = std::move(*wPath),
               alive = alive_]() mutable {
    const std::wstring text = ReadTextFile(wPath);
    if (!alive->load()) return;
    result->Success(flutter::EncodableValue(WideToUtf8(text.c_str())));
  }).detach();
}

}  // namespace flutter_print
