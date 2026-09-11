import Cocoa
import FlutterMacOS
import PDFKit
import UniformTypeIdentifiers

private let mmToPts = 72.0 / 25.4

/// Well-known paper sizes in portrait millimetres, keyed by `PageSize.name`.
private let paperSizesMm: [String: (Double, Double)] = [
  // ISO A-series
  "A0": (841, 1189), "A1": (594, 841), "A2": (420, 594),
  "A3": (297, 420), "A4": (210, 297), "A5": (148, 210), "A6": (105, 148),
  // ISO B-series
  "B4": (250, 353), "B5": (176, 250),
  // North American
  "Letter": (215.9, 279.4), "Legal": (215.9, 355.6),
  "Tabloid": (279.4, 431.8), "Executive": (184.2, 266.7),
  // JIS B-series
  "JIS B4": (257, 364), "JIS B5": (182, 257),
  // Envelopes
  "C5": (162, 229), "DL": (110, 220),
]

/// Boxes a Pigeon completion so it can be passed through the Objective-C
/// `contextInfo` pointer of `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)`.
private final class PrintCompletionBox {
  let completion: (Result<Void, Error>) -> Void
  init(_ completion: @escaping (Result<Void, Error>) -> Void) {
    self.completion = completion
  }
}

extension FlutterPrintPlugin {
  func print(filePath: String, options: PrintOptions?,
             completion: @escaping (Result<Void, Error>) -> Void) {
    handlePrint(filePath: filePath, options: options, showPanel: false, completion: completion)
  }

  func printPreview(filePath: String, options: PrintOptions?,
                    completion: @escaping (Result<Void, Error>) -> Void) {
    handlePrint(filePath: filePath, options: options, showPanel: true, completion: completion)
  }

  private func handlePrint(filePath: String, options: PrintOptions?, showPanel: Bool,
                           completion: @escaping (Result<Void, Error>) -> Void) {
    guard FileManager.default.fileExists(atPath: filePath) else {
      completion(.failure(PigeonError(code: "FILE_NOT_FOUND",
                                      message: "File not found: \(filePath)")))
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    let ext = fileURL.pathExtension.lowercased()

    if ext == "pdf" {
      guard let doc = PDFDocument(url: fileURL) else {
        completion(.failure(PigeonError(code: "INVALID_FILE",
                                        message: "Cannot open PDF")))
        return
      }
      printRendered(options: options, showPanel: showPanel, completion: completion) {
        PDFPagePrintView(document: doc, paperSize: $0)
      }
    } else if let image = NSImage(contentsOf: fileURL) {
      printRendered(options: options, showPanel: showPanel, completion: completion) {
        ImagePrintView(image: image, paperSize: $0)
      }
    } else if let text = readDocument(fileURL) {
      printRendered(options: options, showPanel: showPanel, completion: completion) {
        DocumentPrintView(text: text, paperSize: $0)
      }
    } else if showPanel {
      // No native renderer: let the default app preview and print it.
      openInDefaultApp(fileURL, errorCode: "PREVIEW_ERROR", completion: completion)
    } else {
      // Opening the default app would not print, so fail rather than report
      // a success.
      completion(.failure(PigeonError(code: "UNSUPPORTED_FILE",
                                      message: "File type not supported for printing")))
    }
  }

  /// Reads any document AppKit can import (plain text, RTF, HTML, Word,
  /// OpenDocument…) as styled text, or returns nil. AppKit reads files it
  /// can't parse as raw plain text, so plain text is only accepted from files
  /// whose type is text.
  private func readDocument(_ url: URL) -> NSAttributedString? {
    guard #available(macOS 11, *),
          let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    else { return nil }
    let isText = type.conforms(to: .text)
    // Skip media, archives and other non-documents: AppKit would read them
    // whole as plain text before we could reject them.
    guard isText || type.conforms(to: .compositeContent) else { return nil }
    var attrs: NSDictionary?
    guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: &attrs),
          let kind = attrs?[NSAttributedString.DocumentAttributeKey.documentType]
            as? NSAttributedString.DocumentType else { return nil }
    return kind != .plain || isText ? text : nil
  }

  /// Hands [fileURL] to its default application, reporting whether the open
  /// succeeded. Runs on the main thread as required by NSWorkspace.
  private func openInDefaultApp(_ fileURL: URL, errorCode: String,
                                completion: @escaping (Result<Void, Error>) -> Void) {
    DispatchQueue.main.async {
      if NSWorkspace.shared.open(fileURL) {
        completion(.success(()))
      } else {
        completion(.failure(PigeonError(code: errorCode,
                                        message: "Cannot open file: \(fileURL.path)")))
      }
    }
  }

  /// Called by `runModal(for:delegate:didRun:contextInfo:)` when the print sheet
  /// is dismissed. Cancellation (`success == false`) is treated as success, to
  /// match the iOS dialog behaviour where cancelling is a normal outcome.
  @objc func printOperationDidRun(_ printOperation: NSPrintOperation,
                                  success: Bool,
                                  contextInfo: UnsafeMutableRawPointer?) {
    guard let contextInfo else { return }
    let box = Unmanaged<PrintCompletionBox>.fromOpaque(contextInfo).takeRetainedValue()
    box.completion(.success(()))
  }

  /// Returns print info with [options] applied, and the printer's settings
  /// before any option, to tell which settings the options changed.
  private func buildPrintInfo(
    options: PrintOptions?
  ) -> (info: NSPrintInfo, defaults: NSDictionary) {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo

    // Pick the printer first: the colour settings below depend on its driver.
    if let name = options?.printerAddress, let printer = NSPrinter(name: name) {
      info.printer = printer
    }
    let defaults = info.printSettings.copy() as! NSDictionary

    // Each option is applied only when provided; unset fields keep the system
    // default print settings.
    if let landscape = options?.landscape {
      info.orientation = landscape ? .landscape : .portrait
    }

    if let duplex = options?.duplexMode {
      let (mode, ppdChoice) = switch duplex {
      case .none:      (PMDuplexMode(kPMDuplexNone), "None")
      case .longEdge:  (PMDuplexMode(kPMDuplexNoTumble), "DuplexNoTumble")
      case .shortEdge: (PMDuplexMode(kPMDuplexTumble), "DuplexTumble")
      }
      PMSetDuplex(OpaquePointer(info.pmPrintSettings()), mode)
      info.updateFromPMPrintSettings()
      // Also set the standard PPD duplex option, which drivers and saved panel
      // presets use; left at the driver default it could contradict the above.
      info.printSettings["Duplex"] = ppdChoice
    }

    if let color = options?.color {
      // Force greyscale output when colour is disabled. Entries added to
      // printSettings are forwarded to the print job as CUPS options, so this
      // works for any driver, including ones without colour presets.
      if !color { info.printSettings["print-color-mode"] = "monochrome" }
      // The print panel ignores that CUPS option; set the driver's own colour
      // option so the panel shows the requested mode.
      applyColorPreset(color, to: info)
    }

    // Paper size is set in natural (portrait) dimensions; NSPrintInfo rotates
    // it to match `orientation` automatically, so no manual landscape swap.
    if let ps = options?.pageSize {
      if let (w, h) = paperSizesMm[ps.name] {
        info.paperSize = NSSize(width: w * mmToPts, height: h * mmToPts)
      } else if let w = ps.width, let h = ps.height {
        info.paperSize = NSSize(width: w * mmToPts, height: h * mmToPts)
      }
    }

    // No margins requested: fill the whole sheet. Without this the inherited
    // NSPrintInfo.shared defaults (~1 inch each side) would silently shrink
    // the rendered PDF/image.
    let m = options?.margins
    info.topMargin    = (m?.top    ?? 0) * mmToPts
    info.bottomMargin = (m?.bottom ?? 0) * mmToPts
    info.leftMargin   = (m?.left   ?? 0) * mmToPts
    info.rightMargin  = (m?.right  ?? 0) * mmToPts

    if let copies = options?.copies {
      // Clamp: converting a negative or huge value would trap.
      PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(clamping: max(1, copies)), false)
      info.updateFromPMPrintSettings()
    }

    return (info, defaults)
  }

  /// Sets the driver options behind the print panel's colour control (e.g.
  /// `ColorModel`), read from the printer's Apple presets: those whose value
  /// differs between a monochrome preset and its colour twin. No-op when the
  /// driver has no such presets.
  private func applyColorPreset(_ color: Bool, to info: NSPrintInfo) {
    var printer: PMPrinter?
    var listRef: Unmanaged<CFArray>?
    guard PMSessionGetCurrentPrinter(OpaquePointer(info.pmPrintSession()), &printer) == noErr,
          let printer, PMPrinterCopyPresets(printer, &listRef) == noErr,
          let list = listRef?.takeRetainedValue() else { return }

    // Key presets by their other traits (quality, paper coating…) so each
    // monochrome preset pairs with the colour preset that differs only in mode.
    // Keep the driver's order so every run picks the same pair.
    let modeKey = "com.apple.print.preset.output-mode"
    let settingsKey = "com.apple.print.preset.settings"
    var mono: [(traits: NSDictionary, settings: [String: Any])] = []
    var colour: [NSDictionary: [String: Any]] = [:]
    for i in 0..<CFArrayGetCount(list) {
      let preset = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: PMPreset.self)
      var attrsRef: Unmanaged<CFDictionary>?
      guard PMPresetGetAttributes(preset, &attrsRef) == noErr,
            let attrs = attrsRef?.takeUnretainedValue() as? [String: Any],
            let settings = attrs[settingsKey] as? [String: Any] else { continue }
      let excluded: Set = [modeKey, settingsKey, "com.apple.print.preset.id"]
      let traits = NSDictionary(dictionary: attrs.filter { !excluded.contains($0.key) })
      if attrs[modeKey] as? String == "monochrome" {
        mono.append((traits, settings))
      } else if colour[traits] == nil {
        colour[traits] = settings
      }
    }

    // Prefer the normal-quality pair.
    let pairs = mono.compactMap { m in colour[m.traits].map { (m.traits, m.settings, $0) } }
    guard let (_, m, c) = pairs.first(where: {
            $0.0["com.apple.print.preset.quality"] as? String == "mid"
          }) ?? pairs.first else { return }
    // Set what the wanted preset sets differently, including options the
    // other preset lacks.
    let (wanted, other) = color ? (c, m) : (m, c)
    for (key, value) in wanted where !(value as AnyObject).isEqual(other[key]) {
      info.printSettings[key] = value
    }
  }

  private func printRendered(
    options: PrintOptions?,
    showPanel: Bool,
    completion: @escaping (Result<Void, Error>) -> Void,
    makeView: (NSSize) -> PaperPrintView
  ) {
    // An unknown printer would silently fall back to the default one.
    if let name = options?.printerAddress, !name.isEmpty, NSPrinter(name: name) == nil {
      completion(.failure(PigeonError(code: "PRINTER_ERROR",
                                      message: "Printer not found: \(name)")))
      return
    }
    let (printInfo, defaults) = buildPrintInfo(options: options)
    // Paginate now: a text document's page count depends on paper and margins.
    // The view paginates again when printing (see PaperPrintView).
    let view = makeView(printInfo.paperSize)
    view.layOut(for: printInfo)
    // Reversed ranges would trap; FlutterPrint already rejects them.
    let ranges = (options?.pageRanges ?? []).compactMap {
      $0.start <= $0.end ? Int($0.start)...Int($0.end) : nil
    }
    view.pageRanges = ranges
    guard let first = view.pages.first, let last = view.pages.last else {
      completion(.failure(PigeonError(code: "INVALID_PAGE_RANGE",
                                      message: "Page ranges select no page")))
      return
    }
    // A single range goes to the panel's "Range from … to …" over the whole
    // document, where the user can see and edit it. The panel can't express a
    // discontinuous selection, so for those the view prints only the pages.
    if ranges.count == 1 {
      view.pageRanges = []
      let attrs = printInfo.dictionary()
      attrs[NSPrintInfo.AttributeKey.allPages] = false
      attrs[NSPrintInfo.AttributeKey.firstPage] = first + 1
      attrs[NSPrintInfo.AttributeKey.lastPage] = last + 1
    }
    // Settings the options changed from the printer defaults.
    let requested = printInfo.printSettings.filter { key, value in
      !(defaults[key].map { ($0 as AnyObject).isEqual(value) } ?? false)
    }
    DispatchQueue.main.async {
      let op = NSPrintOperation(view: view, printInfo: printInfo)
      op.showsPrintPanel = showPanel
      op.showsProgressPanel = !showPanel
      // By default the print panel only shows copies, page range and the
      // preview. Enable the remaining controls so the panel actually reflects
      // (and lets the user adjust) the options we applied to printInfo:
      // paper size, orientation and scaling, plus the page-setup accessory.
      if showPanel {
        op.printPanel.options.formUnion([
          .showsPaperSize,
          .showsOrientation,
          .showsScaling,
          .showsPageSetupAccessory,
        ])
      }
      // Attach as a sheet on the app's visible window so macOS can show the
      // print panel correctly. run() (app-modal) fails with "does not support
      // printing" when called outside a user-event context.
      let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
      if showPanel, let window {
        // The sheet is asynchronous; resolve the completion from the didRun
        // callback, passing it through contextInfo as a retained box.
        let context = Unmanaged.passRetained(PrintCompletionBox(completion)).toOpaque()
        op.runModal(for: window, delegate: self,
                    didRun: #selector(self.printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: context)
        // Opening the panel applies the user's selected preset (e.g. "Default
        // Settings"), overriding the requested settings it covers: restore them.
        for (key, value) in requested { op.printInfo.printSettings[key] = value }
      } else {
        // run() is synchronous and returns whether the job succeeded.
        if op.run() {
          completion(.success(()))
        } else {
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "Print operation failed")))
        }
      }
    }
  }
}

private extension PigeonError {
  convenience init(code: String, message: String) {
    self.init(code: code, message: message, details: nil)
  }
}
