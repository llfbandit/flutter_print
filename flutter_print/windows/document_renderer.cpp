#include "document_renderer.h"

#include "flutter_print_utils.h"

#include <gdiplus.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <fpdfview.h>
#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <memory>
#include <mutex>
#include <string_view>
#include <type_traits>
#include <unordered_map>


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

// An open PDF. PDFium reads it through our own handle, which lets other apps
// write, rename or delete the file meanwhile. Hold g_pdfium_mtx while using
// or destroying it.
class PdfFile {
 public:
  // Opens a PDF, or returns null.
  static std::unique_ptr<PdfFile> Open(const std::wstring& path) {
    static std::once_flag init;
    std::call_once(init, [] {
      FPDF_LIBRARY_CONFIG cfg = {};
      cfg.version = 2;
      FPDF_InitLibraryWithConfig(&cfg);
    });
    std::unique_ptr<PdfFile> f(new PdfFile);
    f->file_ = CreateFileW(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    LARGE_INTEGER size = {};
    if (f->file_ == INVALID_HANDLE_VALUE || !GetFileSizeEx(f->file_, &size) ||
        size.QuadPart > ULONG_MAX)
      return nullptr;
    f->access_.m_FileLen  = static_cast<unsigned long>(size.QuadPart);
    f->access_.m_GetBlock = &PdfFile::GetBlock;
    f->access_.m_Param    = f->file_;
    f->doc_.reset(FPDF_LoadCustomDocument(&f->access_, nullptr));
    if (!f->doc_) return nullptr;
    return f;
  }

  ~PdfFile() {
    doc_.reset();
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
  }
  PdfFile(const PdfFile&) = delete;
  PdfFile& operator=(const PdfFile&) = delete;

  FPDF_DOCUMENT get() const { return doc_.get(); }

 private:
  PdfFile() = default;

  // Reads |size| bytes at |pos| for PDFium. Returns 0 on error.
  static int GetBlock(void* param, unsigned long pos, unsigned char* buf,
                      unsigned long size) {
    OVERLAPPED at = {};
    at.Offset = pos;
    DWORD got = 0;
    return ReadFile(static_cast<HANDLE>(param), buf, size, &got, &at) &&
           got == size;
  }

  HANDLE file_ = INVALID_HANDLE_VALUE;
  FPDF_FILEACCESS access_ = {};
  PdfPtr<FPDF_DOCUMENT> doc_;
};

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
  const UINT fullW = w, fullH = h;
  // The DPI gives the real size. Use 96 when the file has none.
  double dpiX = 0, dpiY = 0;
  if (FAILED(frame->GetResolution(&dpiX, &dpiY)) || dpiX <= 0 || dpiY <= 0)
    dpiX = dpiY = 96;

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

  const Gdiplus::RotateFlipType upright =
      UprightTransform(ReadOrientation(frame.Get()));
  bmp->RotateFlip(upright);
  // Keep the real size: a smaller decode has a lower DPI, and a turn swaps
  // the sides.
  const double outX = dpiX * w / fullW, outY = dpiY * h / fullH;
  const bool turned = upright == Gdiplus::Rotate90FlipNone ||
                      upright == Gdiplus::Rotate270FlipNone ||
                      upright == Gdiplus::Rotate90FlipX ||
                      upright == Gdiplus::Rotate270FlipX;
  bmp->SetResolution(static_cast<Gdiplus::REAL>(turned ? outY : outX),
                     static_cast<Gdiplus::REAL>(turned ? outX : outY));
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

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

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

// Replaces each tab with spaces up to the next multiple of 4 columns.
static std::wstring ExpandTabs(std::wstring text) {
  if (text.find(L'\t') == std::wstring::npos) return text;
  std::wstring out;
  out.reserve(text.size());
  size_t col = 0;
  for (wchar_t ch : text) {
    if (ch == L'\t') {
      const size_t n = 4 - col % 4;
      out.append(n, L' ');
      col += n;
    } else {
      out += ch;
      col = (ch == L'\r' || ch == L'\n') ? 0 : col + 1;
    }
  }
  return out;
}

// Widths of characters in the font selected in a DC. GDI sums the widths of
// the characters of a string, so asking it once per character is enough.
class CharWidths {
 public:
  explicit CharWidths(HDC hdc) : hdc_(hdc), widths_(0x10000, -1) {}

  // Counts the characters at the start of |s| that fit in |width| pixels.
  // Keeps surrogate pairs whole.
  size_t Fit(std::wstring_view s, int width) {
    int used = 0;
    for (size_t i = 0; i < s.size();) {
      size_t units = 1;
      const int w = At(s, i, units);
      if (used + w > width) return i;
      used += w;
      i += units;
    }
    return s.size();
  }

  // The advance of each UTF-16 unit of |s|. A surrogate pair's width goes on
  // its first unit.
  std::vector<INT> Advances(std::wstring_view s) {
    std::vector<INT> dx(s.size(), 0);
    for (size_t i = 0; i < s.size();) {
      size_t units = 1;
      dx[i] = At(s, i, units);
      i += units;
    }
    return dx;
  }

 private:
  // The width of the character at |i| in |s|. Sets |units| to its length: 2
  // for a surrogate pair.
  int At(std::wstring_view s, size_t i, size_t& units) {
    const bool pair = IS_HIGH_SURROGATE(s[i]) && i + 1 < s.size() &&
                      IS_LOW_SURROGATE(s[i + 1]);
    units = pair ? 2 : 1;
    return pair ? PairWidth(s[i], s[i + 1]) : Width(s[i]);
  }

  int Width(wchar_t c) {
    int& w = widths_[c];
    if (w < 0) w = Measure(&c, 1);
    return w;
  }

  int PairWidth(wchar_t hi, wchar_t lo) {
    const uint32_t key = (static_cast<uint32_t>(hi) << 16) | lo;
    const auto it = pairs_.find(key);
    if (it != pairs_.end()) return it->second;
    const wchar_t pair[] = {hi, lo};
    return pairs_[key] = Measure(pair, 2);
  }

  int Measure(const wchar_t* s, int n) const {
    SIZE sz = {};
    GetTextExtentPoint32W(hdc_, s, n, &sz);
    return sz.cx;
  }

  HDC hdc_;
  std::vector<int> widths_;
  std::unordered_map<uint32_t, int> pairs_;
};

// A line of a text page: a range of the document text.
struct TextSpan {
  size_t start = 0;
  size_t length = 0;
};

// Adds |line|, which starts at |start| in the text, to |lines|, wrapped at
// |width| pixels, at a space when possible.
static void WrapLine(CharWidths& widths, std::wstring_view line, size_t start,
                     int width, std::vector<TextSpan>& lines) {
  if (line.empty()) {
    lines.push_back({start, 0});
    return;
  }
  for (size_t pos = 0; pos < line.size();) {
    size_t advance = std::max<size_t>(widths.Fit(line.substr(pos), width), 1);
    if (pos + advance < line.size()) {
      const size_t sp = line.substr(pos, advance).rfind(L' ');
      if (sp != std::wstring_view::npos && sp > 0) advance = sp + 1;
    }
    lines.push_back({start + pos, advance});
    pos += advance;
  }
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
    if (PdfFile::Open(path)) return FileKind::kPdf;
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
// Documents
// ---------------------------------------------------------------------------

// A printer page, and where it lands on the DC that gets the drawing.
struct PageTarget {
  HDC hdc = nullptr;
  // Printer metrics in printer pixels: the printable area has the res size,
  // at the off offset in the phys sheet.
  int dpiX = 0, dpiY = 0;
  int resW = 0, resH = 0;
  int physW = 0, physH = 0;
  int offX = 0, offY = 0;
  // Target pixels per printer pixel, and where the printable area starts on
  // the target. Print uses 1 and 0: it draws on the printer DC itself.
  double scaleX = 1, scaleY = 1;
  int originX = 0, originY = 0;
  // The pixels of the target when it is a bitmap, as for the preview:
  // 32 bits, top-down. PDFium draws on them directly.
  void* bits = nullptr;
  int bitsW = 0, bitsH = 0;

  // Maps a rect in printer pixels, from the printable area corner, to the
  // target.
  Gdiplus::Rect Map(double x, double y, double w, double h) const {
    return Gdiplus::Rect(originX + static_cast<INT>(std::lround(x * scaleX)),
                         originY + static_cast<INT>(std::lround(y * scaleY)),
                         static_cast<INT>(std::lround(w * scaleX)),
                         static_cast<INT>(std::lround(h * scaleY)));
  }
};

static PageTarget PrinterTarget(HDC hdc) {
  PageTarget t;
  t.hdc   = hdc;
  t.dpiX  = GetDeviceCaps(hdc, LOGPIXELSX);
  t.dpiY  = GetDeviceCaps(hdc, LOGPIXELSY);
  t.resW  = GetDeviceCaps(hdc, HORZRES);
  t.resH  = GetDeviceCaps(hdc, VERTRES);
  t.physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  t.physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  t.offX  = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  t.offY  = GetDeviceCaps(hdc, PHYSICALOFFSETY);
  return t;
}

// Draws |img| centered in the printable area, at its real size (pixels and
// DPI). Shrinks it when it is larger than the area, but never enlarges it.
static void DrawFitted(const PageTarget& t, Gdiplus::Image* img) {
  const UINT iw = img->GetWidth(), ih = img->GetHeight();
  if (iw == 0 || ih == 0) return;
  double s = std::min(static_cast<double>(t.resW) / iw,
                      static_cast<double>(t.resH) / ih);
  const double rx = img->GetHorizontalResolution();
  const double ry = img->GetVerticalResolution();
  if (rx > 0 && ry > 0) s = std::min({s, t.dpiX / rx, t.dpiY / ry});
  const double dw = iw * s, dh = ih * s;
  Gdiplus::Graphics g(t.hdc);
  g.SetPageUnit(Gdiplus::UnitPixel);
  // The preview shrinks decodes up to twice its size: shrink them smoothly.
  if (t.scaleX < 1 || t.scaleY < 1)
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g.DrawImage(img, t.Map((t.resW - dw) / 2, (t.resH - dh) / 2, dw, dh));
}

// A file laid out on the pages of a printer.
class Document {
 public:
  virtual ~Document() = default;
  virtual int PageCount() const = 0;
  // Draws a page (0-based). Returns false when it can't.
  virtual bool DrawPage(const PageTarget& t, int index) = 0;
};

// Each call locks PDFium, so an open document doesn't block other threads.
class PdfDocument : public Document {
 public:
  static std::unique_ptr<Document> Open(const std::wstring& path) {
    std::lock_guard<std::mutex> lock(g_pdfium_mtx);
    auto file = PdfFile::Open(path);
    if (!file) return nullptr;
    return std::unique_ptr<Document>(new PdfDocument(std::move(file)));
  }

  ~PdfDocument() override {
    std::lock_guard<std::mutex> lock(g_pdfium_mtx);
    file_.reset();
  }

  int PageCount() const override {
    std::lock_guard<std::mutex> lock(g_pdfium_mtx);
    return FPDF_GetPageCount(file_->get());
  }

  bool DrawPage(const PageTarget& t, int index) override {
    std::lock_guard<std::mutex> lock(g_pdfium_mtx);
    PdfPtr<FPDF_PAGE> page(FPDF_LoadPage(file_->get(), index));
    if (!page) return false;
    // Draw from the sheet corner at true size; shrink pages too large for
    // the sheet.
    const double w = FPDF_GetPageWidth(page.get()) * t.dpiX / 72.0;
    const double h = FPDF_GetPageHeight(page.get()) * t.dpiY / 72.0;
    const double s = std::min({1.0, t.physW / w, t.physH / h});
    const Gdiplus::Rect r = t.Map(-t.offX, -t.offY, w * s, h * s);
    if (!t.bits) {
      FPDF_RenderPage(t.hdc, page.get(), r.X, r.Y, r.Width, r.Height, 0,
                      FPDF_ANNOT | FPDF_PRINTING);
      return true;
    }
    // On a bitmap, PDFium renders only the part inside it: a zoomed-in
    // preview region doesn't cost the whole sheet. Clip to the printable
    // area, as the printer does.
    PdfPtr<FPDF_BITMAP> bitmap(FPDFBitmap_CreateEx(
        t.bitsW, t.bitsH, FPDFBitmap_BGRx, t.bits, t.bitsW * 4));
    if (!bitmap) return false;
    const FS_MATRIX m = {
        static_cast<float>(r.Width / FPDF_GetPageWidth(page.get())), 0, 0,
        static_cast<float>(r.Height / FPDF_GetPageHeight(page.get())),
        static_cast<float>(r.X), static_cast<float>(r.Y)};
    const Gdiplus::Rect area = t.Map(0, 0, t.resW, t.resH);
    const FS_RECTF clip = {
        static_cast<float>(std::max(0, area.X)),
        static_cast<float>(std::max(0, area.Y)),
        static_cast<float>(std::min(t.bitsW, area.GetRight())),
        static_cast<float>(std::min(t.bitsH, area.GetBottom()))};
    FPDF_RenderPageBitmapWithMatrix(bitmap.get(), page.get(), &m, &clip,
                                    FPDF_ANNOT | FPDF_PRINTING);
    return true;
  }

 private:
  explicit PdfDocument(std::unique_ptr<PdfFile> file) : file_(std::move(file)) {}
  std::unique_ptr<PdfFile> file_;
};

// Each page fitted and centered in the printable area.
class ImageDocument : public Document {
 public:
  static std::unique_ptr<Document> Open(const std::wstring& path) {
    std::unique_ptr<ImageDocument> d(new ImageDocument);
    auto img = OpenImage(path);
    if (!img) return nullptr;
    d->img_ = std::move(*img);
    return d;
  }

  int PageCount() const override { return static_cast<int>(img_.pageCount); }

  bool DrawPage(const PageTarget& t, int index) override {
    // Decode at the target size when it is smaller, as for the preview. Round
    // it up to a power of 2, so zoom steps share a decode. Keep the last
    // decoded page, for copies of a single page.
    const bool shrink = t.scaleX < 1 || t.scaleY < 1;
    UINT maxSide = 0;
    if (shrink) {
      const double side = std::max(t.resW * t.scaleX, t.resH * t.scaleY);
      for (maxSide = 256; maxSide < side; maxSide <<= 1) {}
    }
    if (index != cached_ || maxSide != cachedSide_) {
      bmp_ = DecodePage(img_, static_cast<UINT>(index), maxSide);
      cached_ = index;
      cachedSide_ = maxSide;
    }
    if (!bmp_) return false;
    DrawFitted(t, bmp_.get());
    return true;
  }

 private:
  ImageDocument() = default;
  // Declared first, so COM outlives the decoder.
  ComScope com_;
  WicImage img_;
  // The decoded page, and the size it was decoded for (0 for full size).
  int cached_ = -1;
  UINT cachedSide_ = 0;
  std::unique_ptr<Gdiplus::Bitmap> bmp_;
};

// One page, fitted and centered in the printable area.
class MetafileDocument : public Document {
 public:
  static std::unique_ptr<Document> Open(const std::wstring& path) {
    auto d = std::make_unique<MetafileDocument>(path);
    if (d->metafile_.GetLastStatus() != Gdiplus::Ok) return nullptr;
    return d;
  }

  explicit MetafileDocument(const std::wstring& path)
      : metafile_(path.c_str()) {}

  int PageCount() const override { return 1; }

  bool DrawPage(const PageTarget& t, int) override {
    DrawFitted(t, &metafile_);
    return true;
  }

 private:
  Gdiplus::Metafile metafile_;
};

// Text in 10 pt Consolas with 1-inch margins, long lines wrapped.
class TextDocument : public Document {
 public:
  // Lays |text| out with the metrics of |ref|, the printer DC or IC.
  TextDocument(HDC ref, std::wstring text)
      : text_(ExpandTabs(std::move(text))) {
    const int dpiX = GetDeviceCaps(ref, LOGPIXELSX);
    const int dpiY = GetDeviceCaps(ref, LOGPIXELSY);
    marginX_ = dpiX;
    marginY_ = dpiY;
    const int contentW = GetDeviceCaps(ref, HORZRES) - 2 * marginX_;
    const int contentH = GetDeviceCaps(ref, VERTRES) - 2 * marginY_;

    // DEFAULT_CHARSET turns on font linking: GDI picks a fallback font for
    // each glyph Consolas lacks (CJK, Arabic…). Printers ignore the quality,
    // which smooths the preview.
    LOGFONTW lf = {};
    lf.lfHeight         = -MulDiv(10, dpiY, 72);
    lf.lfCharSet        = DEFAULT_CHARSET;
    lf.lfQuality        = CLEARTYPE_NATURAL_QUALITY;
    lf.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
    wcscpy_s(lf.lfFaceName, LF_FACESIZE, L"Consolas");
    font_ = CreateFontIndirectW(&lf);
    HGDIOBJ old = SelectObject(ref, font_);

    TEXTMETRICW tm = {};
    GetTextMetricsW(ref, &tm);
    lineH_        = tm.tmHeight + tm.tmExternalLeading;
    linesPerPage_ = (contentH > 0 && lineH_ > 0) ? contentH / lineH_ : 1;

    CharWidths widths(ref);
    const std::wstring_view all(text_);
    for (size_t pos = 0; pos < all.size();) {
      const size_t nl = all.find_first_of(L"\r\n", pos);
      const size_t end = std::min(nl, all.size());
      WrapLine(widths, all.substr(pos, end - pos), pos, contentW, lines_);
      if (nl == std::wstring_view::npos) break;
      pos = nl + (all.substr(nl, 2) == L"\r\n" ? 2 : 1);
    }
    dx_ = widths.Advances(all);
    SelectObject(ref, old);
  }

  ~TextDocument() override { DeleteObject(font_); }
  TextDocument(const TextDocument&) = delete;
  TextDocument& operator=(const TextDocument&) = delete;

  int PageCount() const override {
    const int total = static_cast<int>(lines_.size());
    return total == 0 ? 1 : (total + linesPerPage_ - 1) / linesPerPage_;
  }

  bool DrawPage(const PageTarget& t, int index) override {
    // Scale the printer-size font with the page, so lines break as in print.
    const bool mapped = t.scaleX != 1 || t.scaleY != 1 || t.originX != 0 ||
                        t.originY != 0;
    if (mapped) {
      const XFORM xf = {static_cast<FLOAT>(t.scaleX), 0, 0,
                        static_cast<FLOAT>(t.scaleY),
                        static_cast<FLOAT>(t.originX),
                        static_cast<FLOAT>(t.originY)};
      SetGraphicsMode(t.hdc, GM_ADVANCED);
      SetWorldTransform(t.hdc, &xf);
    }
    // Place each glyph at its printer advance: a font realized at a scaled
    // size rounds its own advances, which moves the text at each zoom.
    HGDIOBJ old = SelectObject(t.hdc, font_);
    const int total = static_cast<int>(lines_.size());
    const int first = index * linesPerPage_;
    const int end   = std::min(first + linesPerPage_, total);
    for (int li = first; li < end; ++li) {
      const TextSpan& ln = lines_[li];
      if (ln.length > 0)
        ExtTextOutW(t.hdc, marginX_, marginY_ + (li - first) * lineH_, 0,
                    nullptr, text_.data() + ln.start,
                    static_cast<UINT>(ln.length), dx_.data() + ln.start);
    }
    SelectObject(t.hdc, old);
    if (mapped) ModifyWorldTransform(t.hdc, nullptr, MWT_IDENTITY);
    return true;
  }

 private:
  // The text with tabs expanded, the printer advance of each unit, and its
  // wrapped lines.
  std::wstring text_;
  std::vector<INT> dx_;
  std::vector<TextSpan> lines_;
  HFONT font_ = nullptr;
  int marginX_ = 0, marginY_ = 0;
  int lineH_ = 0, linesPerPage_ = 1;
};

// Opens |path| laid out for the printer of |ref|. On error, sets |error| and
// returns null.
static std::unique_ptr<Document> OpenDocument(
    HDC ref, const std::wstring& path, FileKind kind,
    std::optional<FlutterError>& error) {
  EnsureGdiplusInit();
  const std::string name = WideToUtf8(path.c_str());
  switch (kind) {
    case FileKind::kPdf:
      if (auto d = PdfDocument::Open(path)) return d;
      error = FlutterError("PDF_ERROR", "Cannot open PDF: " + name);
      return nullptr;
    case FileKind::kImage:
      if (auto d = ImageDocument::Open(path)) return d;
      error = FlutterError("IMAGE_ERROR", "Cannot decode image: " + name);
      return nullptr;
    case FileKind::kMetafile:
      if (auto d = MetafileDocument::Open(path)) return d;
      error = FlutterError("IMAGE_ERROR", "Cannot open metafile: " + name);
      return nullptr;
    case FileKind::kText: {
      auto bytes = ReadBytes(path);
      if (!bytes) {
        error = FlutterError("FILE_ERROR", "Cannot read file: " + name);
        return nullptr;
      }
      // Free the bytes before the layout.
      std::wstring text = DecodeTextBytes(*bytes);
      bytes.reset();
      return std::make_unique<TextDocument>(ref, std::move(text));
    }
    case FileKind::kOther:
      break;
  }
  error = FlutterError("UNSUPPORTED_FILE", "File type not supported for printing");
  return nullptr;
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

std::optional<FlutterError> RenderToDC(HDC hdc, const std::wstring& wPath,
                                       FileKind kind, int copies, bool duplex,
                                       const PageRanges& ranges) {
  std::optional<FlutterError> error;
  auto doc = OpenDocument(hdc, wPath, kind, error);
  if (!doc) return error;

  // Check first, so an empty selection never sends a blank job.
  const int pageCount = doc->PageCount();
  if (auto err = CheckAnyPageSelected(pageCount, ranges)) return err;

  DOCINFOW di = {};
  di.cbSize      = sizeof(di);
  di.lpszDocName = wPath.c_str();
  if (StartDocW(hdc, &di) <= 0)
    return FlutterError("PRINT_ERROR", "StartDoc failed");

  // Cancel the job when a page fails, rather than print it blank.
  const PageTarget target = PrinterTarget(hdc);
  // Draws page |i|, or a blank page when -1.
  const auto printPage = [&](int i) -> std::optional<FlutterError> {
    if (StartPage(hdc) <= 0) {
      AbortDoc(hdc);
      return FlutterError("PRINT_ERROR", "StartPage failed");
    }
    if (i >= 0 && !doc->DrawPage(target, i)) {
      AbortDoc(hdc);
      return FlutterError("PRINT_ERROR",
                          "Cannot draw page " + std::to_string(i + 1));
    }
    // Fails when the job is cancelled or the spooler fails.
    if (EndPage(hdc) <= 0) {
      AbortDoc(hdc);
      return FlutterError("PRINT_ERROR", "EndPage failed");
    }
    return std::nullopt;
  };
  for (int c = 0; c < copies; ++c) {
    int printed = 0;
    for (int i = 0; i < pageCount; ++i) {
      if (!PageSelected(i + 1, ranges)) continue;
      if (auto err = printPage(i)) return err;
      ++printed;
    }
    // On both sides, add a blank back so the next copy starts on a new sheet.
    if (duplex && printed % 2 == 1 && c + 1 < copies) {
      if (auto err = printPage(-1)) return err;
    }
  }
  if (EndDoc(hdc) <= 0) return FlutterError("PRINT_ERROR", "EndDoc failed");
  return std::nullopt;
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
// Preview
// ---------------------------------------------------------------------------

std::unique_ptr<Preview> Preview::Open(HDC ic, const std::wstring& path,
                                       FileKind kind) {
  std::optional<FlutterError> error;
  auto doc = OpenDocument(ic, path, kind, error);
  if (!doc) {
    DeleteDC(ic);
    return nullptr;
  }
  return std::unique_ptr<Preview>(new Preview(ic, std::move(doc)));
}

Preview::Preview(HDC ic, std::unique_ptr<Document> doc)
    : ic_(ic), doc_(std::move(doc)) {}

Preview::~Preview() {
  doc_.reset();
  DeleteDC(ic_);
}

int Preview::PageCount() const { return doc_->PageCount(); }

std::vector<uint8_t> Preview::RenderPage(int index, int maxWidth,
                                         int maxHeight, const RECT* region) {
  if (index < 0 || index >= doc_->PageCount() || maxWidth <= 0 ||
      maxHeight <= 0)
    return {};
  PageTarget t = PrinterTarget(ic_);
  if (t.dpiX <= 0 || t.dpiY <= 0 || t.physW <= 0 || t.physH <= 0) return {};

  // Fit the sheet in the box, at the same scale on both axes.
  const double dpi =
      std::min(static_cast<double>(maxWidth) * t.dpiX / t.physW,
               static_cast<double>(maxHeight) * t.dpiY / t.physH);
  t.scaleX  = dpi / t.dpiX;
  t.scaleY  = dpi / t.dpiY;
  t.originX = static_cast<int>(std::lround(t.offX * t.scaleX));
  t.originY = static_cast<int>(std::lround(t.offY * t.scaleY));
  const int sheetW = std::max(1, static_cast<int>(std::lround(t.physW * t.scaleX)));
  const int sheetH = std::max(1, static_cast<int>(std::lround(t.physH * t.scaleY)));

  // The part to render: the region, within the sheet, or all of it.
  RECT part = {0, 0, sheetW, sheetH};
  if (region && !IntersectRect(&part, region, &part)) return {};
  const int w = part.right - part.left;
  const int h = part.bottom - part.top;
  // Bound the memory: the caller asks for regions when zoomed in.
  constexpr int kMaxSide = 8192;
  if (w <= 0 || h <= 0 || w > kMaxSide || h > kMaxSide) return {};
  t.originX -= part.left;
  t.originY -= part.top;

  // A white sheet, top-down, 4 bytes per pixel.
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize        = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth       = w;
  bi.bmiHeader.biHeight      = -h;
  bi.bmiHeader.biPlanes      = 1;
  bi.bmiHeader.biBitCount    = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(nullptr, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib) return {};
  HDC mem = CreateCompatibleDC(nullptr);
  HGDIOBJ oldBmp = SelectObject(mem, dib);
  PatBlt(mem, 0, 0, w, h, WHITENESS);
  // GDI can batch the fill: flush it before PDFium writes the bits.
  GdiFlush();

  // Drop what falls outside the printable area, as the printer does.
  const Gdiplus::Rect area = t.Map(0, 0, t.resW, t.resH);
  IntersectClipRect(mem, area.X, area.Y, area.GetRight(), area.GetBottom());
  t.hdc = mem;
  t.bits = bits;
  t.bitsW = w;
  t.bitsH = h;
  const bool drawn = doc_->DrawPage(t, index);
  GdiFlush();

  std::vector<uint8_t> png;
  if (drawn) {
    // GDI leaves the alpha bytes at 0: read them as RGB.
    Gdiplus::Bitmap sheet(w, h, w * 4, PixelFormat32bppRGB,
                          static_cast<BYTE*>(bits));
    png = EncodePng(sheet);
  }
  SelectObject(mem, oldBmp);
  DeleteDC(mem);
  DeleteObject(dib);
  return png;
}

}  // namespace flutter_print
