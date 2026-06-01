import 'package:pigeon/pigeon.dart';

// Run generation (from the package root):
//
//   dart run pigeon --input pigeon/messages.dart
//
// macOS shares the same generated Swift file as iOS. After running the command
// above, copy the generated Swift file to the macOS source tree:
//
//   cp ios/flutter_print/Sources/flutter_print/Messages.swift \
//      macos/flutter_print/Sources/flutter_print/Messages.swift

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    javaOut: 'android/src/main/java/com/llfbandit/flutter_print/Messages.java',
    javaOptions: JavaOptions(package: 'com.llfbandit.flutter_print'),
    swiftOut: 'ios/flutter_print/Sources/flutter_print/Messages.swift',
    swiftOptions: SwiftOptions(),
    gobjectHeaderOut: 'linux/messages.h',
    gobjectSourceOut: 'linux/messages.cc',
    gobjectOptions: GObjectOptions(module: 'FlutterPrint'),
    cppHeaderOut: 'windows/messages.h',
    cppSourceOut: 'windows/messages.cpp',
    cppOptions: CppOptions(namespace: 'flutter_print'),
  ),
)
// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------
/// Duplex (double-sided) printing mode.
enum DuplexMode {
  /// Single-sided printing.
  none,

  /// Double-sided, flip along the long edge (portrait binding).
  longEdge,

  /// Double-sided, flip along the short edge (landscape binding).
  shortEdge,
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------
/// Identifies a paper size by either a well-known [name] or explicit
/// [width]/[height] dimensions in millimetres.
///
/// When both fields are present, [name] takes priority.
class PageSize {
  const PageSize({required this.name, this.width, this.height});

  /// Well-known paper-size identifier. Common values: `'A3'`, `'A4'`, `'A5'`,
  /// `'Letter'`, `'Legal'`. See each platform's documentation for the full
  /// list of accepted names.
  final String name;

  /// Page width in millimetres. Used when [name] is null or unrecognised.
  final double? width;

  /// Page height in millimetres. Used when [name] is null or unrecognised.
  final double? height;
}

/// Per-side page margins expressed in millimetres.
///
/// **iOS / Windows** — ignored; margins are controlled by the system dialog
///   or the application that handles the print verb.
class PageMargins {
  const PageMargins({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });

  /// Top margin in millimetres.
  final double top;

  /// Bottom margin in millimetres.
  final double bottom;

  /// Left margin in millimetres.
  final double left;

  /// Right margin in millimetres.
  final double right;
}

/// Options controlling how a print or print-preview job is submitted.
///
/// Unsupported fields on a given platform are silently ignored.
class PrintOptions {
  const PrintOptions({
    this.printerAddress,
    this.pageSize,
    this.margins,
    this.copies = 1,
    this.landscape = false,
    this.color = false,
    this.duplexMode,
  });

  /// Technical address of the target printer. Use [PrinterInfo.address] as
  /// the value. When `null` the platform system default printer is used.
  ///
  /// Platform notes:
  /// - **Android** — ignored; the user selects the printer inside the dialog.
  /// - **iOS** — must be a full AirPrint URL (e.g.
  ///   `'ipp://printer.local/ipp/print'`). When provided the job is sent
  ///   directly without showing a dialog.
  /// - **macOS / Windows** — the printer display name (same as
  ///   [PrinterInfo.label] on these platforms).
  /// - **Linux** — the CUPS destination/queue name.
  final String? printerAddress;

  /// Desired output page size.
  ///
  /// Platform support: Android, macOS, Linux (named sizes only), Windows
  /// (passed to the associated application via the shell print verb, actual
  /// support depends on the application).
  final PageSize? pageSize;

  /// Output page margins.
  ///
  /// Ignored on iOS and Windows.
  final PageMargins? margins;

  /// Number of copies to print. Must be ≥ 1.
  ///
  /// Ignored on iOS and Windows (controlled by the system dialog).
  final int copies;

  /// Whether to print in landscape orientation.
  final bool landscape;

  /// Whether to print in colour. Set to `false` for greyscale/monochrome.
  final bool color;

  /// Duplex (double-sided) printing mode.
  ///
  /// When `null` the platform default is used (typically single-sided).
  /// Ignored on iOS (controlled by the system dialog) and on Windows for
  /// non-image/non-PDF files delegated via ShellExecuteW.
  final DuplexMode? duplexMode;
}

/// Capabilities of a specific printer as reported by the host platform.
///
/// Fields may be `null` when the platform does not provide that information.
class PrinterCapabilities {
  const PrinterCapabilities({
    this.supportsColor,
    this.supportsDuplex,
    this.maxCopies,
    required this.supportedPageSizes,
  });

  /// Whether the printer can print in colour. `null` if unknown.
  final bool? supportsColor;

  /// Whether the printer supports duplex (double-sided) printing. `null` if
  /// unknown.
  final bool? supportsDuplex;

  /// Maximum number of copies the printer accepts in a single job. `null` if
  /// unknown or unlimited.
  final int? maxCopies;

  /// Well-known page-size names accepted by this printer (e.g. `'A4'`,
  /// `'Letter'`). Empty when the platform does not report supported sizes.
  final List<String?> supportedPageSizes;
}

/// Describes a single printer returned by [FlutterPrintApi.listPrinters].
class PrinterInfo {
  const PrinterInfo({
    required this.label,
    this.address,
    this.description,
    required this.isDefault,
    required this.capabilities,
    this.isAvailable,
  });

  /// Human-readable display name shown to the user (e.g. `'HP LaserJet Pro'`).
  final String label;

  /// Platform-specific technical identifier used to address the printer.
  ///
  /// Pass this value as [PrintOptions.printerAddress] to send a job directly
  /// to this printer.
  ///
  /// Platform notes:
  /// - **iOS** — full AirPrint URL (e.g. `'ipp://printer.local/ipp/print'`).
  /// - **macOS / Windows** — same as [label]; the display name is the system
  ///   identifier on these platforms.
  /// - **Linux** — CUPS destination/queue name (e.g. `'HP_LaserJet_Pro'`).
  /// - **Android** — not set; the user selects the printer inside the dialog.
  final String? address;

  /// Optional longer description provided by the platform (e.g. the printer
  /// model or location). May be `null`.
  final String? description;

  /// Whether this is the current system-default printer.
  final bool isDefault;

  /// Capabilities advertised by the printer.
  final PrinterCapabilities capabilities;

  /// Whether the printer is currently online and accepting jobs.
  ///
  /// `true` — printer is idle or processing (online).
  /// `false` — printer is offline or stopped.
  /// `null` — availability cannot be determined on this platform
  ///   (Android and iOS).
  ///
  /// Platform support: macOS, Windows, Linux.
  final bool? isAvailable;
}

// ---------------------------------------------------------------------------
// Host API — implemented natively, called from Dart
// ---------------------------------------------------------------------------

/// Native print API. All methods are implemented on the host side and invoked
/// from Dart through Pigeon-generated channels.
@HostApi()
abstract class FlutterPrintApi {
  /// Sends [filePath] directly to the printer described by [options].
  ///
  /// The file must exist and be readable by the process. Supported file
  /// formats depend on the platform and the installed printer drivers (PDF is
  /// universally accepted).
  ///
  /// **Android / iOS** — always opens the system print dialog (which includes
  /// a preview step). The [PrintOptions.printerName] field is ignored on
  /// Android; on iOS it must be a full AirPrint URL to bypass the dialog.
  ///
  /// **macOS** — uses `NSPrintOperation`. For PDF files the job is rendered
  /// page-by-page using PDFKit. Other file types are opened with the default
  /// application instead.
  ///
  /// **Windows** — delegates to `ShellExecuteW` with the `print` verb (or
  /// `printto` when [PrintOptions.printerName] is set). The associated
  /// application handles the actual rendering.
  ///
  /// **Linux** — submits the job via CUPS (`cupsPrintFile`). Falls back to
  /// the `lp` command-line tool when CUPS is not available at build time.
  ///
  /// Throws a [PlatformException] if the file is not found, the file type is
  /// unsupported, or the print subsystem reports an error.
  void print(String filePath, PrintOptions options);

  /// Opens the native print-preview or print dialog for [filePath].
  ///
  /// **Android / iOS** — identical to [print]: the system print dialog always
  /// includes a preview step on these platforms.
  ///
  /// **macOS** — opens `NSPrintPanel` so the user can review and adjust
  /// settings before printing.
  ///
  /// **Windows** — opens the file in its default application (e.g. a PDF
  /// viewer) using `ShellExecuteW` with the `open` verb. The application's
  /// own print dialog is used for the final print step.
  ///
  /// **Linux** — opens the file with `xdg-open`, delegating preview and
  /// printing to the default document viewer.
  ///
  /// Throws a [PlatformException] if the file is not found.
  void printPreview(String filePath, PrintOptions options);

  /// Returns all printers currently available on this device.
  ///
  /// **Android / iOS / Web** — always returns an empty list. Android's print
  /// framework only exposes printers inside an active `PrintService` context.
  /// iOS has no public AirPrint enumeration API; use [pickPrinter] instead.
  ///
  /// The I/O is performed on a background thread on all platforms; the
  /// platform UI thread is never blocked.
  @async
  List<PrinterInfo> listPrinters();

  /// Shows a native AirPrint printer-picker UI and returns the selected
  /// printer, or `null` if the user cancelled.
  ///
  /// **iOS only** — uses `UIPrinterPickerController`. The returned
  /// [PrinterInfo.name] is the full AirPrint URL (e.g.
  /// `ipp://MyPrinter.local./ipp/print`) suitable for use as
  /// [PrintOptions.printerName].
  ///
  /// Returns `null` on all other platforms.
  @async
  PrinterInfo? pickPrinter();
}
