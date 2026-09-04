import Cocoa

extension FlutterPrintPlugin {
  func pickPrinter(completion: @escaping (Result<PrinterInfo?, any Error>) -> Void) {
    // macOS has no equivalent UI picker; use listPrinters() instead.
    completion(.success(nil))
  }

  func listPrinters(completion: @escaping (Result<[PrinterInfo], any Error>) -> Void) {
    // NSPrinter.printerNames can trigger network lookups for Bonjour printers,
    // so enumerate on a background queue to avoid stalling the platform thread.
    DispatchQueue.global(qos: .userInitiated).async {
      var pmInfo: [String: (isAvailable: Bool, capabilities: PrinterCapabilities)] = [:]
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
          pmInfo[name] = (
            isAvailable: state == PMPrinterState(kPMPrinterIdle)
              || state == PMPrinterState(kPMPrinterProcessing),
            capabilities: Self.capabilities(for: pmPrinter))
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

  /// Page sizes from the paper list; color/duplex/max-copies from the PPD.
  /// Both paths work inside the App Sandbox; PPD fields degrade to unknown/nil
  /// if the read ever fails.
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
    var paperListRef: Unmanaged<CFArray>?
    guard PMPrinterGetPaperList(printer, &paperListRef) == noErr,
          let cfArray = paperListRef?.takeUnretainedValue() else { return [] }

    var result: [String] = []
    var seen = Set<String>()
    for i in 0..<CFArrayGetCount(cfArray) {
      guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
      let paper = unsafeBitCast(rawPtr, to: PMPaper.self)
      var nameRef: Unmanaged<CFString>?
      guard PMPaperGetPPDPaperName(paper, &nameRef) == noErr,
            let ppdName = nameRef?.takeUnretainedValue() as String? else { continue }
      if let mapped = ppdPageSizeName[ppdName], seen.insert(mapped).inserted {
        result.append(mapped)
      }
    }
    return result
  }

  private static func ppdText(for printer: PMPrinter) -> String? {
    var urlRef: Unmanaged<CFURL>?
    guard PMPrinterCopyDescriptionURL(printer, kPMPPDDescriptionType as CFString, &urlRef) == noErr,
          let url = urlRef?.takeRetainedValue() as URL? else { return nil }
    // isoLatin1 so no byte sequence can fail to decode.
    return try? String(contentsOf: url, encoding: .isoLatin1)
  }

  /// PPD paper-name keywords mapped to the plugin's well-known names
  /// (see `paperSizesMm`); unlisted keywords are dropped.
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
    // No Duplex section in the PPD means no duplex support → false, not unknown.
    var supportsDuplex = false
    var maxCopies: Int64? = nil

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
