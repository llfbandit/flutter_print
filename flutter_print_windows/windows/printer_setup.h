#pragma once

#include <windows.h>
#include <winspool.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "messages.h"

namespace flutter_print {

// DMPAPER_* IDs and the paper names the Dart layer uses.
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

// Returns the printer's default DEVMODE, or empty on error.
std::vector<BYTE> GetDefaultDevMode(const std::wstring& printerName);

// Returns the kKnownPapers name of the printer's default paper, or empty when
// it is not one of them.
std::string DefaultPaperName(const std::wstring& printerName);

// Creates a printer DC with |options| applied, or with the printer defaults
// when |options| is null. The caller must DeleteDC it.
// |out_software_copies| gets the copies the driver can't make itself (1 when
// it makes them all). Pass it to RenderToDC.
HDC CreatePrinterDC(const std::wstring& printerName, const PrintOptions* options,
                    int* out_software_copies = nullptr);

// Margins in mm.
struct PrinterMargins {
  double left;
  double top;
  double right;
  double bottom;
};

// Returns the unprintable margins of |printerName| for a paper size.
// |paperSizeName| is a known name like "A4"; when it is empty or unknown, the
// width and height give a custom size. The width and height are oriented:
// width > height means landscape. Returns nullopt on error.
std::optional<PrinterMargins> GetMinimumMargins(const std::wstring& printerName,
                                                const std::string& paperSizeName,
                                                double paperWidthMm,
                                                double paperHeightMm);

}  // namespace flutter_print
