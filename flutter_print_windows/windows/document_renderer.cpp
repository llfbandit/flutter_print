#include "document_renderer.h"

#include "flutter_print_utils.h"

#include <gdiplus.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <fpdfview.h>
#include <algorithm>
#include <memory>
#include <mutex>
#include <type_traits>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace flutter_print {

using Microsoft::WRL::ComPtr;

// PDFium is not thread-safe: hold this lock while using it.
static std::mutex g_pdfium_mtx;

struct PdfCloser {
  void operator()(FPDF_DOCUMENT doc) const { FPDF_CloseDocument(doc); }
  void operator()(FPDF_PAGE page) const { FPDF_ClosePage(page); }
  void operator()(FPDF_BITMAP bitmap) const { FPDFBitmap_Destroy(bitmap); }
};
template <typename T>
using PdfPtr = std::unique_ptr<std::remove_pointer_t<T>, PdfCloser>;

// Opens a PDF, or returns null. Hold g_pdfium_mtx.
static PdfPtr<FPDF_DOCUMENT> OpenPdf(const std::wstring& path) {
  static std::once_flag init;
  std::call_once(init, [] {
    FPDF_LIBRARY_CONFIG cfg = {};
    cfg.version = 2;
    FPDF_InitLibraryWithConfig(&cfg);
  });
  return PdfPtr<FPDF_DOCUMENT>(
      FPDF_LoadDocument(WideToUtf8(path.c_str()).c_str(), nullptr));
}

// GDI+ tokens have no ref count, so a start and stop per call races between
// the print and preview threads. Start GDI+ once and never stop it.
static void EnsureGdiplusInit() {
  static std::once_flag init;
  std::call_once(init, [] {
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR token = 0;
    Gdiplus::GdiplusStartup(&token, &input, nullptr);
  });
}

// ---------------------------------------------------------------------------
// Print rendering
// ---------------------------------------------------------------------------

static bool PageSelected(int pageOneBased, const PageRanges& ranges) {
  if (ranges.empty()) return true;
  for (const auto& r : ranges) {
    if (pageOneBased >= r.first && pageOneBased <= r.second) return true;
  }
  return false;
}

static std::optional<FlutterError> CheckAnyPageSelected(
    int pageCount, const PageRanges& ranges) {
  if (ranges.empty()) return std::nullopt;
  const bool any = std::any_of(ranges.begin(), ranges.end(), [&](const auto& r) {
    return r.first <= r.second && r.first <= pageCount && r.second >= 1;
  });
  if (any) return std::nullopt;
  return FlutterError("INVALID_PAGE_RANGE", "Page ranges select no page");
}

// Prints the pages that |ranges| selects, |copies| times, as one job.
// |drawPage| draws the 0-based page it gets, and returns false when it can't:
// the job is then canceled, not printed with a blank page.
template <typename DrawPage>
static std::optional<FlutterError> PrintPages(HDC hdc,
                                              const std::wstring& docName,
                                              int pageCount, int copies,
                                              const PageRanges& ranges,
                                              DrawPage drawPage) {
  // Check first, so an empty selection never sends a blank job.
  if (auto err = CheckAnyPageSelected(pageCount, ranges)) return err;

  DOCINFOW di = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = docName.c_str();
  if (StartDocW(hdc, &di) <= 0)
    return FlutterError("PRINT_ERROR", "StartDoc failed");

  for (int c = 0; c < copies; ++c) {
    for (int i = 0; i < pageCount; ++i) {
      if (!PageSelected(i + 1, ranges)) continue;
      if (StartPage(hdc) <= 0) {
        AbortDoc(hdc);
        return FlutterError("PRINT_ERROR", "StartPage failed");
      }
      if (!drawPage(i)) {
        AbortDoc(hdc);
        return FlutterError("PRINT_ERROR",
                            "Cannot draw page " + std::to_string(i + 1));
      }
      EndPage(hdc);
    }
  }
  EndDoc(hdc);
  return std::nullopt;
}

// Decodes an image with WIC into a 32bpp GDI+ bitmap, for the formats GDI+
// can't decode (WebP, HEIC…). |outPixels| backs |outBmp|: keep it alive longer.
static std::optional<FlutterError> DecodeViaWIC(
    const std::wstring& path, std::vector<BYTE>& outPixels,
    std::unique_ptr<Gdiplus::Bitmap>& outBmp) {
  // Declared first, so it uninitializes COM after the pointers below release.
  struct ComScope {
    bool ok;
    ~ComScope() { if (ok) CoUninitialize(); }
  } com{SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))};

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))))
    return FlutterError("IMAGE_ERROR", "WIC not available on this system");

  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
          &decoder)))
    return FlutterError("IMAGE_ERROR",
                        "WIC codec not installed for: " +
                            WideToUtf8(path.c_str()));

  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame)))
    return FlutterError("IMAGE_ERROR", "WIC frame decode failed");

  // WIC 32bppBGRA has the same memory layout as GDI+ 32bppARGB.
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom)))
    return FlutterError("IMAGE_ERROR", "WIC format conversion failed");

  UINT iw = 0, ih = 0;
  converter->GetSize(&iw, &ih);
  if (iw == 0 || ih == 0)
    return FlutterError("IMAGE_ERROR", "WIC returned empty image");

  outPixels.resize(static_cast<size_t>(iw) * ih * 4);
  if (FAILED(converter->CopyPixels(nullptr, iw * 4,
                                   static_cast<UINT>(outPixels.size()),
                                   outPixels.data())))
    return FlutterError("IMAGE_ERROR", "WIC pixel copy failed");

  outBmp = std::make_unique<Gdiplus::Bitmap>(
      static_cast<INT>(iw), static_cast<INT>(ih), static_cast<INT>(iw) * 4,
      PixelFormat32bppARGB, outPixels.data());
  return std::nullopt;
}

// Returns the CLSID of the GDI+ encoder for |mimeType|, e.g. L"image/png".
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

// Prints an image fitted and centered in the printable area.
static std::optional<FlutterError> RenderImageToDC(HDC hdc,
                                                   const std::wstring& path,
                                                   int copies,
                                                   const PageRanges& ranges) {
  EnsureGdiplusInit();

  Gdiplus::Image gdiImg(path.c_str());
  std::vector<BYTE> wicPixels;  // Backs wicBmp.
  std::unique_ptr<Gdiplus::Bitmap> wicBmp;
  Gdiplus::Image* img = &gdiImg;
  if (gdiImg.GetLastStatus() != Gdiplus::Ok) {
    if (auto err = DecodeViaWIC(path, wicPixels, wicBmp)) return err;
    img = wicBmp.get();
  }

  const int pw = GetDeviceCaps(hdc, HORZRES);
  const int ph = GetDeviceCaps(hdc, VERTRES);
  const UINT iw = img->GetWidth(), ih = img->GetHeight();
  const float s = std::min(static_cast<float>(pw) / iw,
                           static_cast<float>(ph) / ih);
  const int dw = static_cast<int>(iw * s);
  const int dh = static_cast<int>(ih * s);
  const int dx = (pw - dw) / 2;
  const int dy = (ph - dh) / 2;

  return PrintPages(hdc, path, 1, copies, ranges, [&](int) {
    Gdiplus::Graphics g(hdc);
    g.SetPageUnit(Gdiplus::UnitPixel);
    g.DrawImage(img, dx, dy, dw, dh);
    return true;
  });
}

static std::optional<FlutterError> RenderPdfToDC(HDC hdc,
                                                 const std::wstring& path,
                                                 int copies,
                                                 const PageRanges& ranges) {
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);
  auto doc = OpenPdf(path);
  if (!doc)
    return FlutterError("PDF_ERROR",
                        "Cannot open PDF: " + WideToUtf8(path.c_str()));

  // PDF points to device pixels.
  const double scaleX = GetDeviceCaps(hdc, LOGPIXELSX) / 72.0;
  const double scaleY = GetDeviceCaps(hdc, LOGPIXELSY) / 72.0;
  const int physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  const int physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  const int offX  = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const int offY  = GetDeviceCaps(hdc, PHYSICALOFFSETY);

  return PrintPages(
      hdc, path, FPDF_GetPageCount(doc.get()), copies, ranges, [&](int i) {
        PdfPtr<FPDF_PAGE> page(FPDF_LoadPage(doc.get(), i));
        if (!page) return false;
        const int w = static_cast<int>(FPDF_GetPageWidth(page.get()) * scaleX);
        const int h = static_cast<int>(FPDF_GetPageHeight(page.get()) * scaleY);
        // Draw from the sheet corner at true size; shrink pages too large
        // for the sheet.
        const double s = std::min({1.0, static_cast<double>(physW) / w,
                                   static_cast<double>(physH) / h});
        FPDF_RenderPage(hdc, page.get(), -offX, -offY,
                        static_cast<int>(w * s), static_cast<int>(h * s), 0,
                        FPDF_ANNOT | FPDF_PRINTING);
        return true;
      });
}

static std::vector<uint8_t> ReadAllBytes(const std::wstring& path) {
  HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                         nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return {};
  LARGE_INTEGER sz = {};
  if (!GetFileSizeEx(h, &sz) || sz.QuadPart == 0) { CloseHandle(h); return {}; }
  std::vector<uint8_t> buf(static_cast<size_t>(sz.QuadPart));
  size_t total = 0;
  while (total < buf.size()) {
    const DWORD want =
        static_cast<DWORD>(std::min<size_t>(buf.size() - total, MAXDWORD));
    DWORD got = 0;
    if (!ReadFile(h, buf.data() + total, want, &got, nullptr) || got == 0) break;
    total += got;
  }
  CloseHandle(h);
  buf.resize(total);
  return buf;
}

// Decodes UTF-16 LE/BE (with BOM), UTF-8 (with or without BOM), else ANSI.
static std::wstring DecodeTextBytes(const std::vector<uint8_t>& b) {
  const size_t n = b.size();
  if (n == 0) return {};

  if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
    return std::wstring(reinterpret_cast<const wchar_t*>(b.data() + 2),
                        (n - 2) / 2);

  if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    // Swap the bytes of each UTF-16 BE unit.
    std::wstring w((n - 2) / 2, L'\0');
    const uint8_t* src = b.data() + 2;
    for (size_t i = 0; i < w.size(); ++i)
      w[i] = static_cast<wchar_t>((src[i * 2] << 8) | src[i * 2 + 1]);
    return w;
  }

  const int off = (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
  const auto* raw = reinterpret_cast<const char*>(b.data()) + off;
  const int rawLen = static_cast<int>(n - off);

  int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, raw, rawLen,
                                 nullptr, 0);
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

// Prints a text file in 10 pt Consolas with 1-inch margins, wrapping long
// lines.
static std::optional<FlutterError> RenderTextToDC(HDC hdc,
                                                  const std::wstring& path,
                                                  int copies,
                                                  const PageRanges& ranges) {
  const std::wstring text = ReadTextFile(path);

  const int dpiX     = GetDeviceCaps(hdc, LOGPIXELSX);
  const int dpiY     = GetDeviceCaps(hdc, LOGPIXELSY);
  const int marginX  = dpiX;
  const int marginY  = dpiY;
  const int contentW = GetDeviceCaps(hdc, HORZRES) - 2 * marginX;
  const int contentH = GetDeviceCaps(hdc, VERTRES) - 2 * marginY;

  // DEFAULT_CHARSET turns on font linking: GDI picks a fallback font for each
  // glyph Consolas lacks (CJK, Arabic…).
  LOGFONTW lf = {};
  lf.lfHeight         = -MulDiv(10, dpiY, 72);
  lf.lfCharSet        = DEFAULT_CHARSET;
  lf.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
  wcscpy_s(lf.lfFaceName, LF_FACESIZE, L"Consolas");
  HFONT hFont    = CreateFontIndirectW(&lf);
  HFONT hOldFont = static_cast<HFONT>(SelectObject(hdc, hFont));

  TEXTMETRICW tm = {};
  GetTextMetricsW(hdc, &tm);
  const int lineH        = tm.tmHeight + tm.tmExternalLeading;
  const int linesPerPage = (contentH > 0 && lineH > 0) ? contentH / lineH : 1;

  // Split into printed lines: expand tabs, wrap at contentW, at a space when
  // possible.
  std::vector<std::wstring> lines;
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
      lines.push_back({});
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
        lines.push_back(expanded.substr(lineStart, advance));
        lineStart += advance;
      }
    }

    if (last) break;
    pos = (nl + 1 < text.size() && text[nl] == L'\r' && text[nl + 1] == L'\n')
              ? nl + 2 : nl + 1;
  }

  const int total = static_cast<int>(lines.size());
  const int pages = (total == 0) ? 1 : (total + linesPerPage - 1) / linesPerPage;

  auto err = PrintPages(hdc, path, pages, copies, ranges, [&](int p) {
    const int first = p * linesPerPage;
    const int end   = std::min(first + linesPerPage, total);
    for (int li = first; li < end; ++li) {
      const std::wstring& ln = lines[li];
      if (!ln.empty())
        TextOutW(hdc, marginX, marginY + (li - first) * lineH,
                 ln.c_str(), static_cast<int>(ln.size()));
    }
    return true;
  });

  SelectObject(hdc, hOldFont);
  DeleteObject(hFont);
  return err;
}

std::optional<FlutterError> RenderToDC(HDC hdc, const std::wstring& wPath,
                                       const std::string& mime, int copies,
                                       const PageRanges& ranges) {
  if (mime == "application/pdf") return RenderPdfToDC(hdc, wPath, copies, ranges);
  if (mime.rfind("text/", 0) == 0) return RenderTextToDC(hdc, wPath, copies, ranges);
  return RenderImageToDC(hdc, wPath, copies, ranges);
}

std::optional<FlutterError> ShellPrint(const std::wstring& wPath,
                                       const std::wstring& printerName) {
  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  // NOCLOSEPROCESS: get the handler process, to catch a crash.
  // NOASYNC: finish any DDE talk before returning, as we pump no messages.
  // FLAG_NO_UI: show no shell error dialog.
  sei.fMask  = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  sei.lpVerb = printerName.empty() ? L"print" : L"printto";
  sei.lpFile = wPath.c_str();
  sei.lpParameters = printerName.empty() ? nullptr : printerName.c_str();
  sei.nShow  = SW_HIDE;

  if (!ShellExecuteExW(&sei)) {
    const DWORD e = GetLastError();
    return FlutterError("SHELL_ERROR",
                        "Failed to launch print handler for " +
                            WideToUtf8(wPath.c_str()) + " (error " +
                            std::to_string(e) + ")");
  }
  if (!sei.hProcess) return std::nullopt;

  // Wait a little to catch a handler that fails at once. Many handlers keep
  // running after the job is spooled, so a running process is a success.
  constexpr DWORD kHelperWaitMs = 10000;
  std::optional<FlutterError> err;
  DWORD code = 0;
  if (WaitForSingleObject(sei.hProcess, kHelperWaitMs) == WAIT_OBJECT_0 &&
      GetExitCodeProcess(sei.hProcess, &code) && code != 0) {
    err = FlutterError("SHELL_ERROR",
                       "Print handler exited with code " + std::to_string(code));
  }
  CloseHandle(sei.hProcess);
  return err;
}

// ---------------------------------------------------------------------------
// Preview rendering
// ---------------------------------------------------------------------------

int GetPdfPageCount(const std::wstring& path) {
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);
  auto doc = OpenPdf(path);
  return doc ? FPDF_GetPageCount(doc.get()) : 0;
}

std::vector<uint8_t> RenderPdfPageToPng(const std::wstring& path,
                                         int pageIndex,
                                         double dpi) {
  EnsureGdiplusInit();
  std::lock_guard<std::mutex> lock(g_pdfium_mtx);
  auto doc = OpenPdf(path);
  if (!doc) return {};
  PdfPtr<FPDF_PAGE> page(FPDF_LoadPage(doc.get(), pageIndex));
  if (!page) return {};

  const int w = static_cast<int>(FPDF_GetPageWidth(page.get())  * dpi / 72.0);
  const int h = static_cast<int>(FPDF_GetPageHeight(page.get()) * dpi / 72.0);
  if (w <= 0 || h <= 0) return {};

  // PDFium BGRA has the same memory layout as GDI+ 32bppARGB.
  PdfPtr<FPDF_BITMAP> bitmap(FPDFBitmap_Create(w, h, /*alpha=*/1));
  if (!bitmap) return {};
  FPDFBitmap_FillRect(bitmap.get(), 0, 0, w, h, 0xFFFFFFFF);
  FPDF_RenderPageBitmap(bitmap.get(), page.get(), 0, 0, w, h, 0, FPDF_ANNOT);

  Gdiplus::Bitmap gdiBmp(w, h, FPDFBitmap_GetStride(bitmap.get()),
                         PixelFormat32bppARGB,
                         static_cast<BYTE*>(FPDFBitmap_GetBuffer(bitmap.get())));
  CLSID pngClsid;
  ComPtr<IStream> stream;
  if (FAILED(GetEncoderClsid(L"image/png", &pngClsid)) ||
      FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      gdiBmp.Save(stream.Get(), &pngClsid, nullptr) != Gdiplus::Ok)
    return {};

  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return {};
  std::vector<uint8_t> png(static_cast<size_t>(stat.cbSize.QuadPart));
  const LARGE_INTEGER zero = {};
  ULONG read = 0;
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  stream->Read(png.data(), static_cast<ULONG>(png.size()), &read);
  png.resize(read);
  return png;
}

}  // namespace flutter_print
