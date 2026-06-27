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
// Copies
// ---------------------------------------------------------------------------

// Returns the maximum number of copies the printer's driver/spooler can
// produce natively (the DC_COPIES capability), or 1 when the capability is
// unavailable. Drivers that report 1 (e.g. "Microsoft Print to PDF" and many
// virtual printers) silently clamp DEVMODE.dmCopies to 1, so any extra copies
// must be emitted in software (see RenderOrFallback's |copies| parameter).
int GetDriverMaxCopies(const std::wstring& printerName);

// ---------------------------------------------------------------------------
// DEVMODE
// ---------------------------------------------------------------------------

// Writes |options| into an existing DEVMODE in-place. |deviceCopies| is the
// value written to dmCopies (i.e. the copies the driver is asked to produce
// natively); it is decided by the caller from GetDriverMaxCopies, so it may be
// less than options.copies() when the remaining copies are emitted in software.
void ApplyOptionsToDEVMODE(DEVMODE* dm, const PrintOptions& options,
                           int deviceCopies);

// Returns a GlobalAlloc'd DEVMODE initialised from the printer's native
// settings with |options| overlaid. Caller must GlobalFree the handle.
// When |out_software_copies| is non-null it receives the number of copies that
// must be produced in software because the driver cannot replicate them
// natively (1 when the driver handles all requested copies).
HGLOBAL BuildDevMode(const std::wstring& printerName, const PrintOptions& options,
                     int* out_software_copies = nullptr);

// ---------------------------------------------------------------------------
// Printer DC
// ---------------------------------------------------------------------------

// Creates a printer DC for |printerName| with |options| applied.
// Caller must DeleteDC the returned handle. |out_software_copies| has the same
// meaning as in BuildDevMode.
HDC CreatePrinterDC(const std::wstring& printerName, const PrintOptions& options,
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
