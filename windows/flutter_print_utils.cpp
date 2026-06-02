#define NOMINMAX
#include "flutter_print_utils.h"

#include <windows.h>
#include <gdiplus.h>
#include <shellapi.h>
#include <winspool.h>
#include <wincodec.h>

#include <fpdfview.h>

#include <algorithm>
#include <string>
#include <vector>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

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

bool EndsWithIgnoreCase(const std::wstring& path, const wchar_t* ext) {
  std::wstring lower = path;
  std::transform(lower.begin(), lower.end(), lower.begin(), ::towlower);
  const size_t el = wcslen(ext);
  return lower.size() >= el && lower.compare(lower.size() - el, el, ext) == 0;
}

bool IsImageFile(const std::wstring& path) {
  return EndsWithIgnoreCase(path, L".jpg")  ||
         EndsWithIgnoreCase(path, L".jpeg") ||
         EndsWithIgnoreCase(path, L".png")  ||
         EndsWithIgnoreCase(path, L".bmp")  ||
         EndsWithIgnoreCase(path, L".gif")  ||
         EndsWithIgnoreCase(path, L".tiff") ||
         EndsWithIgnoreCase(path, L".tif")  ||
         EndsWithIgnoreCase(path, L".wmf")  ||
         EndsWithIgnoreCase(path, L".emf")  ||
         EndsWithIgnoreCase(path, L".webp") ||
         EndsWithIgnoreCase(path, L".heic") ||
         EndsWithIgnoreCase(path, L".heif");
}

bool IsPdfFile(const std::wstring& path) {
  return EndsWithIgnoreCase(path, L".pdf");
}

// ---------------------------------------------------------------------------
// DEVMODE / printer
// ---------------------------------------------------------------------------

int NameToDMPaper(const std::string& name) {
  if (name == "A3")        return DMPAPER_A3;
  if (name == "A4")        return DMPAPER_A4;
  if (name == "A5")        return DMPAPER_A5;
  if (name == "A6")        return DMPAPER_A6;
  if (name == "Letter")    return DMPAPER_LETTER;
  if (name == "Legal")     return DMPAPER_LEGAL;
  if (name == "Tabloid")   return DMPAPER_TABLOID;
  if (name == "Executive") return DMPAPER_EXECUTIVE;
  if (name == "JIS B4")    return DMPAPER_B4;
  if (name == "JIS B5")    return DMPAPER_B5;
  if (name == "DL")        return DMPAPER_ENV_DL;
  if (name == "C5")        return DMPAPER_ENV_C5;
  return 0;
}

void ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options) {
  dm->dmCopies      = static_cast<short>(std::max<int64_t>(1, options.copies()));
  dm->dmOrientation = options.landscape() ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
  dm->dmColor       = options.color()     ? DMCOLOR_COLOR      : DMCOLOR_MONOCHROME;
  dm->dmFields     |= DM_COPIES | DM_ORIENTATION | DM_COLOR;

  const DuplexMode* dup = options.duplex_mode();
  if (dup) {
    switch (*dup) {
      case DuplexMode::kNone:      dm->dmDuplex = DMDUP_SIMPLEX;    break;
      case DuplexMode::kLongEdge:  dm->dmDuplex = DMDUP_VERTICAL;   break;
      case DuplexMode::kShortEdge: dm->dmDuplex = DMDUP_HORIZONTAL; break;
    }
    dm->dmFields |= DM_DUPLEX;
  }

  const PageSize* ps = options.page_size();
  if (ps) {
    dm->dmFields &= ~(DM_PAPERSIZE | DM_PAPERWIDTH | DM_PAPERLENGTH);

    const std::string& sname = ps->name();
    if (!sname.empty()) {
      int paper = NameToDMPaper(sname);
      if (paper > 0) {
        dm->dmPaperSize = static_cast<short>(paper);
        dm->dmFields   |= DM_PAPERSIZE;
      }
    }
    if (!(dm->dmFields & DM_PAPERSIZE)) {
      const double* w = ps->width();
      const double* h = ps->height();
      if (w && h && *w > 0 && *h > 0) {
        // dmPaperWidth is always the short edge and dmPaperLength the long edge
        // (tenths of mm), independently of dmOrientation.
        const double shortEdge = std::min(*w, *h);
        const double longEdge  = std::max(*w, *h);
        dm->dmPaperSize   = DMPAPER_USER;
        dm->dmPaperWidth  = static_cast<short>(std::round(shortEdge * 10.0));
        dm->dmPaperLength = static_cast<short>(std::round(longEdge  * 10.0));
        dm->dmFields     |= DM_PAPERSIZE | DM_PAPERWIDTH | DM_PAPERLENGTH;
        // dmPaperWidth = short edge, dmPaperLength = long edge.
        // Portrait DC: width = short edge; Landscape DC: width = long edge.
        // Override so the DC width always matches the requested page width.
        dm->dmOrientation = (*w > *h) ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
      }
    }
  }
}

HGLOBAL BuildDevMode(const std::wstring& printerName,
                     const PrintOptions& options) {
  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr))
    return nullptr;

  const LONG sz = DocumentPropertiesW(
      nullptr, hPrinter, const_cast<LPWSTR>(printerName.c_str()),
      nullptr, nullptr, 0);
  if (sz <= 0) { ClosePrinter(hPrinter); return nullptr; }

  HGLOBAL h = GlobalAlloc(GHND, sz);
  if (!h) { ClosePrinter(hPrinter); return nullptr; }

  auto* dm = static_cast<DEVMODE*>(GlobalLock(h));
  if (DocumentPropertiesW(nullptr, hPrinter,
                           const_cast<LPWSTR>(printerName.c_str()),
                           dm, nullptr, DM_OUT_BUFFER) == IDOK) {
    ApplyOptionsToDEVMODE(dm, options);
    // Let the driver validate and normalise our changes; without this round-trip
    // many drivers silently ignore the modified DEVMODE and produce a blank job.
    DocumentPropertiesW(nullptr, hPrinter,
                         const_cast<LPWSTR>(printerName.c_str()),
                         dm, dm, DM_IN_BUFFER | DM_OUT_BUFFER);
  }
  GlobalUnlock(h);
  ClosePrinter(hPrinter);
  return h;
}

HDC CreatePrinterDC(const std::wstring& printerName,
                    const PrintOptions& options) {
  HGLOBAL h  = BuildDevMode(printerName, options);
  auto*   dm = h ? static_cast<DEVMODE*>(GlobalLock(h)) : nullptr;
  HDC     hdc = CreateDCW(L"WINSPOOL", printerName.c_str(), nullptr, dm);
  if (dm) GlobalUnlock(h);
  if (h)  GlobalFree(h);
  return hdc;
}

HGLOBAL BuildDevNames(const std::wstring& printerName) {
  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr))
    return nullptr;

  DWORD needed = 0;
  GetPrinterW(hPrinter, 2, nullptr, 0, &needed);
  std::vector<BYTE> buf(needed);
  const bool ok = needed > 0 &&
                  GetPrinterW(hPrinter, 2, buf.data(), needed, &needed);
  ClosePrinter(hPrinter);
  if (!ok) return nullptr;

  auto*        info   = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
  std::wstring driver = info->pDriverName ? info->pDriverName : L"";
  std::wstring port   = info->pPortName   ? info->pPortName   : L"";

  // DEVNAMES offsets are in WCHARs from the start of the allocation.
  // sizeof(DEVNAMES) == 8 bytes == 4 WCHARs.
  const WORD base      = static_cast<WORD>(sizeof(DEVNAMES) / sizeof(WCHAR));
  const WORD driverOff = base;
  const WORD deviceOff = driverOff + static_cast<WORD>(driver.size() + 1);
  const WORD portOff   = deviceOff + static_cast<WORD>(printerName.size() + 1);
  const size_t total   = (static_cast<size_t>(portOff) + port.size() + 1) * sizeof(WCHAR);

  HGLOBAL h = GlobalAlloc(GHND, total);
  if (!h) return nullptr;

  auto* dn    = static_cast<DEVNAMES*>(GlobalLock(h));
  dn->wDriverOffset = driverOff;
  dn->wDeviceOffset = deviceOff;
  dn->wOutputOffset = portOff;
  dn->wDefault      = 0;

  auto* chars = reinterpret_cast<WCHAR*>(dn);
  wcscpy_s(chars + driverOff, driver.size() + 1,      driver.c_str());
  wcscpy_s(chars + deviceOff, printerName.size() + 1, printerName.c_str());
  wcscpy_s(chars + portOff,   port.size() + 1,        port.c_str());
  GlobalUnlock(h);
  return h;
}

PrintDialogHandles BuildDialogHandles(const PrintOptions& options) {
  PrintDialogHandles out;

  const std::string* pn = options.printer_address();
  if (pn && !pn->empty()) {
    const std::wstring wPrinter = Utf8ToWide(*pn);
    out.hDevNames = BuildDevNames(wPrinter);
    out.hDevMode  = BuildDevMode(wPrinter, options);
  }

  // Fallback: bare DEVMODE — PrintDlg will use the system default printer.
  if (!out.hDevMode) {
    out.hDevMode = GlobalAlloc(GHND, sizeof(DEVMODE));
    if (out.hDevMode) {
      auto* dm = static_cast<DEVMODE*>(GlobalLock(out.hDevMode));
      if (dm) {
        dm->dmSize = sizeof(DEVMODE);
        ApplyOptionsToDEVMODE(dm, options);
        GlobalUnlock(out.hDevMode);
      }
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Decode via WIC and draw centred/scaled into hdc.
// Used as a fallback for formats GDI+ does not support (WebP, HEIC, …).
static std::optional<FlutterError> RenderViaWIC(
    HDC hdc, const std::wstring& path, int pw, int ph) {
  HRESULT coinit_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  IWICImagingFactory* factory = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                 CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    if (SUCCEEDED(coinit_hr)) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC not available on this system");
  }

  IWICBitmapDecoder* decoder = nullptr;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                           WICDecodeMetadataCacheOnLoad,
                                           &decoder);
  if (FAILED(hr)) {
    factory->Release();
    if (SUCCEEDED(coinit_hr)) CoUninitialize();
    return FlutterError("IMAGE_ERROR",
                         "WIC codec not installed for: " +
                             WideToUtf8(path.c_str()));
  }

  IWICBitmapFrameDecode* frame = nullptr;
  hr = decoder->GetFrame(0, &frame);
  decoder->Release();
  if (FAILED(hr)) {
    factory->Release();
    if (SUCCEEDED(coinit_hr)) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC frame decode failed");
  }

  IWICFormatConverter* converter = nullptr;
  factory->CreateFormatConverter(&converter);
  // PixelFormat32bppBGRA in WIC == PixelFormat32bppARGB in GDI+ (BGRA memory).
  converter->Initialize(frame, GUID_WICPixelFormat32bppBGRA,
                         WICBitmapDitherTypeNone, nullptr, 0.0,
                         WICBitmapPaletteTypeCustom);
  frame->Release();
  factory->Release();

  UINT iw = 0, ih = 0;
  converter->GetSize(&iw, &ih);
  std::vector<BYTE> pixels(static_cast<size_t>(iw) * ih * 4);
  converter->CopyPixels(nullptr, iw * 4,
                         static_cast<UINT>(pixels.size()), pixels.data());
  converter->Release();
  if (SUCCEEDED(coinit_hr)) CoUninitialize();

  if (iw == 0 || ih == 0)
    return FlutterError("IMAGE_ERROR", "WIC returned empty image");

  Gdiplus::Bitmap bmp(static_cast<INT>(iw), static_cast<INT>(ih),
                       static_cast<INT>(iw) * 4, PixelFormat32bppARGB,
                       pixels.data());
  const float s  = std::min(static_cast<float>(pw) / iw,
                             static_cast<float>(ph) / ih);
  Gdiplus::Graphics g(hdc);
  g.SetPageUnit(Gdiplus::UnitPixel);
  g.DrawImage(&bmp,
              (pw - static_cast<int>(iw * s)) / 2,
              (ph - static_cast<int>(ih * s)) / 2,
              static_cast<int>(iw * s),
              static_cast<int>(ih * s));
  return std::nullopt;
}

std::optional<FlutterError> RenderImageToDC(HDC hdc, const std::wstring& path) {
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok)
    return FlutterError("GDI_ERROR", "GDI+ initialisation failed");

  const int pw = GetDeviceCaps(hdc, HORZRES);
  const int ph = GetDeviceCaps(hdc, VERTRES);

  DOCINFOW di = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = path.c_str();

  std::optional<FlutterError> err;
  {
    Gdiplus::Image img(path.c_str());
    if (StartDoc(hdc, &di) > 0) {
      if (StartPage(hdc) > 0) {
        if (img.GetLastStatus() == Gdiplus::Ok) {
          // GDI+ handles this format natively.
          const UINT iw = img.GetWidth(), ih = img.GetHeight();
          const float s = std::min(static_cast<float>(pw) / iw,
                                   static_cast<float>(ph) / ih);
          Gdiplus::Graphics g(hdc);
          g.SetPageUnit(Gdiplus::UnitPixel);
          g.DrawImage(&img,
                      (pw - static_cast<int>(iw * s)) / 2,
                      (ph - static_cast<int>(ih * s)) / 2,
                      static_cast<int>(iw * s),
                      static_cast<int>(ih * s));
        } else {
          // GDI+ can't decode this format (e.g. WebP, HEIC) — try WIC.
          err = RenderViaWIC(hdc, path, pw, ph);
        }
        EndPage(hdc);
      }
      EndDoc(hdc);
    } else {
      err = FlutterError("PRINT_ERROR", "StartDoc failed");
    }
  }

  Gdiplus::GdiplusShutdown(token);
  return err;
}

std::optional<FlutterError> RenderPdfToDC(HDC hdc, const std::wstring& path) {
  FPDF_LIBRARY_CONFIG cfg = {};
  cfg.version = 2;
  FPDF_InitLibraryWithConfig(&cfg);

  const std::string utf8 = WideToUtf8(path.c_str());
  FPDF_DOCUMENT doc = FPDF_LoadDocument(utf8.c_str(), nullptr);
  if (!doc) {
    FPDF_DestroyLibrary();
    return FlutterError("PDF_ERROR", "Cannot open PDF: " + utf8);
  }

  // Scaling factor: PDF points (1/72 in) to device pixels.
  const double dpiX = static_cast<double>(GetDeviceCaps(hdc, LOGPIXELSX)) / 72.0;
  const double dpiY = static_cast<double>(GetDeviceCaps(hdc, LOGPIXELSY)) / 72.0;

  // Physical paper dimensions as resolved by the driver (reflects the actual
  // paper loaded, which may differ from the requested custom size).
  const int physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  const int physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  // Offset from the physical paper edge to the printable-area origin (DC origin).
  const int marginLeft = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const int marginTop  = GetDeviceCaps(hdc, PHYSICALOFFSETY);

  DOCINFOW di = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = path.c_str();

  std::optional<FlutterError> err;

  if (StartDoc(hdc, &di) > 0) {
    const int pageCount = FPDF_GetPageCount(doc);
    for (int i = 0; i < pageCount; ++i) {
      FPDF_PAGE page = FPDF_LoadPage(doc, i);
      if (!page) continue;

      // Native size: PDF points to device pixels.
      const int nativeW = static_cast<int>(FPDF_GetPageWidth(page)  * dpiX);
      const int nativeH = static_cast<int>(FPDF_GetPageHeight(page) * dpiY);

      // Scale down only when the PDF overflows the physical paper; never upscale.
      // PHYSICALWIDTH/HEIGHT reflect what the driver actually resolved to, so
      // this handles matching paper (scale = 1) and fallback paper (PDF fits).
      const double scale = std::min({1.0,
          static_cast<double>(physW) / nativeW,
          static_cast<double>(physH) / nativeH});
      const int renderW = static_cast<int>(nativeW * scale);
      const int renderH = static_cast<int>(nativeH * scale);

      // PDFium on Windows GDI must be anchored at the physical page origin.
      // Positive-only offsets (e.g. printable-area relative) produce blank output.
      StartPage(hdc);
      FPDF_RenderPage(hdc, page, -marginLeft, -marginTop, renderW, renderH,
                      0, FPDF_ANNOT | FPDF_PRINTING);
      EndPage(hdc);
      FPDF_ClosePage(page);
    }
    EndDoc(hdc);
  } else {
    err = FlutterError("PRINT_ERROR", "StartDoc failed");
  }

  FPDF_CloseDocument(doc);
  FPDF_DestroyLibrary();
  return err;
}

std::optional<FlutterError> RenderOrFallback(HDC hdc,
                                              const std::wstring& wPath,
                                              const std::wstring& printerName) {
  if (IsImageFile(wPath)) {
    auto err = RenderImageToDC(hdc, wPath);
    DeleteDC(hdc);
    return err;
  }
  if (IsPdfFile(wPath)) {
    auto err = RenderPdfToDC(hdc, wPath);
    DeleteDC(hdc);
    return err;
  }

  if (hdc) DeleteDC(hdc);

  HINSTANCE hr;
  if (printerName.empty()) {
    hr = ShellExecuteW(nullptr, L"print", wPath.c_str(),
                       nullptr, nullptr, SW_HIDE);
  } else {
    hr = ShellExecuteW(nullptr, L"printto", wPath.c_str(),
                       printerName.c_str(), nullptr, SW_HIDE);
  }
  if (reinterpret_cast<INT_PTR>(hr) <= 32)
    return FlutterError("SHELL_ERROR",
                        "ShellExecuteW failed with code " +
                            std::to_string(reinterpret_cast<INT_PTR>(hr)));
  return std::nullopt;
}

}  // namespace flutter_print
