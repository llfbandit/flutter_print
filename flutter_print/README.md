# flutter_print

A Flutter plugin focusing on print, that's it.

**PDF and image files** print on every platform, with the print options
applied. Text documents are rendered natively on macOS and Windows. Other file
types are handled differently on each platform, see [File types](#file-types).

**Widgets** are rendered as an image in a single-page PDF.

<p align="center">
<img src="https://raw.githubusercontent.com/llfbandit/flutter_print/main/img/win_preview.png" alt="Print preview on Windows" width="538">
<img src="https://raw.githubusercontent.com/llfbandit/flutter_print/main/img/android_preview.png" alt="Print preview on Android" width="162">
</p>

---

## Usage

### Basic print

```dart
import 'package:flutter_print/flutter_print.dart';

// List available printers
final List<PrinterInfo> printers = await FlutterPrint.listPrinters();

// Print with default settings
await FlutterPrint.print('/path/to/document.pdf');

// Let the user review settings in the system print dialog first
await FlutterPrint.printPreview('/path/to/document.pdf', context: context);

// On the web `filePath` must be a URL accessible from the page's origin, or a
// Blob URL. The browser's print dialog (which includes a preview) is always
// shown.
await FlutterPrint.print('https://example.com/document.pdf');
```

### Print with options

```dart
await FlutterPrint.print(
  '/path/to/document.pdf',
  options: PrintOptions(
    // Target a specific printer (uses system default when omitted).
    printerAddress: printers.first.address,

    // Use a named page size preset.
    // Or via PageSize(name: '', width: w, height: h)
    pageSize: PaperSizes.a4,

    // Margins in millimetres.
    margins: PageMargins(top: 10, bottom: 10, left: 15, right: 15),

    copies: 2,
    landscape: false,
    color: true,
    duplexMode: DuplexMode.longEdge,

    // Pages 1–3 and 5.
    pageRanges: [PageRange(start: 1, end: 3), PageRange(start: 5, end: 5)],
  ),
);
```

Page ranges are 1-based and inclusive. They are sorted and merged before
printing; an invalid range throws an `ArgumentError`, and a selection that
matches no page fails with `INVALID_PAGE_RANGE`.

### Widget print

Render any Flutter widget off-screen and print it directly — no file needed.
`printWidget` rasterises the widget into a single-page PDF and sends it to the
printer, and `printWidgetPreview` opens it in the print dialog instead.
`previewWidget` returns PNG bytes you can display with `Image.memory` before
printing.

```dart
// Print a widget
await FlutterPrint.printWidget(
  (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  context: context,
  options: PrintOptions(pageSize: PaperSizes.a4),
);

// Preview a widget in-app before printing
final png = await FlutterPrint.previewWidget(
  (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  context: context,
  options: PrintOptions(pageSize: PaperSizes.a4),
);
Image.memory(png);
```

---

## Feature support by platform

| Feature        | Android | iOS | macOS | Windows | Linux | Web |
|----------------|---------|-----|-------|---------|-------|-----|
| Direct print   |         | ✔️¹ | ✔️    | ✔️      | ✔️    |     |
| Print preview  | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️³   | ✔️  |
| List printers  |         |     | ✔️    | ✔️      | ✔️    |     |

¹ With a `printerAddress` from `FlutterPrint.ios?.pickPrinter()` (e.g.
`ipp://printer.local./ipp/print`). Without it, the system print dialog is shown.  
² A Flutter print dialog with a built-in preview.  
³ Opens the file in its default viewer with `xdg-open`.

## Option support by platform

Options a platform doesn't support are silently ignored.

| Option           | Android | iOS | macOS | Windows | Linux | Web |
|------------------|---------|-----|-------|---------|-------|-----|
| `printerAddress` |         | ✔️¹ | ✔️    | ✔️      | ✔️    |     |
| `pageSize`       | ✔️⁴     |     | ✔️    | ✔️²     | ✔️    |     |
| `margins`        | ✔️⁴     |     | ✔️    |         |       |     |
| `copies`         |         |     | ✔️    | ✔️²     | ✔️    |     |
| `landscape`      | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️    |     |
| `color`          | ✔️      | ✔️  | ✔️³   | ✔️²     | ✔️    |     |
| `duplexMode`     | ✔️⁴     | ✔️  | ✔️    | ✔️²     | ✔️    |     |
| `pageRanges`     |         |     | ✔️    | ✔️²     | ✔️    |     |

¹ `print` only, with an address from `FlutterPrint.ios?.pickPrinter()`. `printPreview` ignores it.  
² For PDF, image, EMF/WMF and text files only.  
³ The print panel shows the requested `color` when the printer driver has
colour presets (AirPrint and most drivers).  
⁴ For PDF files only.

On macOS, the options are applied to the print panel too, so the user starts
from the requested settings.

## File types

| Platform | PDF & images | Text documents | Other files |
|----------|--------------|----------------|-------------|
| Android  | Native       | Not supported  | Not supported |
| iOS      | Native       | `UNSUPPORTED_FILE` | `UNSUPPORTED_FILE` |
| macOS    | Native       | Native¹        | `print` fails with `UNSUPPORTED_FILE`; `printPreview` opens the default app |
| Windows  | Native²      | Native³        | Printed by the associated application, with its own settings⁴ |
| Linux    | CUPS         | CUPS           | CUPS |
| Web      | Browser      | Browser        | Browser |

¹ Plain text, RTF, HTML, Word and OpenDocument text (macOS 11+).  
² Also EMF and WMF, printed as vectors.  
³ Any text file, detected by its content (`.txt`, `.csv`, `.json`, `.md`,
`.log`, source code…), printed as plain text.  
⁴ Including HTML, SVG and RTF.

## Image support by platform

| Format | Android | iOS | macOS | Windows | Linux |
|--------|---------|-----|-------|---------|-------|
| JPEG   | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    |
| PNG    | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    |
| BMP    | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    |
| GIF    | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    |
| TIFF   | ✔️      | ✔️  | ✔️    | ✔️      | ✔️    |
| WebP   | ✔️      | ✔️¹ | ✔️¹   | ✔️²     | ✔️³   |
| HEIC   | ✔️      | ✔️  | ✔️    | ✔️²     | ✔️³   |

¹ Requires iOS 14 / macOS 11 or later.  
² Requires the WebP or HEIC codec from the Microsoft Store (built into
Windows 11 for HEIC).  
³ Requires the matching GDK-Pixbuf loader: `webp-pixbuf-loader` for WebP,
`libheif` + `heif-pixbuf-loader` for HEIC.

On Windows, any format with an installed WIC codec prints too (AVIF, JPEG XL,
camera RAW…). Each page of a TIFF prints as a page, and page ranges apply.
Photos print upright from their EXIF orientation.

---

## Setup

### macOS

Add the print entitlement to `macos/Runner/Release.entitlements` and
`macos/Runner/DebugProfile.entitlements`:

```xml
<key>com.apple.security.print</key>
<true/>
```

The plugin works in sandboxed apps and needs no other entitlement.

### Windows

- x64 only for now.
- The first build downloads [PDFium binaries](https://github.com/bblanchon/pdfium-binaries) and bundles
`pdfium.dll` with your app.
- Ship PDFium's licence notices with your app: `LICENSE` and `licenses/` in
`build/windows/x64/_deps/pdfium-src/`.

### Linux

The plugin requires the **CUPS** development libraries. Install them before
building the application:

```sh
# Debian / Ubuntu
sudo apt install libcups2-dev

# Fedora / RHEL / CentOS
sudo dnf install cups-devel

# Arch Linux
sudo pacman -S cups
```

Without them the build fails. At runtime, the CUPS service must be running to
list printers and print.
