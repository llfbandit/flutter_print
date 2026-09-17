import Cocoa

/// Calls [body] with each Printing Manager object (PMPrinter, PMPaper…) of
/// [array]. The array owns the objects: don't keep them after the call.
func forEachPM<T>(in array: CFArray, as type: T.Type, _ body: (T) -> Void) {
  for i in 0..<CFArrayGetCount(array) {
    guard let object = CFArrayGetValueAtIndex(array, i) else { continue }
    body(unsafeBitCast(object, to: T.self))
  }
}

extension FlutterPrintPlugin {
  func pickPrinter(completion: @escaping (Result<PrinterInfo?, any Error>) -> Void) {
    // macOS has no printer picker: use listPrinters().
    completion(.success(nil))
  }

  func listPrinters(completion: @escaping (Result<[PrinterInfo], any Error>) -> Void) {
    // Run off the main thread: listing Bonjour printers can hit the network.
    DispatchQueue.global(qos: .userInitiated).async {
      var pmInfo: [String: (isAvailable: Bool, capabilities: PrinterCapabilities)] = [:]
      var listRef: Unmanaged<CFArray>?
      if PMServerCreatePrinterList(nil, &listRef) == noErr,
         let list = listRef?.takeRetainedValue() {
        forEachPM(in: list, as: PMPrinter.self) { printer in
          guard let name = PMPrinterGetName(printer)?.takeUnretainedValue() as String?
          else { return }
          var state: PMPrinterState = 0
          PMPrinterGetState(printer, &state)
          pmInfo[name] = (
            isAvailable: state == PMPrinterState(kPMPrinterIdle)
              || state == PMPrinterState(kPMPrinterProcessing),
            capabilities: Self.capabilities(for: printer))
        }
      }

      let defaultName = NSPrintInfo.shared.printer.name
      let printers = NSPrinter.printerNames.map { name in
        PrinterInfo(
          label: name,
          address: name,
          isDefault: name == defaultName,
          capabilities: pmInfo[name]?.capabilities ?? Self.unknownCapabilities,
          isAvailable: pmInfo[name]?.isAvailable
        )
      }
      completion(.success(printers))
    }
  }

  private static let unknownCapabilities = PrinterCapabilities(
    colorCapability: .unknown,
    supportsDuplex: nil,
    maxCopies: nil,
    supportedPageSizes: []
  )

  /// Reads page sizes from the paper list, and colour, duplex and max copies
  /// from the PPD. Both work in the App Sandbox.
  private static func capabilities(for printer: PMPrinter) -> PrinterCapabilities {
    let parsed = ppdText(for: printer).map(parsePpd)
    return PrinterCapabilities(
      colorCapability: parsed?.color ?? .unknown,
      supportsDuplex: parsed?.supportsDuplex,
      maxCopies: parsed?.maxCopies,
      supportedPageSizes: supportedPageSizes(for: printer)
    )
  }

  private static func supportedPageSizes(for printer: PMPrinter) -> [String] {
    var listRef: Unmanaged<CFArray>?
    guard PMPrinterGetPaperList(printer, &listRef) == noErr,
          let list = listRef?.takeUnretainedValue() else { return [] }

    var result: [String] = []
    forEachPM(in: list, as: PMPaper.self) { paper in
      var nameRef: Unmanaged<CFString>?
      guard PMPaperGetPPDPaperName(paper, &nameRef) == noErr,
            let ppdName = nameRef?.takeUnretainedValue() as String?,
            let name = ppdPageSizeName[ppdName], !result.contains(name) else { return }
      result.append(name)
    }
    return result
  }

  private static func ppdText(for printer: PMPrinter) -> String? {
    var urlRef: Unmanaged<CFURL>?
    guard PMPrinterCopyDescriptionURL(printer, kPMPPDDescriptionType as CFString, &urlRef) == noErr,
          let url = urlRef?.takeRetainedValue() as URL? else { return nil }
    // Latin-1 decodes any bytes.
    return try? String(contentsOf: url, encoding: .isoLatin1)
  }

  /// PPD paper names mapped to the plugin's names (see `paperSizesMm`).
  private static let ppdPageSizeName: [String: String] = [
    "A0": "A0", "A1": "A1", "A2": "A2", "A3": "A3",
    "A4": "A4", "A5": "A5", "A6": "A6",
    "B4": "B4", "ISOB4": "B4", "B5": "B5", "ISOB5": "B5",
    "JISB4": "JIS B4", "JISB5": "JIS B5",
    "Letter": "Letter", "Legal": "Legal",
    "Tabloid": "Tabloid", "Ledger": "Tabloid", "11x17": "Tabloid",
    "Executive": "Executive",
    "C5": "C5", "ISOC5": "C5", "EnvC5": "C5",
    "DL": "DL", "EnvDL": "DL",
  ]

  private static func parsePpd(
    _ ppd: String
  ) -> (color: ColorCapability, supportsDuplex: Bool, maxCopies: Int64?) {
    var color: ColorCapability = .unknown
    // A PPD without a Duplex option has no duplex: false, not unknown.
    var supportsDuplex = false
    var maxCopies: Int64?

    ppd.enumerateLines { line, _ in
      if line.hasPrefix("*ColorDevice:") {
        let value = line.dropFirst("*ColorDevice:".count)
          .trimmingCharacters(in: .whitespaces)
        color = value.caseInsensitiveCompare("True") == .orderedSame
          ? .supported : .monochrome
      } else if line.hasPrefix("*OpenUI *Duplex") {
        supportsDuplex = true
      } else if line.hasPrefix("*cupsMaxCopies:") {
        let value = line.dropFirst("*cupsMaxCopies:".count)
          .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
        if let n = Int64(value) { maxCopies = n }
      }
    }

    return (color, supportsDuplex, maxCopies)
  }
}
