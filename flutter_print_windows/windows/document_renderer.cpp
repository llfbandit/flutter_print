#include "document_renderer.h"

#include "flutter_print_utils.h"

#include <gdiplus.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <fpdfview.h>
#include <algorithm>
#include <cctype>
#include <memory>
#include <mutex>
#include <string_view>
#include <type_traits>


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

// Reads up to |max| bytes from the start of the file, or returns nullopt when
// it can't be read (missing, a folder, locked…).
static std::optional<std::vector<uint8_t>> ReadBytes(const std::wstring& path,
                                                     size_t max = SIZE_MAX) {
  // Share writes too, to read a log that its app keeps open.
  HANDLE h = CreateFileW(path.c_str(), GENERIC_READ,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return std::nullopt;
  LARGE_INTEGER sz = {};
  if (!GetFileSizeEx(h, &sz)) { CloseHandle(h); return std::nullopt; }
  std::vector<uint8_t> buf(
      std::min(static_cast<size_t>(sz.QuadPart), max));
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

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

struct WicImage {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapDecoder> decoder;
  UINT pageCount = 1;
};

// Opens an image with WIC, or returns nullopt. Hold a ComScope.
static std::optional<WicImage> OpenImage(const std::wstring& path) {
  WicImage img;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&img.factory))) ||
      FAILED(img.factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
          &img.decoder)))
    return std::nullopt;

  // Only TIFF frames are pages. Other formats use frames for animation or
  // icon sizes.
  GUID format = {};
  UINT frames = 0;
  if (SUCCEEDED(img.decoder->GetContainerFormat(&format)) &&
      format == GUID_ContainerFormatTiff &&
      SUCCEEDED(img.decoder->GetFrameCount(&frames)) && frames > 1)
    img.pageCount = frames;
  return img;
}

// Returns the EXIF orientation (1 to 8), or 1 when there is none.
static USHORT ReadOrientation(IWICBitmapFrameDecode* frame) {
  ComPtr<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader))) return 1;
  PROPVARIANT v;
  PropVariantInit(&v);
  USHORT orientation = 1;
  if (SUCCEEDED(reader->GetMetadataByName(L"System.Photo.Orientation", &v)) &&
      v.vt == VT_UI2)
    orientation = v.uiVal;
  PropVariantClear(&v);
  return orientation;
}

// Returns the transform that turns an image with this EXIF orientation
// upright.
static Gdiplus::RotateFlipType UprightTransform(USHORT orientation) {
  switch (orientation) {
    case 2:  return Gdiplus::RotateNoneFlipX;
    case 3:  return Gdiplus::Rotate180FlipNone;
    case 4:  return Gdiplus::RotateNoneFlipY;
    case 5:  return Gdiplus::Rotate90FlipX;
    case 6:  return Gdiplus::Rotate90FlipNone;
    case 7:  return Gdiplus::Rotate270FlipX;
    case 8:  return Gdiplus::Rotate270FlipNone;
    default: return Gdiplus::RotateNoneFlipNone;
  }
}

// Decodes a page to an upright bitmap, or returns null. A non-zero |maxSide|
// shrinks the page to fit it while decoding.
static std::unique_ptr<Gdiplus::Bitmap> DecodePage(const WicImage& img,
                                                   UINT index,
                                                   UINT maxSide = 0) {
  ComPtr<IWICBitmapFrameDecode> frame;
  UINT w = 0, h = 0;
  if (FAILED(img.decoder->GetFrame(index, &frame)) ||
      FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0)
    return nullptr;

  ComPtr<IWICBitmapSource> source = frame;
  if (maxSide > 0 && std::max(w, h) > maxSide) {
    const double s = static_cast<double>(maxSide) / std::max(w, h);
    w = std::max(1u, static_cast<UINT>(w * s));
    h = std::max(1u, static_cast<UINT>(h * s));
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(img.factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(frame.Get(), w, h,
                                  WICBitmapInterpolationModeFant)))
      return nullptr;
    source = scaler;
  }

  // WIC 32bppBGRA has the same memory layout as GDI+ 32bppARGB.
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(img.factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom)))
    return nullptr;
  auto bmp = std::make_unique<Gdiplus::Bitmap>(
      static_cast<INT>(w), static_cast<INT>(h), PixelFormat32bppARGB);
  if (bmp->GetLastStatus() != Gdiplus::Ok) return nullptr;

  Gdiplus::Rect rect(0, 0, static_cast<INT>(w), static_cast<INT>(h));
  Gdiplus::BitmapData data = {};
  if (bmp->LockBits(&rect, Gdiplus::ImageLockModeWrite, PixelFormat32bppARGB,
                    &data) != Gdiplus::Ok)
    return nullptr;
  const HRESULT hr = converter->CopyPixels(
      nullptr, static_cast<UINT>(data.Stride),
      static_cast<UINT>(data.Stride) * h, static_cast<BYTE*>(data.Scan0));
  bmp->UnlockBits(&data);
  if (FAILED(hr)) return nullptr;

  bmp->RotateFlip(UprightTransform(ReadOrientation(frame.Get())));
  return bmp;
}

// True for an EMF header record or a placeable WMF key.
static bool IsMetafile(const std::vector<uint8_t>& b) {
  const auto u16 = [&](size_t i) { return uint32_t{b[i]} | uint32_t{b[i + 1]} << 8; };
  const auto u32 = [&](size_t i) { return u16(i) | u16(i + 2) << 16; };
  if (b.size() >= 44 && u32(0) == EMR_HEADER && u32(40) == ENHMETA_SIGNATURE)
    return true;
  // GDI+ can't open a WMF without the placeable header.
  return b.size() >= 4 && u32(0) == 0x9AC6CDD7;
}

// Draws |img| fitted and centered in the printable area.
static void DrawFitted(HDC hdc, Gdiplus::Image* img) {
  const int pw = GetDeviceCaps(hdc, HORZRES);
  const int ph = GetDeviceCaps(hdc, VERTRES);
  const UINT iw = img->GetWidth(), ih = img->GetHeight();
  if (iw == 0 || ih == 0) return;
  const float s = std::min(static_cast<float>(pw) / iw,
                           static_cast<float>(ph) / ih);
  const int dw = static_cast<int>(iw * s);
  const int dh = static_cast<int>(ih * s);
  Gdiplus::Graphics g(hdc);
  g.SetPageUnit(Gdiplus::UnitPixel);
  g.DrawImage(img, (pw - dw) / 2, (ph - dh) / 2, dw, dh);
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

static std::vector<uint8_t> EncodePng(Gdiplus::Bitmap& bmp) {
  static const std::optional<CLSID> pngClsid = []() -> std::optional<CLSID> {
    CLSID clsid;
    if (FAILED(GetEncoderClsid(L"image/png", &clsid))) return std::nullopt;
    return clsid;
  }();
  ComPtr<IStream> stream;
  if (!pngClsid ||
      FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      bmp.Save(stream.Get(), &*pngClsid, nullptr) != Gdiplus::Ok)
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

// Draws |img| scaled by |scale| on white and encodes it as PNG.
static std::vector<uint8_t> ImageToPng(Gdiplus::Image* img, double scale) {
  const int w = std::max(1, static_cast<int>(img->GetWidth() * scale));
  const int h = std::max(1, static_cast<int>(img->GetHeight() * scale));
  Gdiplus::Bitmap out(w, h, PixelFormat32bppARGB);
  if (out.GetLastStatus() != Gdiplus::Ok) return {};
  {
    Gdiplus::Graphics g(&out);
    g.Clear(Gdiplus::Color(255, 255, 255));
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.DrawImage(img, 0, 0, w, h);
  }
  return EncodePng(out);
}

// ---------------------------------------------------------------------------
// File kinds
// ---------------------------------------------------------------------------

// True when |b| looks like text: a UTF-16 BOM, or no NUL and no control
// characters other than tab, line breaks, form feed, escape and Ctrl+Z.
static bool LooksLikeText(const std::vector<uint8_t>& b) {
  if (b.size() >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) ||
                        (b[0] == 0xFE && b[1] == 0xFF)))
    return true;
  return std::all_of(b.begin(), b.end(), [](uint8_t c) {
    return c >= 0x20 || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
           c == 0x1A || c == 0x1B;
  });
}

// True for text formats that another app must render: RTF, PostScript, MHTML,
// and HTML or SVG markup. Printing their source is not what users want.
static bool IsRichText(std::string_view text) {
  const size_t start = text.find_first_not_of(" \t\r\n");
  if (start == std::string_view::npos) return false;
  text.remove_prefix(start);

  for (std::string_view prefix : {"{\\rtf", "%!", "MIME-Version:"}) {
    if (text.substr(0, prefix.size()) == prefix) return true;
  }
  if (text[0] != '<') return false;
  std::string lower(text);
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](char c) { return static_cast<char>(tolower(static_cast<unsigned char>(c))); });
  for (std::string_view tag : {"<html", "<!doctype html", "<svg"}) {
    if (lower.find(tag) != std::string::npos) return true;
  }
  return false;
}

static std::wstring DecodeTextBytes(const std::vector<uint8_t>& b);

FileKind DetectFileKind(const std::wstring& path) {
  const auto bytes = ReadBytes(path, 8192);
  if (!bytes) return FileKind::kOther;
  const std::vector<uint8_t>& head = *bytes;
  const std::string_view text(reinterpret_cast<const char*>(head.data()),
                              head.size());

  // PDFium finds the header in the first 1 KB. Past the start, check that
  // PDFium opens the file, as a text file can quote the header.
  const size_t pdf = text.substr(0, 1024).find("%PDF-");
  if (pdf == 0) return FileKind::kPdf;
  if (pdf != std::string_view::npos) {
    std::lock_guard<std::mutex> lock(g_pdfium_mtx);
    if (OpenPdf(path)) return FileKind::kPdf;
  }
  if (IsMetafile(head)) return FileKind::kMetafile;

  // Before WIC, which probes every decoder: bitmap headers are binary.
  if (LooksLikeText(head)) {
    // Decode first, to check UTF-16 files too.
    return IsRichText(WideToUtf8(DecodeTextBytes(head).c_str()))
               ? FileKind::kOther
               : FileKind::kText;
  }

  ComScope com;
  return OpenImage(path) ? FileKind::kImage : FileKind::kOther;
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

// Prints each page fitted and centered in the printable area.
static std::optional<FlutterError> RenderImageToDC(HDC hdc,
                                                   const std::wstring& path,
                                                   int copies,
                                                   const PageRanges& ranges) {
  EnsureGdiplusInit();
  ComScope com;
  auto img = OpenImage(path);
  if (!img)
    return FlutterError("IMAGE_ERROR",
                        "Cannot decode image: " + WideToUtf8(path.c_str()));

  // Keep the last decoded page, for copies of a single page.
  int cached = -1;
  std::unique_ptr<Gdiplus::Bitmap> bmp;
  return PrintPages(hdc, path, static_cast<int>(img->pageCount), copies, ranges,
                    [&](int i) {
                      if (i != cached) {
                        bmp = DecodePage(*img, i);
                        cached = i;
                      }
                      if (!bmp) return false;
                      DrawFitted(hdc, bmp.get());
                      return true;
                    });
}

static std::optional<FlutterError> RenderMetafileToDC(HDC hdc,
                                                      const std::wstring& path,
                                                      int copies,
                                                      const PageRanges& ranges) {
  EnsureGdiplusInit();
  Gdiplus::Metafile metafile(path.c_str());
  if (metafile.GetLastStatus() != Gdiplus::Ok)
    return FlutterError("IMAGE_ERROR",
                        "Cannot open metafile: " + WideToUtf8(path.c_str()));
  return PrintPages(hdc, path, 1, copies, ranges, [&](int) {
    DrawFitted(hdc, &metafile);
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

  const size_t off =
      (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
  const std::string_view raw(reinterpret_cast<const char*>(b.data()) + off,
                             n - off);
  std::wstring w = MultiByteToWide(raw, CP_UTF8, MB_ERR_INVALID_CHARS);
  return w.empty() ? MultiByteToWide(raw, CP_ACP) : w;
}

std::wstring ReadTextFile(const std::wstring& path) {
  const auto bytes = ReadBytes(path);
  return bytes ? DecodeTextBytes(*bytes) : std::wstring{};
}

// Expands the tabs of |raw| and adds it to |lines|, wrapped at |width| pixels,
// at a space when possible.
static void WrapLine(HDC hdc, const std::wstring& raw, int width,
                     std::vector<std::wstring>& lines) {
  std::wstring line;
  line.reserve(raw.size());
  for (wchar_t ch : raw) {
    if (ch == L'\t')
      line.append(4 - line.size() % 4, L' ');
    else
      line += ch;
  }
  if (line.empty()) {
    lines.push_back({});
    return;
  }

  for (size_t start = 0; start < line.size();) {
    INT fit = 0;
    SIZE sz = {};
    GetTextExtentExPointW(hdc, line.c_str() + start,
                          static_cast<int>(line.size() - start), width, &fit,
                          nullptr, &sz);
    size_t advance = static_cast<size_t>(std::max(fit, 1));
    if (start + advance < line.size()) {
      const size_t sp = line.rfind(L' ', start + advance - 1);
      if (sp != std::wstring::npos && sp > start) advance = sp - start + 1;
    }
    lines.push_back(line.substr(start, advance));
    start += advance;
  }
}

// Prints a text file in 10 pt Consolas with 1-inch margins, wrapping long
// lines.
static std::optional<FlutterError> RenderTextToDC(HDC hdc,
                                                  const std::wstring& path,
                                                  int copies,
                                                  const PageRanges& ranges) {
  const auto bytes = ReadBytes(path);
  if (!bytes)
    return FlutterError("FILE_ERROR",
                        "Cannot read file: " + WideToUtf8(path.c_str()));
  const std::wstring text = DecodeTextBytes(*bytes);

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

  std::vector<std::wstring> lines;
  for (size_t pos = 0; pos < text.size();) {
    const size_t nl = text.find_first_of(L"\r\n", pos);
    WrapLine(hdc, text.substr(pos, nl - pos), contentW, lines);
    if (nl == std::wstring::npos) break;
    pos = nl + (text.compare(nl, 2, L"\r\n") == 0 ? 2 : 1);
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
                                       FileKind kind, int copies,
                                       const PageRanges& ranges) {
  switch (kind) {
    case FileKind::kPdf:      return RenderPdfToDC(hdc, wPath, copies, ranges);
    case FileKind::kImage:    return RenderImageToDC(hdc, wPath, copies, ranges);
    case FileKind::kMetafile: return RenderMetafileToDC(hdc, wPath, copies, ranges);
    case FileKind::kText:     return RenderTextToDC(hdc, wPath, copies, ranges);
    case FileKind::kOther:    break;
  }
  return FlutterError("UNSUPPORTED_FILE", "File type not supported for printing");
}

std::optional<FlutterError> ShellPrint(const std::wstring& wPath,
                                       const std::wstring& printerName) {
  // Get the handler process, to catch a crash.
  HANDLE process = nullptr;
  const bool printTo = !printerName.empty();
  if (const DWORD e = ShellRun(printTo ? L"printto" : L"print", wPath,
                               printTo ? printerName.c_str() : nullptr, SW_HIDE,
                               &process))
    return FlutterError("SHELL_ERROR",
                        "Failed to launch print handler for " +
                            WideToUtf8(wPath.c_str()) + " (error " +
                            std::to_string(e) + ")");
  if (!process) return std::nullopt;

  // Wait a little to catch a handler that fails at once. Many handlers keep
  // running after the job is spooled, so a running process is a success.
  constexpr DWORD kHelperWaitMs = 10000;
  std::optional<FlutterError> err;
  DWORD code = 0;
  if (WaitForSingleObject(process, kHelperWaitMs) == WAIT_OBJECT_0 &&
      GetExitCodeProcess(process, &code) && code != 0) {
    err = FlutterError("SHELL_ERROR",
                       "Print handler exited with code " + std::to_string(code));
  }
  CloseHandle(process);
  return err;
}

// ---------------------------------------------------------------------------
// Preview rendering
// ---------------------------------------------------------------------------

int GetPageCount(const std::wstring& path, FileKind kind) {
  switch (kind) {
    case FileKind::kPdf: {
      std::lock_guard<std::mutex> lock(g_pdfium_mtx);
      auto doc = OpenPdf(path);
      return doc ? FPDF_GetPageCount(doc.get()) : 0;
    }
    case FileKind::kImage: {
      ComScope com;
      auto img = OpenImage(path);
      return img ? static_cast<int>(img->pageCount) : 0;
    }
    case FileKind::kMetafile:
      return 1;
    default:
      return 0;
  }
}

static std::vector<uint8_t> RenderPdfPageToPng(const std::wstring& path,
                                               int pageIndex, double dpi) {
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
  return EncodePng(gdiBmp);
}

std::vector<uint8_t> RenderPageToPng(const std::wstring& path, FileKind kind,
                                     int pageIndex, double dpi) {
  EnsureGdiplusInit();
  const UINT maxSide = static_cast<UINT>(12 * dpi);

  switch (kind) {
    case FileKind::kPdf:
      return RenderPdfPageToPng(path, pageIndex, dpi);
    case FileKind::kImage: {
      ComScope com;
      auto img = OpenImage(path);
      if (!img || pageIndex < 0) return {};
      // The decoder shrinks large pages, and never enlarges small ones.
      auto bmp = DecodePage(*img, static_cast<UINT>(pageIndex), maxSide);
      return bmp ? ImageToPng(bmp.get(), 1.0) : std::vector<uint8_t>{};
    }
    case FileKind::kMetafile: {
      Gdiplus::Metafile metafile(path.c_str());
      if (metafile.GetLastStatus() != Gdiplus::Ok) return {};
      return ImageToPng(&metafile, static_cast<double>(maxSide) /
                                       std::max({metafile.GetWidth(),
                                                 metafile.GetHeight(), 1u}));
    }
    default:
      return {};
  }
}

}  // namespace flutter_print
