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
  func print(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPreview: false)
  }

  func printPreview(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPreview: true)
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

      let handler: UIPrinterPickerController.CompletionHandler = { controller, userDidSelect, _ in
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
  func handlePrint(filePath: String, options: PrintOptions?, showPreview: Bool) throws {
    let fileURL = URL(fileURLWithPath: filePath)

    guard FileManager.default.fileExists(atPath: filePath) else {
      throw PigeonError(code: "FILE_NOT_FOUND",
                        message: "File not found: \(filePath)",
                        details: nil)
    }

    guard UIPrintInteractionController.canPrint(fileURL) else {
      throw PigeonError(code: "UNSUPPORTED_FILE",
                        message: "File type not supported for printing",
                        details: nil)
    }

    let printInfo = UIPrintInfo(dictionary: nil)
    printInfo.jobName = fileURL.lastPathComponent
    printInfo.outputType = (options?.color ?? true) ? .general : .grayscale
    printInfo.orientation = (options?.landscape == true) ? .landscape : .portrait
    if let duplex = options?.duplexMode {
      switch duplex {
      case .none:      printInfo.duplex = .none
      case .longEdge:  printInfo.duplex = .longEdge
      case .shortEdge: printInfo.duplex = .shortEdge
      }
    }

    let controller = UIPrintInteractionController.shared
    controller.printInfo = printInfo
    controller.printingItem = fileURL

    DispatchQueue.main.async {
      guard let rootVC = self.rootViewController() else { return }

      // If a printer URL string is provided, print directly without UI.
      if !showPreview,
         let urlString = options?.printerAddress,
         let printerURL = URL(string: urlString)
      {
        let printer = UIPrinter(url: printerURL)
        controller.print(to: printer, completionHandler: nil)
        return
      }

      if UIDevice.current.userInterfaceIdiom == .pad {
        controller.present(from: rootVC.view.bounds, in: rootVC.view,
                           animated: true, completionHandler: nil)
      } else {
        controller.present(animated: true, completionHandler: nil)
      }
    }
  }

  func rootViewController() -> UIViewController? {
    if #available(iOS 15.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: { $0.isKeyWindow })?
        .rootViewController
    } else {
      return UIApplication.shared.keyWindow?.rootViewController
    }
  }
}
