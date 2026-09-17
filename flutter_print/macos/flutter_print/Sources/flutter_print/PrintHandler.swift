import Cocoa
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

/// Carries a completion through the `contextInfo` pointer of `runModal`.
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
    // Fail rather than fall back to the default printer.
    if let name = options?.printerAddress, !name.isEmpty, NSPrinter(name: name) == nil {
      completion(.failure(PigeonError(code: "PRINTER_ERROR",
                                      message: "Printer not found: \(name)")))
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    let (printInfo, defaults) = buildPrintInfo(options: options)
    let textRect = DocumentPrintView.textRect(for: printInfo)
    // Load off the main thread: a large document takes seconds.
    DispatchQueue.global(qos: .userInitiated).async {
      let loaded = Result { try self.loadForPrint(fileURL, textRect: textRect) }
      DispatchQueue.main.async {
        switch loaded {
        case .success(let makeView?):
          self.printRendered(makeView(printInfo.paperSize), printInfo: printInfo,
                             defaults: defaults, options: options,
                             showPanel: showPanel, completion: completion)
        case .success(nil) where showPanel:
          // No native renderer: let the default app preview and print the file.
          if NSWorkspace.shared.open(fileURL) {
            completion(.success(()))
          } else {
            completion(.failure(PigeonError(code: "PREVIEW_ERROR",
                                            message: "Cannot open file: \(filePath)")))
          }
        case .success(nil):
          // Fail: opening the default app would not print.
          completion(.failure(PigeonError(code: "UNSUPPORTED_FILE",
                                          message: "File type not supported for printing")))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  /// Loads the file and returns a factory for its print view, or nil when no
  /// native renderer handles its type. Paginates text for [textRect].
  private func loadForPrint(_ fileURL: URL, textRect: NSRect) throws -> ((NSSize) -> PaperPrintView)? {
    if fileURL.pathExtension.lowercased() == "pdf" {
      guard let doc = PDFDocument(url: fileURL) else {
        throw PigeonError(code: "INVALID_FILE", message: "Cannot open PDF")
      }
      return { PDFPagePrintView(document: doc, paperSize: $0) }
    }
    if let image = NSImage(contentsOf: fileURL) {
      return { ImagePrintView(image: image, paperSize: $0) }
    }
    if let text = readDocument(fileURL) {
      let pages = TextPages(text: text)
      pages.layOut(in: textRect)
      return { DocumentPrintView(text: pages, paperSize: $0) }
    }
    return nil
  }

  /// Reads a document AppKit can import (plain text, RTF, HTML, Word…), or nil.
  private func readDocument(_ url: URL) -> NSAttributedString? {
    guard #available(macOS 11, *),
          let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    else { return nil }
    let isText = type.conforms(to: .text)
    // Skip media and archives: AppKit would read them whole as plain text.
    guard isText || type.conforms(to: .compositeContent) else { return nil }
    let read = { () -> NSAttributedString? in
      var attrs: NSDictionary?
      guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: &attrs),
            let kind = attrs?[NSAttributedString.DocumentAttributeKey.documentType]
              as? NSAttributedString.DocumentType else { return nil }
      // AppKit reads unknown formats as plain text: accept that from text files only.
      return kind != .plain || isText ? text : nil
    }
    // The HTML importer uses WebKit, which runs on the main thread only.
    let isWeb = type.conforms(to: .html) || type.conforms(to: .webArchive)
    return isWeb && !Thread.isMainThread ? DispatchQueue.main.sync(execute: read) : read()
  }

  /// Completes a sheet print. Reports a cancel as success, like on iOS.
  @objc func printOperationDidRun(_ printOperation: NSPrintOperation,
                                  success: Bool,
                                  contextInfo: UnsafeMutableRawPointer?) {
    guard let contextInfo else { return }
    let box = Unmanaged<PrintCompletionBox>.fromOpaque(contextInfo).takeRetainedValue()
    box.completion(.success(()))
  }

  /// Returns print info with [options] applied, and the printer defaults.
  private func buildPrintInfo(
    options: PrintOptions?
  ) -> (info: NSPrintInfo, defaults: NSDictionary) {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo

    // Set the printer first: the colour settings depend on its driver.
    if let name = options?.printerAddress, let printer = NSPrinter(name: name) {
      info.printer = printer
    }
    let defaults = info.printSettings.copy() as! NSDictionary

    // Unset options keep the printer defaults.
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
      // Set the PPD option too: drivers and panel presets read it.
      info.printSettings["Duplex"] = ppdChoice
    }

    if let color = options?.color {
      // The job gets print settings as CUPS options: this forces greyscale on
      // any driver.
      if !color { info.printSettings["print-color-mode"] = "monochrome" }
      // The panel ignores the CUPS option and shows the driver's own.
      applyColorPreset(color, to: info)
    }

    // Portrait size: NSPrintInfo rotates it for landscape.
    if let ps = options?.pageSize {
      if let (w, h) = paperSizesMm[ps.name] {
        info.paperSize = NSSize(width: w * mmToPts, height: h * mmToPts)
      } else if let w = ps.width, let h = ps.height {
        info.paperSize = NSSize(width: w * mmToPts, height: h * mmToPts)
      }
    }

    // Default to no margins, not the 1 inch of NSPrintInfo.shared.
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

  /// Sets the driver options behind the panel's colour control (e.g.
  /// `ColorModel`): those that differ between a monochrome preset and its
  /// colour twin. Does nothing when the driver has no such presets.
  private func applyColorPreset(_ color: Bool, to info: NSPrintInfo) {
    var printer: PMPrinter?
    var listRef: Unmanaged<CFArray>?
    guard PMSessionGetCurrentPrinter(OpaquePointer(info.pmPrintSession()), &printer) == noErr,
          let printer, PMPrinterCopyPresets(printer, &listRef) == noErr,
          let list = listRef?.takeRetainedValue() else { return }

    // Pair presets that differ only in mode, keyed by their other traits
    // (quality, paper…). Keep the driver's order for a stable choice.
    let modeKey = "com.apple.print.preset.output-mode"
    let settingsKey = "com.apple.print.preset.settings"
    let ignored: Set = [modeKey, settingsKey, "com.apple.print.preset.id"]
    var mono: [(traits: NSDictionary, settings: [String: Any])] = []
    var colour: [NSDictionary: [String: Any]] = [:]
    forEachPM(in: list, as: PMPreset.self) { preset in
      var attrsRef: Unmanaged<CFDictionary>?
      guard PMPresetGetAttributes(preset, &attrsRef) == noErr,
            let attrs = attrsRef?.takeUnretainedValue() as? [String: Any],
            let settings = attrs[settingsKey] as? [String: Any] else { return }
      let traits = NSDictionary(dictionary: attrs.filter { !ignored.contains($0.key) })
      if attrs[modeKey] as? String == "monochrome" {
        mono.append((traits, settings))
      } else if colour[traits] == nil {
        colour[traits] = settings
      }
    }

    let pairs = mono.compactMap { m in
      colour[m.traits].map { (traits: m.traits, mono: m.settings, colour: $0) }
    }
    // Prefer the normal-quality pair.
    guard let pair = pairs.first(where: {
            $0.traits["com.apple.print.preset.quality"] as? String == "mid"
          }) ?? pairs.first else { return }
    // Set what the wanted preset sets differently, even keys the other lacks.
    let (wanted, other) = color ? (pair.colour, pair.mono) : (pair.mono, pair.colour)
    for (key, value) in wanted where !(value as AnyObject).isEqual(other[key]) {
      info.printSettings[key] = value
    }
  }

  private func printRendered(
    _ view: PaperPrintView,
    printInfo: NSPrintInfo,
    defaults: NSDictionary,
    options: PrintOptions?,
    showPanel: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Text is already paginated for this paper: this only sets the frame.
    view.layOut(for: printInfo)
    // Skip reversed ranges: they would trap. FlutterPrint rejects them anyway.
    let ranges = (options?.pageRanges ?? []).compactMap {
      $0.start <= $0.end ? Int($0.start)...Int($0.end) : nil
    }
    view.pageRanges = ranges
    guard let first = view.pages.first, let last = view.pages.last else {
      completion(.failure(PigeonError(code: "INVALID_PAGE_RANGE",
                                      message: "Page ranges select no page")))
      return
    }
    // The panel shows a single range and lets the user edit it. It can't show
    // several, so the view prints only their pages.
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
    let op = NSPrintOperation(view: view, printInfo: printInfo)
    op.showsPrintPanel = showPanel
    op.showsProgressPanel = !showPanel
    // Show the controls for the options we set.
    if showPanel {
      op.printPanel.options.formUnion([
        .showsPaperSize,
        .showsOrientation,
        .showsScaling,
        .showsPageSetupAccessory,
      ])
    }
    // Show the panel as a sheet: run() fails with "does not support printing"
    // outside a user event.
    let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    if showPanel, let window {
      let context = Unmanaged.passRetained(PrintCompletionBox(completion)).toOpaque()
      op.runModal(for: window, delegate: self,
                  didRun: #selector(self.printOperationDidRun(_:success:contextInfo:)),
                  contextInfo: context)
      // The panel applies the user's preset (e.g. "Default Settings") on open:
      // restore the requested settings.
      for (key, value) in requested { op.printInfo.printSettings[key] = value }
    } else if op.run() {
      completion(.success(()))
    } else {
      completion(.failure(PigeonError(code: "PRINT_ERROR",
                                      message: "Print operation failed")))
    }
  }
}

private extension PigeonError {
  convenience init(code: String, message: String) {
    self.init(code: code, message: message, details: nil)
  }
}
