import Cocoa
import FlutterMacOS

public class FlutterPrintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPrintPlugin()
    FlutterPrintApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
  }
}

// MARK: - FlutterPrintApi

extension FlutterPrintPlugin: FlutterPrintApi {
  func print(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPanel: false)
  }

  func printPreview(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPanel: true)
  }

  func pickPrinter(completion: @escaping (Result<PrinterInfo?, any Error>) -> Void) {
    // macOS has no equivalent UI picker; use listPrinters() instead.
    completion(.success(nil))
  }

  func listPrinters(completion: @escaping (Result<[PrinterInfo], any Error>) -> Void) {
    // NSPrinter.printerNames can trigger network lookups for Bonjour printers,
    // so enumerate on a background queue to avoid stalling the platform thread.
    DispatchQueue.global(qos: .userInitiated).async {
      var availabilityMap: [String: Bool] = [:]
      var listRef: Unmanaged<CFArray>?
      if PMServerCreatePrinterList(nil, &listRef) == noErr,
         let cfArray = listRef?.takeRetainedValue() {
        for i in 0..<CFArrayGetCount(cfArray) {
          guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
          let pmPrinter = unsafeBitCast(rawPtr, to: PMPrinter.self)
          guard let nameRef = PMPrinterGetName(pmPrinter),
                let name = nameRef.takeUnretainedValue() as String? else { continue }
          var state: PMPrinterState = 0
          PMPrinterGetState(pmPrinter, &state)
          availabilityMap[name] = (state == PMPrinterState(kPMPrinterIdle)
                                || state == PMPrinterState(kPMPrinterProcessing))
        }
      }

      let defaultName = NSPrintInfo.shared.printer.name
      let printers = NSPrinter.printerNames.map { name in
        PrinterInfo(
          label: name,
          address: name,
          isDefault: name == defaultName,
          capabilities: PrinterCapabilities(
            colorCapability: .unknown,
            supportsDuplex: nil,
            maxCopies: nil,
            supportedPageSizes: []
          ),
          isAvailable: availabilityMap[name]
        )
      }
      completion(.success(printers))
    }
  }
}
