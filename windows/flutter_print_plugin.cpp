#define NOMINMAX
#include "flutter_print_plugin.h"
#include "flutter_print_utils.h"

#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>
#include <winspool.h>

#include <flutter/plugin_registrar_windows.h>

#include "messages.h"

#include <memory>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "comdlg32.lib")
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
  registrar->AddPlugin(std::move(plugin));
}

FlutterPrintPlugin::FlutterPrintPlugin(HWND hwnd) : hwnd_(hwnd) {}

std::optional<FlutterError> FlutterPrintPlugin::Print(
    const std::string& file_path, const PrintOptions& options) {
  const std::wstring wPath = Utf8ToWide(file_path);
  if (GetFileAttributesW(wPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    return FlutterError("FILE_NOT_FOUND", "File not found: " + file_path);

  if (IsImageFile(wPath) || IsPdfFile(wPath)) {
    std::wstring wPrinter;
    const std::string* pn = options.printer_address();
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

    HDC hdc = CreatePrinterDC(wPrinter, options);
    if (!hdc)
      return FlutterError("PRINTER_ERROR",
                          "Cannot create printer DC for: " +
                              WideToUtf8(wPrinter.c_str()));
    return RenderOrFallback(hdc, wPath, wPrinter);
  }

  // Other file types: delegate to the file's associated application.
  const std::string* pn = options.printer_address();
  const std::wstring wPrinter = (pn && !pn->empty()) ? Utf8ToWide(*pn) : std::wstring{};
  return RenderOrFallback(nullptr, wPath, wPrinter);
}

std::optional<FlutterError> FlutterPrintPlugin::PrintPreview(
    const std::string& file_path, const PrintOptions& options) {
  const std::wstring wPath = Utf8ToWide(file_path);
  if (GetFileAttributesW(wPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    return FlutterError("FILE_NOT_FOUND", "File not found: " + file_path);

  auto [hDevMode, hDevNames] = BuildDialogHandles(options);

  // For image and PDF files all options are applied via GDI+/PDFium, so show
  // the Print Setup dialog.
  // For other types only the printer name is forwarded via ShellExecuteW
  // "printto", so show the standard Print dialog instead.
  const bool isRenderable = IsImageFile(wPath) || IsPdfFile(wPath);

  PRINTDLG pd = {};
  pd.lStructSize = sizeof(pd);
  pd.hwndOwner   = hwnd_;
  pd.hDevMode    = hDevMode;
  pd.hDevNames   = hDevNames;
  pd.Flags       = PD_USEDEVMODECOPIES | PD_NOSELECTION | PD_NOPAGENUMS |
                   (isRenderable ? PD_PRINTSETUP : 0);

  if (!PrintDlg(&pd)) {
    if (pd.hDC)       DeleteDC(pd.hDC);
    if (pd.hDevMode)  GlobalFree(pd.hDevMode);
    if (pd.hDevNames) GlobalFree(pd.hDevNames);
    return std::nullopt;  // cancelled
  }

  // Extract printer name and create a DC from the confirmed DEVMODE before
  // freeing the dialog handles.
  std::wstring printerName;
  if (pd.hDevNames) {
    auto* dn = static_cast<DEVNAMES*>(GlobalLock(pd.hDevNames));
    if (dn) {
      printerName = reinterpret_cast<const WCHAR*>(dn) + dn->wDeviceOffset;
      GlobalUnlock(pd.hDevNames);
    }
  }

  HDC hdc = nullptr;
  if (pd.hDevMode && !printerName.empty()) {
    auto* dm = static_cast<DEVMODE*>(GlobalLock(pd.hDevMode));
    if (dm) {
      hdc = CreateDCW(L"WINSPOOL", printerName.c_str(), nullptr, dm);
      GlobalUnlock(pd.hDevMode);
    }
  }

  if (pd.hDC)       DeleteDC(pd.hDC);
  if (pd.hDevMode)  GlobalFree(pd.hDevMode);
  if (pd.hDevNames) GlobalFree(pd.hDevNames);

  if (!hdc)
    return FlutterError("PRINTER_ERROR", "Cannot create printer DC");

  return RenderOrFallback(hdc, wPath, printerName);
}

void FlutterPrintPlugin::PickPrinter(
    std::function<void(ErrorOr<std::optional<PrinterInfo>>)> result) {
  result(std::optional<PrinterInfo>(std::nullopt));
}

void FlutterPrintPlugin::ListPrinters(
    std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  // EnumPrintersW can block while resolving network printers — run on a
  // detached thread so the platform thread is never stalled.
  std::thread([result = std::move(result)]() {
    DWORD needed = 0, returned = 0;
    EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2,
                  nullptr, 0, &needed, &returned);
    if (needed == 0) { result(flutter::EncodableList{}); return; }

    std::vector<BYTE> buf(needed);
    if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr,
                       2, buf.data(), needed, &needed, &returned)) {
      result(flutter::EncodableList{});
      return;
    }

    WCHAR defName[512] = {};
    DWORD defSize = static_cast<DWORD>(sizeof(defName) / sizeof(WCHAR));
    GetDefaultPrinterW(defName, &defSize);
    const std::wstring defaultPrinter(defName);

    auto* info = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
    flutter::EncodableList printers;

    for (DWORD i = 0; i < returned; ++i) {
      const WCHAR* name = info[i].pPrinterName;
      if (!name) continue;

      PrinterCapabilities caps(nullptr, nullptr, nullptr,
                               flutter::EncodableList{});
      std::string descStr;
      const std::string* descPtr = nullptr;
      if (info[i].pComment && info[i].pComment[0]) {
        descStr = WideToUtf8(info[i].pComment);
        descPtr = &descStr;
      }
      const std::string nameUtf8 = WideToUtf8(name);
      printers.push_back(flutter::CustomEncodableValue(PrinterInfo(
          nameUtf8, &nameUtf8, descPtr, std::wstring(name) == defaultPrinter,
          caps)));
    }
    result(printers);
  }).detach();
}

}  // namespace flutter_print
