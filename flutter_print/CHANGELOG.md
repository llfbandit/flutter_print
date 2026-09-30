## 0.5.0
* feat: Add page range print option (Windows, macOS, Linux).
* feat: Sort and merge page ranges. Throw ArgumentError on invalid ranges.
* fix(macos): Apply all print options in the print panel and follow paper changes made there.
* feat(macos): Print text, RTF, HTML and Word documents natively, with all options. Drop the `lp` fallback (App Sandbox); `print` fails with `UNSUPPORTED_FILE` for other file types.
* fix(macos): Don't crash on a negative or out-of-range `copies`.
* fix(macos): Print rotated and cropped PDF pages as displayed.
* fix(macos): Fail with `PRINTER_ERROR` for an unknown `printerAddress` instead of using the default printer.
* fix(ios): Complete `pickPrinter` when the picker can't be shown, and fail with `NO_WINDOW` instead of returning `null` without a view.
* fix(ios): Reject a print job while another one runs, instead of changing the open dialog.
* fix(ios): Present from the Flutter view, and anchor the iPad popover to its centre.
* fix(ios): Fail with `PRINTER_ERROR` for an invalid or unreachable `printerAddress`.
* feat(ios): Use photo output for images.
* feat(ios): Report availability, colour and duplex support of the printer from `pickPrinter`.

## 0.4.0
* feat: Make print options nullable to get system defaults.
* feat(android): Implement image print.
* fix(android): Report PDF page count for page-range selection.
* fix(Android): Copy off the main thread.
* fix(android): Don't report print job result too early.
* fix(ios): silent errors.
* fix(macos): Landspace applied twice.
* feat(macos): report printer capabilities in listPrinters.
* fix(macos): page size/margins.
* fix(macos): Open default apps for sanboxed apps.

## 0.3.1
* fix(macos): Broken in 0.3.0. Syncs with new API.
* fix(ios): Broken in 0.3.0. Syncs with new API.
* fix(linux): Broken in 0.3.0. Syncs with new API.

## 0.3.0
* chore: Partial federated structure. Split windows and web platforms.
* feat(Windows): Add custom preview dialog with fluent_ui (there's no way for preview print on windows).
* feat(Windows): Windows can preview any text/* files (UTF 16 included).
* chore(Windows): Multiple code improvements/additions.

## 0.2.4
* fix: WASM compilation.
* fix: Temp file deleted too early (race condition with preview/print dialog).
* fix: Ensure OverlayEntry removal in case of rebuild for `printWidget` and `previewWidget`.

## 0.2.3
* fix: WASM compilation for pub.dev score.

## 0.2.2
* fix: `printWidget` with transparent background.

## 0.2.1
* fix: pages size presets.

## 0.2.0
* feat: Add `printWidget` and `previewWidget` for widget printing.
* fix(linux): Add page size presets.
* fix(windows): Custom page print.

## 0.1.0

* feat: Initial release with support for Android, iOS, macOS, Windows, Linux and Web
* feat: Print files via native platform dialog or directly to a printer (silent print)
* feat: List available printers
* feat: iOS AirPrint printer picker via `FlutterPrint.ios?.pickPrinter()`
* feat: support PDF and image files with native rendering
* feat: Support other documents via platform default handlers
* feat: `PrintOptions` for configuring printer address, page size, margins, copies, landscape, color, and duplex mode
* feat: Named paper size presets via `PaperSizes` (A0–A6, B4–B5, ...)
* feat: Per-platform margin control in millimeters via `PageMargins`
* feat: Duplex mode support (none, longEdge, shortEdge)
