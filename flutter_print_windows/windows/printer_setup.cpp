#include "printer_setup.h"

#include <algorithm>

#pragma comment(lib, "winspool.lib")

namespace flutter_print {

// ---------------------------------------------------------------------------
// Paper names
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

// ---------------------------------------------------------------------------
// DEVMODE
// ---------------------------------------------------------------------------

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
  if (!dm) { GlobalFree(h); ClosePrinter(hPrinter); return nullptr; }

  if (DocumentPropertiesW(nullptr, hPrinter,
                           const_cast<LPWSTR>(printerName.c_str()),
                           dm, nullptr, DM_OUT_BUFFER) != IDOK) {
    GlobalUnlock(h);
    GlobalFree(h);
    ClosePrinter(hPrinter);
    return nullptr;
  }

  ApplyOptionsToDEVMODE(dm, options);
  // Let the driver validate and normalise our changes; without this round-trip
  // many drivers silently ignore the modified DEVMODE and produce a blank job.
  // On failure, proceed with the modified-but-unvalidated DEVMODE — CreateDCW
  // will re-validate, and it is still better than falling back to defaults.
  DocumentPropertiesW(nullptr, hPrinter,
                       const_cast<LPWSTR>(printerName.c_str()),
                       dm, dm, DM_IN_BUFFER | DM_OUT_BUFFER);
  GlobalUnlock(h);
  ClosePrinter(hPrinter);
  return h;
}

// ---------------------------------------------------------------------------
// Printer DC
// ---------------------------------------------------------------------------

HDC CreatePrinterDC(const std::wstring& printerName,
                    const PrintOptions& options) {
  HGLOBAL h  = BuildDevMode(printerName, options);
  auto*   dm = h ? static_cast<DEVMODE*>(GlobalLock(h)) : nullptr;
  HDC     hdc = CreateDCW(L"WINSPOOL", printerName.c_str(), nullptr, dm);
  if (dm) GlobalUnlock(h);
  if (h)  GlobalFree(h);
  return hdc;
}

}  // namespace flutter_print
