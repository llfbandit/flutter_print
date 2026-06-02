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
