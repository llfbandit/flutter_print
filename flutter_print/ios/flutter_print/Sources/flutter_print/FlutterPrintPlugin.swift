import Flutter
import UIKit
import UniformTypeIdentifiers

public class FlutterPrintPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  // All jobs share UIPrintInteractionController.shared: run one at a time.
  private var isPrinting = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPrintPlugin()
    instance.registrar = registrar
    FlutterPrintApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }
}

// MARK: - FlutterPrintApi

extension FlutterPrintPlugin: FlutterPrintApi {
  func print(filePath: String, options: PrintOptions?,
             completion: @escaping (Result<Void, Error>) -> Void) {
    handlePrint(filePath: filePath, options: options, showPreview: false, completion: completion)
  }

  func printPreview(filePath: String, options: PrintOptions?,
                    completion: @escaping (Result<Void, Error>) -> Void) {
    handlePrint(filePath: filePath, options: options, showPreview: true, completion: completion)
  }

  func listPrinters(completion: @escaping (Result<[PrinterInfo], any Error>) -> Void) {
    // iOS does not expose a public API for enumerating printers.
    completion(.success([]))
  }

  func pickPrinter(completion: @escaping (Result<PrinterInfo?, any Error>) -> Void) {
    guard let view = registrar?.viewController?.view else {
      completion(.failure(Self.noWindowError))
      return
    }

    let picker = UIPrinterPickerController(initiallySelectedPrinter: nil)
    // Capturing the picker keeps it alive until it completes.
    let handler: UIPrinterPickerController.CompletionHandler = { _, userDidSelect, _ in
      guard userDidSelect, let printer = picker.selectedPrinter else {
        completion(.success(nil))
        return
      }
      // Contact the printer: its capabilities are valid only after that.
      printer.contactPrinter { available in DispatchQueue.main.async {
        completion(.success(PrinterInfo(
          label: printer.displayName,
          address: printer.url.absoluteString,
          isDefault: false,
          capabilities: PrinterCapabilities(
            colorCapability: !available ? .unknown : printer.supportsColor ? .supported : .monochrome,
            supportsDuplex: available ? printer.supportsDuplex : nil,
            maxCopies: nil,
            supportedPageSizes: []
          ),
          isAvailable: available
        )))
      }}
    }

    let presented = UIDevice.current.userInterfaceIdiom == .pad
      ? picker.present(from: Self.popoverAnchor(in: view), in: view,
                       animated: true, completionHandler: handler)
      : picker.present(animated: true, completionHandler: handler)
    // UIKit doesn't call the handler when it can't show the picker.
    if !presented {
      completion(.failure(PigeonError(code: "PRINT_ERROR",
                                      message: "Failed to present the printer picker")))
    }
  }
}

// MARK: - Private

private extension FlutterPrintPlugin {
  func handlePrint(filePath: String, options: PrintOptions?, showPreview: Bool,
                   completion: @escaping (Result<Void, Error>) -> Void) {
    let fileURL = URL(fileURLWithPath: filePath)

    guard FileManager.default.fileExists(atPath: filePath) else {
      completion(.failure(PigeonError(code: "FILE_NOT_FOUND",
                                      message: "File not found: \(filePath)")))
      return
    }

    guard UIPrintInteractionController.canPrint(fileURL) else {
      completion(.failure(PigeonError(code: "UNSUPPORTED_FILE",
                                      message: "File type not supported for printing")))
      return
    }

    guard !isPrinting else {
      completion(.failure(PigeonError(code: "PRINT_ERROR",
                                      message: "Another print job is in progress")))
      return
    }

    let printInfo = UIPrintInfo(dictionary: nil)
    printInfo.jobName = fileURL.lastPathComponent
    // Unset options keep the system defaults.
    if let color = options?.color {
      // Photo types pick photo paper and quality for images.
      printInfo.outputType = Self.isImage(fileURL)
        ? (color ? .photo : .photoGrayscale)
        : (color ? .general : .grayscale)
    }
    if let landscape = options?.landscape {
      printInfo.orientation = landscape ? .landscape : .portrait
    }
    if let duplex = options?.duplexMode {
      switch duplex {
      case .none:      printInfo.duplex = .none
      case .longEdge:  printInfo.duplex = .longEdge
      case .shortEdge: printInfo.duplex = .shortEdge
      }
    }

    let controller = UIPrintInteractionController.shared
    // Report a cancel as success: it is a normal outcome.
    let printHandler: UIPrintInteractionController.CompletionHandler = { _, _, error in
      self.isPrinting = false
      if let error {
        completion(.failure(PigeonError(code: "PRINT_ERROR",
                                        message: error.localizedDescription)))
      } else {
        completion(.success(()))
      }
    }
    // Set the job only once it can run, so a failed call leaves others alone.
    let start = {
      self.isPrinting = true
      controller.printInfo = printInfo
      controller.printingItem = fileURL
    }

    // With a printer address, print directly without UI.
    if !showPreview, let address = options?.printerAddress, !address.isEmpty {
      guard let url = URL(string: address) else {
        completion(.failure(PigeonError(code: "PRINTER_ERROR",
                                        message: "Invalid printer address: \(address)")))
        return
      }
      let printer = UIPrinter(url: url)
      // Fail like macOS for an unknown printer.
      isPrinting = true
      printer.contactPrinter { available in DispatchQueue.main.async {
        guard available else {
          self.isPrinting = false
          completion(.failure(PigeonError(code: "PRINTER_ERROR",
                                          message: "Printer not found: \(address)")))
          return
        }
        start()
        if !controller.print(to: printer, completionHandler: printHandler) {
          self.isPrinting = false
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "Failed to start the print job")))
        }
      }}
      return
    }

    guard let view = registrar?.viewController?.view else {
      completion(.failure(Self.noWindowError))
      return
    }
    start()
    let presented = UIDevice.current.userInterfaceIdiom == .pad
      ? controller.present(from: Self.popoverAnchor(in: view), in: view,
                           animated: true, completionHandler: printHandler)
      : controller.present(animated: true, completionHandler: printHandler)
    if !presented {
      isPrinting = false
      completion(.failure(PigeonError(code: "PRINT_ERROR",
                                      message: "Failed to present the print dialog")))
    }
  }

  static let noWindowError = PigeonError(code: "NO_WINDOW",
                                         message: "No view to present the print dialog")

  static func isImage(_ url: URL) -> Bool {
    guard #available(iOS 14, *),
          let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    else { return false }
    return type.conforms(to: .image)
  }

  /// A point at the centre of [view]: a full-view rect leaves the popover
  /// arrow no room.
  static func popoverAnchor(in view: UIView) -> CGRect {
    CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
  }
}

private extension PigeonError {
  convenience init(code: String, message: String) {
    self.init(code: code, message: message, details: nil)
  }
}
