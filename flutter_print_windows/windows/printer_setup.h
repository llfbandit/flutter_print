#pragma once

#define NOMINMAX
#include <windows.h>
#include <winspool.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "messages.h"

namespace flutter_print {

// ---------------------------------------------------------------------------
// Paper names
// ---------------------------------------------------------------------------

// Paper-size IDs mapped to the well-known names the Dart layer uses.
inline constexpr std::pair<WORD, const char*> kKnownPapers[] = {
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

// ---------------------------------------------------------------------------
// DEVMODE
// ---------------------------------------------------------------------------

// Returns the printer's default DEVMODE (driver-sized), or empty on error.
std::vector<BYTE> GetDefaultDevMode(const std::wstring& printerName);

// ---------------------------------------------------------------------------
// Printer DC
// ---------------------------------------------------------------------------

// Creates a printer DC for |printerName| with |options| applied. When |options|
// is null the printer's default settings are used unchanged.
// Caller must DeleteDC the returned handle. When |out_software_copies| is
// non-null it receives the number of copies that must be produced in software
// because the driver cannot replicate them natively (1 when the driver handles
// all requested copies); see RenderToDC's |copies| parameter.
HDC CreatePrinterDC(const std::wstring& printerName, const PrintOptions* options,
                    int* out_software_copies = nullptr);

// ---------------------------------------------------------------------------
// Hardware margins
// ---------------------------------------------------------------------------

struct PrinterMargins {
  double left;
  double top;
  double right;
  double bottom;
};

// Returns the hardware (unprintable-area) margins in mm for |printerName|
// with the given paper size. |paperSizeName| is a well-known name (e.g.
// "A4"); if empty, |paperWidthMm| and |paperHeightMm| are used for a custom
// size. Returns nullopt when the printer DC cannot be created.
std::optional<PrinterMargins> GetMinimumMargins(const std::wstring& printerName,
                                                const std::string& paperSizeName,
                                                double paperWidthMm,
                                                double paperHeightMm);

}  // namespace flutter_print
