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
