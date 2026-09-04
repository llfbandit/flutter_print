import Flutter
import UIKit

public class FlutterPrintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPrintPlugin()
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
    DispatchQueue.main.async {
      guard let rootVC = self.rootViewController() else {
        completion(.success(nil))
        return
      }

      let picker = UIPrinterPickerController(initiallySelectedPrinter: nil)

      let handler: UIPrinterPickerController.CompletionHandler = { [picker] controller, userDidSelect, _ in
        _ = picker
        guard userDidSelect, let printer = controller.selectedPrinter else {
          completion(.success(nil))
          return
        }
        completion(.success(PrinterInfo(
          label: printer.displayName,
          address: printer.url.absoluteString,
          isDefault: false,
          capabilities: PrinterCapabilities(
            colorCapability: .unknown,
            supportsDuplex: nil,
            maxCopies: nil,
            supportedPageSizes: []
          )
        )))
      }

      if UIDevice.current.userInterfaceIdiom == .pad {
        picker.present(from: rootVC.view.bounds, in: rootVC.view,
                       animated: true, completionHandler: handler)
      } else {
        picker.present(animated: true, completionHandler: handler)
      }
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

    let printInfo = UIPrintInfo(dictionary: nil)
    printInfo.jobName = fileURL.lastPathComponent
    // Each option is applied only when provided; unset fields keep UIPrintInfo's
    // system defaults.
    if let color = options?.color {
      printInfo.outputType = color ? .general : .grayscale
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

    DispatchQueue.main.async {
      let controller = UIPrintInteractionController.shared
      controller.printInfo = printInfo
      controller.printingItem = fileURL

      // Bridges the UIKit completion handler to the Pigeon completion. A
      // user-cancelled dialog (completed == false) is reported as success,
      // since cancellation is a normal outcome rather than a failure.
      let printHandler: UIPrintInteractionController.CompletionHandler = { _, _, error in
        if let error {
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: error.localizedDescription)))
        } else {
          completion(.success(()))
        }
      }

      // If a printer URL string is provided, print directly without UI.
      // This path does not need a view controller.
      if !showPreview,
         let urlString = options?.printerAddress,
         let printerURL = URL(string: urlString)
      {
        let printer = UIPrinter(url: printerURL)
        if !controller.print(to: printer, completionHandler: printHandler) {
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "Failed to start the print job")))
        }
        return
      }

      guard let rootVC = self.rootViewController() else {
        completion(.failure(PigeonError(code: "NO_WINDOW",
                                        message: "No active window to present the print dialog")))
        return
      }

      let presented: Bool
      if UIDevice.current.userInterfaceIdiom == .pad {
        presented = controller.present(from: rootVC.view.bounds, in: rootVC.view,
                                       animated: true, completionHandler: printHandler)
      } else {
        presented = controller.present(animated: true, completionHandler: printHandler)
      }
      if !presented {
        completion(.failure(PigeonError(code: "PRINT_ERROR",
                                        message: "Failed to present the print dialog")))
      }
    }
  }

  func rootViewController() -> UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow })?
      .rootViewController
  }
}

private extension PigeonError {
  convenience init(code: String, message: String) {
    self.init(code: code, message: message, details: nil)
  }
}
