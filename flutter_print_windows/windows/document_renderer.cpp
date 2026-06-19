#include "document_renderer.h"

#include "flutter_print_utils.h"

#include <gdiplus.h>
#include <shellapi.h>
#include <wincodec.h>

#include <fpdfview.h>
#include <algorithm>
#include <mutex>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace flutter_print {

// Serialises all PDFium document/page operations; PDFium global state is not
// thread-safe without external synchronization.
static std::mutex g_pdfium_mtx;
static std::once_flag g_pdfium_init_flag;

static void EnsurePdfiumInit() {
  std::call_once(g_pdfium_init_flag, []() {
    FPDF_LIBRARY_CONFIG cfg = {};
    cfg.version = 2;
    FPDF_InitLibraryWithConfig(&cfg);
  });
}

// ---------------------------------------------------------------------------
// Internal helpers
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
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC not available on this system");
  }

  IWICBitmapDecoder* decoder = nullptr;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                           WICDecodeMetadataCacheOnLoad,
                                           &decoder);
  if (FAILED(hr)) {
    factory->Release();
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR",
                         "WIC codec not installed for: " +
                             WideToUtf8(path.c_str()));
  }

  IWICBitmapFrameDecode* frame = nullptr;
  hr = decoder->GetFrame(0, &frame);
  decoder->Release();
  if (FAILED(hr)) {
    factory->Release();
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC frame decode failed");
  }

  IWICFormatConverter* converter = nullptr;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr) || !converter) {
    frame->Release();
    factory->Release();
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC format converter creation failed");
  }
  // PixelFormat32bppBGRA in WIC == PixelFormat32bppARGB in GDI+ (BGRA memory).
  hr = converter->Initialize(frame, GUID_WICPixelFormat32bppBGRA,
                              WICBitmapDitherTypeNone, nullptr, 0.0,
                              WICBitmapPaletteTypeCustom);
  frame->Release();
  factory->Release();
  if (FAILED(hr)) {
    converter->Release();
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC format conversion failed");
  }

  UINT iw = 0, ih = 0;
  converter->GetSize(&iw, &ih);
  if (iw == 0 || ih == 0) {
    converter->Release();
    if (coinit_hr == S_OK) CoUninitialize();
    return FlutterError("IMAGE_ERROR", "WIC returned empty image");
  }
  std::vector<BYTE> pixels(static_cast<size_t>(iw) * ih * 4);
  hr = converter->CopyPixels(nullptr, iw * 4,
                              static_cast<UINT>(pixels.size()), pixels.data());
  converter->Release();
  if (coinit_hr == S_OK) CoUninitialize();
  if (FAILED(hr))
    return FlutterError("IMAGE_ERROR", "WIC pixel copy failed");

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

// Returns the CLSID of the GDI+ encoder for |mimeType| (e.g. L"image/png").
static HRESULT GetEncoderClsid(const WCHAR* mimeType, CLSID* pClsid) {
  UINT num = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return E_FAIL;

  std::vector<BYTE> buf(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
  Gdiplus::GetImageEncoders(num, size, codecs);

  for (UINT i = 0; i < num; ++i) {
    if (wcscmp(codecs[i].MimeType, mimeType) == 0) {
      *pClsid = codecs[i].Clsid;
      return S_OK;
    }
  }
  return E_FAIL;
}

// ---------------------------------------------------------------------------
// Print rendering
// ---------------------------------------------------------------------------

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
      } else {
        err = FlutterError("PRINT_ERROR", "StartPage failed");
      }
      EndDoc(hdc);
    } else {
      err = FlutterError("PRINT_ERROR", "StartDoc failed");
    }
  }

  Gdiplus::GdiplusShutdown(token);
  return err;
}

// ---------------------------------------------------------------------------
// Internal PDF render helper
// ---------------------------------------------------------------------------

// Render all pages of |doc| to |hdc|.
// Caller must hold g_pdfium_mtx and have called FPDF_InitLibraryWithConfig.
static std::optional<FlutterError> DoRenderPdfDoc(HDC hdc, FPDF_DOCUMENT doc,
                                                   const std::wstring& docName) {
  const double dpiX = static_cast<double>(GetDeviceCaps(hdc, LOGPIXELSX)) / 72.0;
  const double dpiY = static_cast<double>(GetDeviceCaps(hdc, LOGPIXELSY)) / 72.0;
  const int physW      = GetDeviceCaps(hdc, PHYSICALWIDTH);
  const int physH      = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  const int marginLeft = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const int marginTop  = GetDeviceCaps(hdc, PHYSICALOFFSETY);

  DOCINFOW di = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = docName.c_str();

  std::optional<FlutterError> err;

  if (StartDoc(hdc, &di) > 0) {
    const int pageCount = FPDF_GetPageCount(doc);
    for (int i = 0; i < pageCount; ++i) {
      FPDF_PAGE page = FPDF_LoadPage(doc, i);
      if (!page) continue;

      const int nativeW = static_cast<int>(FPDF_GetPageWidth(page)  * dpiX);
      const int nativeH = static_cast<int>(FPDF_GetPageHeight(page) * dpiY);

      const double scale = std::min({1.0,
          static_cast<double>(physW) / nativeW,
          static_cast<double>(physH) / nativeH});
      const int renderW = static_cast<int>(nativeW * scale);
      const int renderH = static_cast<int>(nativeH * scale);

      if (StartPage(hdc) > 0) {
        FPDF_RenderPage(hdc, page, -marginLeft, -marginTop, renderW, renderH,
                        0, FPDF_ANNOT | FPDF_PRINTING);
        EndPage(hdc);
      }
      FPDF_ClosePage(page);
    }
    EndDoc(hdc);
  } else {
    err = FlutterError("PRINT_ERROR", "StartDoc failed");
  }

  return err;
}

std::optional<FlutterError> RenderPdfToDC(HDC hdc, const std::wstring& path) {
  EnsurePdfiumInit();
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);

  const std::string utf8 = WideToUtf8(path.c_str());
  FPDF_DOCUMENT doc = FPDF_LoadDocument(utf8.c_str(), nullptr);
  if (!doc)
    return FlutterError("PDF_ERROR", "Cannot open PDF: " + utf8);

  auto err = DoRenderPdfDoc(hdc, doc, path);
  FPDF_CloseDocument(doc);
  return err;
}

// ---------------------------------------------------------------------------
// Text-file rendering — GDI direct-to-printer-DC with Windows font linking
// ---------------------------------------------------------------------------

static std::vector<uint8_t> ReadAllBytes(const std::wstring& path) {
  HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return {};
  LARGE_INTEGER sz = {};
  if (!GetFileSizeEx(h, &sz) || sz.QuadPart == 0) { CloseHandle(h); return {}; }
  std::vector<uint8_t> buf(static_cast<size_t>(sz.QuadPart));
  size_t total = 0;
  while (total < buf.size()) {
    const DWORD want = static_cast<DWORD>(std::min<size_t>(buf.size() - total, MAXDWORD));
    DWORD got = 0;
    if (!ReadFile(h, buf.data() + total, want, &got, nullptr) || got == 0) break;
    total += got;
  }
  CloseHandle(h);
  buf.resize(total);
  return buf;
}

// Decode bytes to a wide string — handles UTF-16 LE/BE, UTF-8 (BOM or plain), ANSI.
static std::wstring DecodeTextBytes(const std::vector<uint8_t>& b) {
  const size_t n = b.size();
  if (n == 0) return {};

  if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
    return std::wstring(reinterpret_cast<const wchar_t*>(b.data() + 2), (n - 2) / 2);

  if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    // UTF-16 BE — swap each byte pair to produce UTF-16 LE (wchar_t on Windows).
    std::wstring w((n - 2) / 2, L'\0');
    const uint8_t* src = b.data() + 2;
    for (size_t i = 0; i < w.size(); ++i)
      w[i] = static_cast<wchar_t>((src[i * 2] << 8) | src[i * 2 + 1]);
    return w;
  }

  const int off = (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
  const auto* raw = reinterpret_cast<const char*>(b.data()) + off;
  const int rawLen = static_cast<int>(n - off);

  int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, raw, rawLen, nullptr, 0);
  if (wlen > 0) {
    std::wstring w(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, raw, rawLen, &w[0], wlen);
    return w;
  }

  wlen = MultiByteToWideChar(CP_ACP, 0, raw, rawLen, nullptr, 0);
  std::wstring w(wlen, L'\0');
  MultiByteToWideChar(CP_ACP, 0, raw, rawLen, &w[0], wlen);
  return w;
}

std::wstring ReadTextFile(const std::wstring& path) {
  return DecodeTextBytes(ReadAllBytes(path));
}

std::optional<FlutterError> RenderTextToDC(HDC hdc, const std::wstring& path) {
  const std::wstring text = DecodeTextBytes(ReadAllBytes(path));

  const int dpiX     = GetDeviceCaps(hdc, LOGPIXELSX);
  const int dpiY     = GetDeviceCaps(hdc, LOGPIXELSY);
  const int printW   = GetDeviceCaps(hdc, HORZRES);
  const int printH   = GetDeviceCaps(hdc, VERTRES);
  const int marginX  = dpiX;                    // 1-inch left/right
  const int marginY  = dpiY;                    // 1-inch top/bottom
  const int contentW = printW - 2 * marginX;
  const int contentH = printH - 2 * marginY;

  // DEFAULT_CHARSET enables Windows font linking: GDI substitutes appropriate
  // system fonts per-glyph so CJK, Cyrillic, Arabic, etc. all render correctly.
  LOGFONTW lf = {};
  lf.lfHeight         = -MulDiv(10, dpiY, 72);  // 10 pt
  lf.lfCharSet        = DEFAULT_CHARSET;
  lf.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
  wcscpy_s(lf.lfFaceName, LF_FACESIZE, L"Consolas");
  HFONT hFont    = CreateFontIndirectW(&lf);
  HFONT hOldFont = static_cast<HFONT>(SelectObject(hdc, hFont));

  TEXTMETRICW tm = {};
  GetTextMetricsW(hdc, &tm);
  const int lineH        = tm.tmHeight + tm.tmExternalLeading;
  const int linesPerPage = (contentH > 0 && lineH > 0) ? contentH / lineH : 1;

  // Split the file into display lines: expand tabs, wrap at contentW pixels.
  std::vector<std::wstring> displayLines;
  size_t pos = 0;
  while (pos < text.size()) {
    const size_t nl   = text.find_first_of(L"\r\n", pos);
    const bool   last = (nl == std::wstring::npos);
    const std::wstring raw = last ? text.substr(pos) : text.substr(pos, nl - pos);

    std::wstring expanded;
    expanded.reserve(raw.size());
    for (wchar_t ch : raw) {
      if (ch == L'\t')
        expanded.append(4 - expanded.size() % 4, L' ');
      else
        expanded += ch;
    }

    if (expanded.empty()) {
      displayLines.push_back({});
    } else {
      size_t lineStart = 0;
      while (lineStart < expanded.size()) {
        INT fit = 0;
        SIZE sz = {};
        GetTextExtentExPointW(hdc, expanded.c_str() + lineStart,
                              static_cast<int>(expanded.size() - lineStart),
                              contentW, &fit, nullptr, &sz);
        if (fit <= 0) fit = 1;

        int advance = fit;
        if (lineStart + static_cast<size_t>(fit) < expanded.size()) {
          const size_t sp = expanded.rfind(L' ', lineStart + fit - 1);
          if (sp != std::wstring::npos && sp > lineStart)
            advance = static_cast<int>(sp - lineStart + 1);
        }
        displayLines.push_back(expanded.substr(lineStart, advance));
        lineStart += advance;
      }
    }

    if (last) break;
    pos = (nl + 1 < text.size() && text[nl] == L'\r' && text[nl + 1] == L'\n')
              ? nl + 2 : nl + 1;
  }

  DOCINFOW di    = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = path.c_str();

  std::optional<FlutterError> err;
  if (StartDoc(hdc, &di) > 0) {
    const int total = static_cast<int>(displayLines.size());
    const int pages = (total == 0) ? 1 : (total + linesPerPage - 1) / linesPerPage;

    for (int p = 0; p < pages; ++p) {
      if (StartPage(hdc) <= 0) continue;
      const int first = p * linesPerPage;
      const int end   = std::min(first + linesPerPage, total);
      for (int li = first; li < end; ++li) {
        const std::wstring& ln = displayLines[li];
        if (!ln.empty())
          TextOutW(hdc, marginX, marginY + (li - first) * lineH,
                   ln.c_str(), static_cast<int>(ln.size()));
      }
      EndPage(hdc);
    }
    EndDoc(hdc);
  } else {
    err = FlutterError("PRINT_ERROR", "StartDoc failed");
  }

  SelectObject(hdc, hOldFont);
  DeleteObject(hFont);
  return err;
}

std::optional<FlutterError> RenderOrFallback(HDC hdc,
                                              const std::wstring& wPath,
                                              const std::wstring& printerName) {
  const std::string mime = GetMimeType(wPath);
  if (mime.rfind("image/", 0) == 0) {
    auto err = RenderImageToDC(hdc, wPath);
    DeleteDC(hdc);
    return err;
  }
  if (mime == "application/pdf") {
    auto err = RenderPdfToDC(hdc, wPath);
    DeleteDC(hdc);
    return err;
  }
  if (mime.rfind("text/", 0) == 0) {
    auto err = RenderTextToDC(hdc, wPath);
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

// ---------------------------------------------------------------------------
// Preview rendering
// ---------------------------------------------------------------------------

int GetPdfPageCount(const std::wstring& path) {
  EnsurePdfiumInit();
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);
  const std::string utf8 = WideToUtf8(path.c_str());
  FPDF_DOCUMENT doc = FPDF_LoadDocument(utf8.c_str(), nullptr);
  int count = 0;
  if (doc) {
    count = FPDF_GetPageCount(doc);
    FPDF_CloseDocument(doc);
  }
  return count;
}

std::vector<uint8_t> RenderPdfPageToPng(const std::wstring& path,
                                         int pageIndex,
                                         double dpi) {
  Gdiplus::GdiplusStartupInput gdipInput;
  ULONG_PTR gdipToken = 0;
  if (Gdiplus::GdiplusStartup(&gdipToken, &gdipInput, nullptr) != Gdiplus::Ok)
    return {};

  EnsurePdfiumInit();
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);
  std::vector<uint8_t> result;

  const std::string utf8 = WideToUtf8(path.c_str());
  FPDF_DOCUMENT doc = FPDF_LoadDocument(utf8.c_str(), nullptr);
  if (doc) {
    FPDF_PAGE page = FPDF_LoadPage(doc, pageIndex);
    if (page) {
      const int w = static_cast<int>(FPDF_GetPageWidth(page)  * dpi / 72.0);
      const int h = static_cast<int>(FPDF_GetPageHeight(page) * dpi / 72.0);

      if (w > 0 && h > 0) {
        // Render page to BGRA bitmap (PDFium BGRA == GDI+ PixelFormat32bppARGB).
        FPDF_BITMAP bm = FPDFBitmap_Create(w, h, 1 /* has alpha */);
        if (bm) {
          FPDFBitmap_FillRect(bm, 0, 0, w, h, 0xFFFFFFFF); // white bg
          FPDF_RenderPageBitmap(bm, page, 0, 0, w, h, 0, FPDF_ANNOT);

          void* buf         = FPDFBitmap_GetBuffer(bm);
          const int stride  = FPDFBitmap_GetStride(bm);

          Gdiplus::Bitmap gdiBmp(w, h, stride, PixelFormat32bppARGB,
                                  static_cast<BYTE*>(buf));

          CLSID pngClsid;
          if (SUCCEEDED(GetEncoderClsid(L"image/png", &pngClsid))) {
            IStream* stream = nullptr;
            if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
              if (gdiBmp.Save(stream, &pngClsid, nullptr) == Gdiplus::Ok) {
                LARGE_INTEGER li = {};
                stream->Seek(li, STREAM_SEEK_SET, nullptr);
                STATSTG stat = {};
                stream->Stat(&stat, STATFLAG_NONAME);
                result.resize(stat.cbSize.QuadPart);
                ULONG read = 0;
                stream->Read(result.data(),
                              static_cast<ULONG>(result.size()), &read);
                result.resize(read);
              }
              stream->Release();
            }
          }
          FPDFBitmap_Destroy(bm);
        }
      }
      FPDF_ClosePage(page);
    }
    FPDF_CloseDocument(doc);
  }

  Gdiplus::GdiplusShutdown(gdipToken);

  return result;
}

}  // namespace flutter_print
