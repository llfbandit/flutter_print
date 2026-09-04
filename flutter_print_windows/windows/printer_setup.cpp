#include "printer_setup.h"

#include <algorithm>
#include <optional>

#pragma comment(lib, "winspool.lib")

namespace flutter_print {

// ---------------------------------------------------------------------------
// Paper names
// ---------------------------------------------------------------------------

// Maps a well-known paper-size name (e.g. "A4") to its DMPAPER_* constant, or
// 0 for unrecognised names.
static int NameToDMPaper(const std::string& name) {
  for (const auto& [id, known] : kKnownPapers) {
    if (name == known) return id;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Copies
// ---------------------------------------------------------------------------

// Returns the maximum copies the driver/spooler can produce natively, or 1 when
// unknown. Drivers that report 1 (e.g. "Microsoft Print to PDF") silently clamp
// dmCopies to 1, so extra copies must be emitted in software.
static int GetDriverMaxCopies(const std::wstring& printerName) {
  // A null port is accepted on NT-based Windows and resolves to the printer's
  // default port. DC_COPIES returns the maximum copies the driver/spooler can
  // produce, or (DWORD)-1 when the capability is not implemented.
  const DWORD r = DeviceCapabilitiesW(printerName.c_str(), nullptr, DC_COPIES,
                                      nullptr, nullptr);
  if (r == static_cast<DWORD>(-1) || r == 0) return 1;
  return static_cast<int>(r);
}

// ---------------------------------------------------------------------------
// DEVMODE
// ---------------------------------------------------------------------------

// Writes |options| into |dm| in place. |deviceCopies| is the dmCopies value,
// which may be less than options.copies() when the rest are emitted in software.
static void ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options,
                                  int deviceCopies) {
  // Each field is applied only when provided; unset (null) fields keep the
  // printer's default DEVMODE value.
  if (options.copies()) {
    dm->dmCopies  = static_cast<short>(std::max(1, deviceCopies));
    dm->dmFields |= DM_COPIES;
  }

  const bool* landscape = options.landscape();
  if (landscape) {
    dm->dmOrientation = *landscape ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
    dm->dmFields     |= DM_ORIENTATION;
  }

  const bool* color = options.color();
  if (color) {
    dm->dmColor   = *color ? DMCOLOR_COLOR : DMCOLOR_MONOCHROME;
    dm->dmFields |= DM_COLOR;
  }

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

std::vector<BYTE> GetDefaultDevMode(const std::wstring& printerName) {
  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr))
    return {};
  std::vector<BYTE> buf = ReadDevMode(hPrinter, printerName);
  ClosePrinter(hPrinter);
  return buf;
}

// Returns the printer's DEVMODE with |options| overlaid, or empty on error.
// When |options| is null the printer's default DEVMODE is returned unchanged.
static std::vector<BYTE> BuildDevMode(const std::wstring& printerName,
                                      const PrintOptions* options,
                                      int* out_software_copies) {
  // Split the requested copies between the driver (dmCopies) and software
  // emission. Drivers that cannot replicate copies natively report
  // DC_COPIES == 1 and silently drop dmCopies > 1, so in that case we ask the
  // driver for a single copy and let the renderer emit the rest.
  // When copies is unset, leave it to the printer default (1).
  const int64_t* copiesOpt = options ? options->copies() : nullptr;
  const int requestedCopies = copiesOpt
      ? static_cast<int>(std::max<int64_t>(1, *copiesOpt))
      : 1;
  const int maxDriverCopies = GetDriverMaxCopies(printerName);
  const bool driverHandlesAll = maxDriverCopies >= requestedCopies;
  const int deviceCopies   = driverHandlesAll ? requestedCopies : 1;
  if (out_software_copies)
    *out_software_copies = driverHandlesAll ? 1 : requestedCopies;

  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr))
    return {};

  std::vector<BYTE> buf = ReadDevMode(hPrinter, printerName);
  // With no options, keep the printer's default DEVMODE (system defaults).
  if (!buf.empty() && options) {
    auto* dm = reinterpret_cast<DEVMODE*>(buf.data());
    ApplyOptionsToDEVMODE(dm, *options, deviceCopies);
    // Let the driver validate and normalise our changes; without this round-trip
    // many drivers silently ignore the modified DEVMODE and produce a blank job.
    // On failure, proceed with the modified-but-unvalidated DEVMODE — CreateDCW
    // will re-validate, and it is still better than falling back to defaults.
    DocumentPropertiesW(nullptr, hPrinter,
                         const_cast<LPWSTR>(printerName.c_str()),
                         dm, dm, DM_IN_BUFFER | DM_OUT_BUFFER);
  }
  ClosePrinter(hPrinter);
  return buf;
}

// ---------------------------------------------------------------------------
// Printer DC
// ---------------------------------------------------------------------------

HDC CreatePrinterDC(const std::wstring& printerName,
                    const PrintOptions* options,
                    int* out_software_copies) {
  std::vector<BYTE> dm = BuildDevMode(printerName, options, out_software_copies);
  return CreateDCW(L"WINSPOOL", printerName.c_str(), nullptr,
                   dm.empty() ? nullptr : reinterpret_cast<DEVMODE*>(dm.data()));
}

// ---------------------------------------------------------------------------
// Hardware margins
// ---------------------------------------------------------------------------

std::optional<PrinterMargins> GetMinimumMargins(const std::wstring& printerName,
                                                const std::string& paperSizeName,
                                                double paperWidthMm,
                                                double paperHeightMm) {
  // Same paper-size rules and driver validation as the print path.
  PrintOptions options;
  options.set_page_size(PageSize(paperSizeName, &paperWidthMm, &paperHeightMm));
  HDC hdc = CreatePrinterDC(printerName, &options);
  if (!hdc) return std::nullopt;

  // PHYSICALOFFSET* gives the top-left unprintable corner in device units.
  // PHYSICALWIDTH/HEIGHT is the full sheet; HORZRES/VERTRES is the printable
  // area. Right/bottom margin = sheet - printable - top-left offset.
  const int offX  = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const int offY  = GetDeviceCaps(hdc, PHYSICALOFFSETY);
  const int physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  const int physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  const int rezW  = GetDeviceCaps(hdc, HORZRES);
  const int rezH  = GetDeviceCaps(hdc, VERTRES);
  const int dpiX  = GetDeviceCaps(hdc, LOGPIXELSX);
  const int dpiY  = GetDeviceCaps(hdc, LOGPIXELSY);
  DeleteDC(hdc);

  if (dpiX <= 0 || dpiY <= 0) return std::nullopt;

  const double kInchToMm = 25.4;
  PrinterMargins m;
  m.left   = (offX / static_cast<double>(dpiX)) * kInchToMm;
  m.top    = (offY / static_cast<double>(dpiY)) * kInchToMm;
  m.right  = ((physW - rezW - offX) / static_cast<double>(dpiX)) * kInchToMm;
  m.bottom = ((physH - rezH - offY) / static_cast<double>(dpiY)) * kInchToMm;
  return m;
}

}  // namespace flutter_print
