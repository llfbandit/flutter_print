#pragma once

#define NOMINMAX
#include <windows.h>
#include <winspool.h>

#include <string>

#include "messages.h"

namespace flutter_print {

// ---------------------------------------------------------------------------
// Paper names
// ---------------------------------------------------------------------------

// Maps a well-known paper-size name (e.g. "A4", "Letter") to its DMPAPER_*
// constant. Returns 0 for unrecognised names.
int NameToDMPaper(const std::string& name);

// ---------------------------------------------------------------------------
// DEVMODE
// ---------------------------------------------------------------------------

// Writes |options| into an existing DEVMODE in-place.
void ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options);

// Returns a GlobalAlloc'd DEVMODE initialised from the printer's native
// settings with |options| overlaid. Caller must GlobalFree the handle.
HGLOBAL BuildDevMode(const std::wstring& printerName, const PrintOptions& options);

// ---------------------------------------------------------------------------
// Printer DC
// ---------------------------------------------------------------------------

// Creates a printer DC for |printerName| with |options| applied.
// Caller must DeleteDC the returned handle.
HDC CreatePrinterDC(const std::wstring& printerName, const PrintOptions& options);

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
