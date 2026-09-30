#include "printer_setup.h"

#include <algorithm>
#include <cmath>
#include <optional>


namespace flutter_print {

// Returns the DMPAPER_* ID for a known paper name, or 0.
static int NameToDMPaper(const std::string& name) {
  for (const auto& [id, known] : kKnownPapers) {
    if (name == known) return id;
  }
  return 0;
}

// Returns the most copies the driver can make, or 1 when unknown. Drivers
// that report 1 (e.g. Microsoft Print to PDF) ignore a higher dmCopies.
static int GetDriverMaxCopies(const std::wstring& printerName) {
  const DWORD r = DeviceCapabilitiesW(printerName.c_str(), nullptr, DC_COPIES,
                                      nullptr, nullptr);
  if (r == static_cast<DWORD>(-1) || r == 0) return 1;
  return static_cast<int>(r);
}

// Writes the set fields of |options| into |dm|. Unset fields keep the printer
// default. |deviceCopies| replaces options.copies() (see BuildDevMode).
static void ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options,
                                  int deviceCopies) {
  if (options.copies()) {
    dm->dmCopies  = static_cast<short>(std::max(1, deviceCopies));
    dm->dmFields |= DM_COPIES;
  }

  if (const bool* landscape = options.landscape()) {
    dm->dmOrientation = *landscape ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
    dm->dmFields     |= DM_ORIENTATION;
  }

  if (const bool* color = options.color()) {
    dm->dmColor   = *color ? DMCOLOR_COLOR : DMCOLOR_MONOCHROME;
    dm->dmFields |= DM_COLOR;
  }

  if (const DuplexMode* dup = options.duplex_mode()) {
    switch (*dup) {
      case DuplexMode::kNone:      dm->dmDuplex = DMDUP_SIMPLEX;    break;
      case DuplexMode::kLongEdge:  dm->dmDuplex = DMDUP_VERTICAL;   break;
      case DuplexMode::kShortEdge: dm->dmDuplex = DMDUP_HORIZONTAL; break;
    }
    dm->dmFields |= DM_DUPLEX;
  }

  const PageSize* ps = options.page_size();
  if (!ps) return;
  dm->dmFields &= ~(DM_PAPERSIZE | DM_PAPERWIDTH | DM_PAPERLENGTH);

  if (const int paper = NameToDMPaper(ps->name()); paper > 0) {
    dm->dmPaperSize = static_cast<short>(paper);
    dm->dmFields   |= DM_PAPERSIZE;
    return;
  }

  const double* w = ps->width();
  const double* h = ps->height();
  if (!w || !h || *w <= 0 || *h <= 0) return;
  // Custom size in tenths of mm: dmPaperWidth is always the short edge.
  dm->dmPaperSize   = DMPAPER_USER;
  dm->dmPaperWidth  = static_cast<short>(std::round(std::min(*w, *h) * 10.0));
  dm->dmPaperLength = static_cast<short>(std::round(std::max(*w, *h) * 10.0));
  dm->dmFields     |= DM_PAPERSIZE | DM_PAPERWIDTH | DM_PAPERLENGTH;
  // Set the orientation so the DC width matches the requested width.
  dm->dmOrientation = (*w > *h) ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
}

static std::vector<BYTE> ReadDevMode(HANDLE hPrinter,
                                     const std::wstring& printerName) {
  const LONG sz = DocumentPropertiesW(
      nullptr, hPrinter, const_cast<LPWSTR>(printerName.c_str()),
      nullptr, nullptr, 0);
  if (sz <= 0) return {};
  std::vector<BYTE> buf(static_cast<size_t>(sz));
  if (DocumentPropertiesW(nullptr, hPrinter,
                          const_cast<LPWSTR>(printerName.c_str()),
                          reinterpret_cast<DEVMODE*>(buf.data()), nullptr,
                          DM_OUT_BUFFER) != IDOK) {
    return {};
  }
  return buf;
}

// Returns the printer's DEVMODE with |options| applied, or empty on error.
static std::vector<BYTE> BuildDevMode(const std::wstring& printerName,
                                      const PrintOptions* options,
                                      int* out_software_copies) {
  // When the driver can't make all the copies, ask it for one and draw the
  // copies in software.
  const int64_t* copiesOpt = options ? options->copies() : nullptr;
  const int requestedCopies =
      copiesOpt ? static_cast<int>(std::max<int64_t>(1, *copiesOpt)) : 1;
  const bool driverCopies =
      requestedCopies == 1 || GetDriverMaxCopies(printerName) >= requestedCopies;
  if (out_software_copies)
    *out_software_copies = driverCopies ? 1 : requestedCopies;

  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr))
    return {};

  std::vector<BYTE> buf = ReadDevMode(hPrinter, printerName);
  if (!buf.empty() && options) {
    auto* dm = reinterpret_cast<DEVMODE*>(buf.data());
    ApplyOptionsToDEVMODE(dm, *options, driverCopies ? requestedCopies : 1);
    // Let the driver validate the changes: many drivers ignore a DEVMODE that
    // skipped this step. On failure, keep our DEVMODE: CreateDCW checks it too.
    DocumentPropertiesW(nullptr, hPrinter,
                        const_cast<LPWSTR>(printerName.c_str()),
                        dm, dm, DM_IN_BUFFER | DM_OUT_BUFFER);
  }
  ClosePrinter(hPrinter);
  return buf;
}

std::vector<BYTE> GetDefaultDevMode(const std::wstring& printerName) {
  return BuildDevMode(printerName, nullptr, nullptr);
}

HDC CreatePrinterDC(const std::wstring& printerName,
                    const PrintOptions* options,
                    int* out_software_copies) {
  std::vector<BYTE> dm = BuildDevMode(printerName, options, out_software_copies);
  return CreateDCW(L"WINSPOOL", printerName.c_str(), nullptr,
                   dm.empty() ? nullptr : reinterpret_cast<DEVMODE*>(dm.data()));
}

std::optional<PrinterMargins> GetMinimumMargins(const std::wstring& printerName,
                                                const std::string& paperSizeName,
                                                double paperWidthMm,
                                                double paperHeightMm) {
  // Build the DEVMODE like the print path does. An information context is
  // enough for GetDeviceCaps and cheaper than a DC.
  PrintOptions options;
  options.set_page_size(PageSize(paperSizeName, &paperWidthMm, &paperHeightMm));
  std::vector<BYTE> dm = BuildDevMode(printerName, &options, nullptr);
  HDC hdc = CreateICW(L"WINSPOOL", printerName.c_str(), nullptr,
                      dm.empty() ? nullptr : reinterpret_cast<DEVMODE*>(dm.data()));
  if (!hdc) return std::nullopt;

  // The printable area starts at PHYSICALOFFSET and has the HORZRES/VERTRES
  // size, in the PHYSICALWIDTH/HEIGHT sheet.
  const int offX  = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const int offY  = GetDeviceCaps(hdc, PHYSICALOFFSETY);
  const int physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  const int physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  const int resW  = GetDeviceCaps(hdc, HORZRES);
  const int resH  = GetDeviceCaps(hdc, VERTRES);
  const int dpiX  = GetDeviceCaps(hdc, LOGPIXELSX);
  const int dpiY  = GetDeviceCaps(hdc, LOGPIXELSY);
  DeleteDC(hdc);

  if (dpiX <= 0 || dpiY <= 0) return std::nullopt;

  constexpr double kMmPerInch = 25.4;
  const double mmX = kMmPerInch / dpiX;
  const double mmY = kMmPerInch / dpiY;
  PrinterMargins m;
  m.left   = offX * mmX;
  m.top    = offY * mmY;
  m.right  = (physW - resW - offX) * mmX;
  m.bottom = (physH - resH - offY) * mmY;
  return m;
}

}  // namespace flutter_print
