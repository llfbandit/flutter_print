# flutter_print

A Flutter plugin focusing on print, that's it.

Print PDF, image and other files, or any widget, with print options, on
Android, iOS, macOS, Windows, Linux and Web.

<p align="center">
<img src="https://raw.githubusercontent.com/llfbandit/flutter_print/main/img/win_preview.png" alt="Print preview on Windows" width="538">
<img src="https://raw.githubusercontent.com/llfbandit/flutter_print/main/img/android_preview.png" alt="Print preview on Android" width="162">
</p>

## Usage

```dart
import 'package:flutter_print/flutter_print.dart';

final printers = await FlutterPrint.listPrinters();

// Print directly, or review the settings in the print dialog first.
await FlutterPrint.print('/path/to/document.pdf');
await FlutterPrint.printPreview('/path/to/document.pdf', context: context);

await FlutterPrint.print(
  '/path/to/document.pdf',
  options: PrintOptions(
    printerAddress: printers.first.address, // Default printer when omitted.
    pageSize: PaperSizes.a4, // Or PageSize(name: '', width: w, height: h).
    margins: PageMargins(top: 10, bottom: 10, left: 15, right: 15), // mm
    copies: 2,
    landscape: false,
    color: true,
    duplexMode: DuplexMode.longEdge,
    pageRanges: [PageRange(start: 1, end: 3), PageRange(start: 5, end: 5)],
  ),
);
```

On the web, the file path is a URL from the page's origin or a Blob URL, and
the browser's print dialog is always shown.

### Widgets

Widgets are rendered off-screen as an image in a single-page PDF.

```dart
// Print, or use printWidgetPreview to open the print dialog.
await FlutterPrint.printWidget(
  (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  context: context,
  options: PrintOptions(pageSize: PaperSizes.a4),
);

// Get PNG bytes to show before printing.
final png = await FlutterPrint.previewWidget(...);
```

## Platform support

|                  | Android | iOS | macOS | Windows | Linux | Web |
|------------------|---------|-----|-------|---------|-------|-----|
| `print`          |         | ✔️¹ | ✔️    | ✔️      | ✔️    |     |
| `printPreview`   | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    | ✔️  |
| `listPrinters`   |         |     | ✔️    | ✔️      | ✔️    |     |
| `printerAddress` |         | ✔️¹ | ✔️    | ✔️      | ✔️    |     |
| `pageSize`       | ✔️      |     | ✔️    | ✔️²     | ✔️    |     |
| `margins`        | ✔️      |     | ✔️    |         |       |     |
| `copies`         |         |     | ✔️    | ✔️²     | ✔️    |     |
| `landscape`      | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️    |     |
| `color`          | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️    |     |
| `duplexMode`     | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️    |     |
| `pageRanges`     |         |     | ✔️    | ✔️²     | ✔️    |     |

Where `print` is unsupported, it opens the print dialog. Unsupported options
are ignored.

¹ With an address from `FlutterPrint.ios?.pickPrinter()`. `printPreview`
ignores it.  
² Supported file types only, see [File types](#file-types). Files printed by
their default app ignore it.

### File types

| Platform | PDF & images | Text documents | Other files |
|----------|--------------|----------------|-------------|
| Android  | ✔️           |                |             |
| iOS      | ✔️           |                |             |
| macOS    | ✔️           | ✔️¹            | `printPreview` opens the default app |
| Windows  | ✔️           | ✔️²            | Printed by the default app, with its own settings |
| Linux    | ✔️           | ✔️             | ✔️ (CUPS) |
| Web      | ✔️           | ✔️             | ✔️ (browser) |

Unsupported files fail with `UNSUPPORTED_FILE`.

¹ Plain text, RTF, HTML, Word and OpenDocument (macOS 11+).  
² Any text file, detected by its content, printed as plain text. EMF and WMF
print as vectors.

### Images

JPEG, PNG, BMP and GIF print everywhere. TIFF prints everywhere but Android.

| Format | Android | iOS | macOS | Windows | Linux |
|--------|---------|-----|-------|---------|-------|
| WebP   | ✔️      | 14+ | 11+   | ✔️¹     | ✔️²   |
| HEIC   | 9+      | ✔️  | ✔️    | ✔️¹     | ✔️²   |

¹ With the codec from the Microsoft Store (HEIC is built into Windows 11). Any
other format with a WIC codec prints too (AVIF, JPEG XL, RAW…).  
² With `webp-pixbuf-loader` for WebP, `libheif` and `heif-pixbuf-loader` for
HEIC.

## Setup

### macOS

Add the print entitlement to `macos/Runner/Release.entitlements` and
`macos/Runner/DebugProfile.entitlements`. No other entitlement is needed.

```xml
<key>com.apple.security.print</key>
<true/>
```

### Windows

x64 only. The first build downloads
[PDFium](https://github.com/bblanchon/pdfium-binaries) and bundles
`pdfium.dll`. Ship its licence notices (`LICENSE` and `licenses/` in
`build/windows/x64/_deps/pdfium-src/`) with your app.

### Linux

Install the CUPS development libraries to build, and run the CUPS service to
print:

```sh
sudo apt install libcups2-dev   # Debian / Ubuntu
sudo dnf install cups-devel     # Fedora / RHEL
sudo pacman -S cups             # Arch
```

In a Flatpak or Snap sandbox, `printPreview` uses the desktop print dialog
(`xdg-desktop-portal`), where page ranges and orientation may be ignored. Set
`GTK_USE_PORTAL=1` to use it outside a sandbox. `print` and `listPrinters` still
need CUPS: `--socket=cups` for Flatpak, the `cups` plug for Snap.
