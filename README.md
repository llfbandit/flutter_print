# flutter_print

A Flutter plugin focusing on print, that's it.

**PDF and image files** are rendered natively on every platform.

**All other file types** (HTML, plain text, Office documents, …) are forwarded to the platform's default handler for that format.
`PrintOptions` fields other than `printerName` may not be forwarded in this case.

---

## Usage

### Basic print

```dart
import 'package:flutter_print/flutter_print.dart';

// List available printers
final List<PrinterInfo> printers = await FlutterPrint.listPrinters();

// Print with default settings
await FlutterPrint.print('/path/to/document.pdf');

// On the web `filePath` must be a URL accessible from the page's origin.
// The browser's native print dialog (which includes a preview) is always shown.
// Blob URL is OK too.
await FlutterPrint.print('https://example.com/document.pdf');
```

### Print with options

```dart
await FlutterPrint.print(
  '/path/to/document.pdf',
  options: PrintOptions(
    // Target a specific printer (uses system default when omitted).
    printerName: 'my_printer',

    // Use a named page size preset.
    // Or via PageSize(width: w, height: h)
    pageSize: PaperSizes.a4,

    // Margins in millimetres.
    margins: PageMargins(top: 10, bottom: 10, left: 15, right: 15),

    copies: 2,
    landscape: false,
    color: true,
  ),
);
```

---

## Feature support by platform

| Feature        | Android | iOS | macOS | Windows | Linux | Web |
|----------------|---------|-----|-------|---------|-------|-----|
| Direct print   |         | ✔️† | ✔️   | ✔️      | ✔️   |     |
| Setup & print  | ✔️      | ✔️ | ✔️   | ✔️      | ✔️§  | ✔️  |
| List printers  |         |     | ✔️   | ✔️      | ✔️   |     |

† On iOS, with a `printerAddress` from `FlutterPrint.ios?.pickPrinter()` (e.g. `ipp://printer.local./ipp/print`),

§ On Linux it uses `xdg-open` to open the file in its default viewer.

## Option support by platform

Not all options are honoured on every platform. Unsupported fields are silently
ignored.

| Option           | Android | iOS | macOS | Windows | Linux | Web |
|------------------|---------|-----|-------|---------|-------|-----|
| `printerAddress` |         | ✔️† | ✔️   | ✔️      | ✔️   |     |
| `pageSize`       | ✔️      |     | ✔️   | ✔️‡     | ✔️§  |     |
| `margins`        | ✔️      |     | ✔️   |         | ✔️§  |     |
| `copies`         |         |     | ✔️   | ✔️‡     | ✔️   |     |
| `landscape`      | ✔️      | ✔️  | ✔️   | ✔️‡    | ✔️   |    |
| `color`          | ✔️      | ✔️  | ✔️   | ✔️‡    | ✔️   |    |
| `duplexMode`     | ✔️      | ✔️  | ✔️   | ✔️‡    | ✔️§  |    |

† On iOS, with a `printerAddress` from `FlutterPrint.ios?.pickPrinter()` (e.g. `ipp://printer.local./ipp/print`).

‡ Windows — options are fully applied for **PDF** files and **image** files.
All other file types are delegated to their associated application with its own defaults.  

§ Linux — requires CUPS.  

---

## Image support by platform

| Format | Windows | macOS | iOS | Android | Linux |
|--------|---------|-------|-----|---------|-------|
| JPEG   | ✔️      | ✔️   | ✔️  | ✔️     | ✔️    |
| PNG    | ✔️      | ✔️   | ✔️  | ✔️     | ✔️    |
| BMP    | ✔️      | ✔️   | ✔️  | ✔️     | ✔️    |
| GIF    | ✔️      | ✔️   | ✔️  | ✔️     | ✔️    |
| TIFF   | ✔️      | ✔️   | ✔️  | ✔️     | ✔️    |
| WebP   | ✔️¹     | ✔️²  | ✔️² | ✔️     | ✔️³   |
| HEIC   | ✔️¹     | ✔️²  | ✔️² | ✔️     | ✔️³   |

¹ Requires the WebP or HEIC codec from the Microsoft Store (built into Windows 11 for HEIC).  
² Requires macOS / iOS 11 or later.  
³ Requires the matching GDK-Pixbuf loader: `webp-pixbuf-loader` for WebP, `libheif` + `heif-pixbuf-loader` for HEIC.

---

## Setup

### macOS

You must add print entitlement to your app:

`macos/Runner/Release.entitlements` and `macos/Runner/DebugProfile.entitlements`
```xml
<dict>
  <key>com.apple.security.print</key>
  <true/>
</dict>
```

### Linux

Printer enumeration and direct printing require the **CUPS** development
libraries. Install them before building the application:

```sh
# Debian / Ubuntu
sudo apt-get install libcups2-dev

# Fedora / RHEL / CentOS
sudo dnf install cups-devel

# Arch Linux
sudo pacman -S cups
```

When `libcups2-dev` is absent the plugin still compiles, but `listPrinters`
returns an empty list and `print` falls back to the `lp` command-line tool
(which requires CUPS to be running at runtime).
