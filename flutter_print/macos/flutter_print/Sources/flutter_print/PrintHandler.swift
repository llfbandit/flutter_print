import Cocoa
import FlutterMacOS
import PDFKit

/// Boxes a Pigeon completion so it can be passed through the Objective-C
/// `contextInfo` pointer of `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)`.
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
      printRendered(options: options, showPanel: showPanel,
                    pageCount: doc.pageCount, completion: completion) { pages, paper in
        PDFPagePrintView(document: doc, pages: pages, paperSize: paper)
      }
    } else if let image = NSImage(contentsOf: fileURL) {
      printRendered(options: options, showPanel: showPanel,
                    pageCount: 1, completion: completion) { _, paper in
        ImagePrintView(image: image, paperSize: paper)
      }
    } else if showPanel {
      openInDefaultApp(fileURL, errorCode: "PREVIEW_ERROR", completion: completion)
    } else {
      // No native renderer for this file type. Try a silent CUPS job via lp;
      // if that's blocked (e.g. the app is sandboxed, which forbids spawning
      // /usr/bin/lp), fall back to handing the file to its default app.
      printViaLp(url: fileURL, options: options) { result in
        switch result {
        case .launchFailed:
          self.openInDefaultApp(fileURL, errorCode: "PRINT_ERROR", completion: completion)
        case .completed(0):
          completion(.success(()))
        case .completed(let status):
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "lp exited with status \(status)")))
        }
      }
    }
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
      // mirrors the `print-color-mode` option used by the lp fallback and lets
      // the direct (no-panel) PDF/image path honour `color` as well.
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
      PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(copies), false)
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

  /// Resolves [ranges] into a sorted list of 0-based document page indices to
  /// print. Returns every page (`0..<pageCount`) when [ranges] is nil or empty,
  /// and nil when the selection matches no page in the document.
  private func selectedPageIndices(ranges: [PageRange]?, pageCount: Int) -> [Int]? {
    guard let ranges, !ranges.isEmpty else { return Array(0..<pageCount) }
    let pages = (0..<pageCount).filter { idx in
      let page = Int64(idx + 1)
      return ranges.contains { page >= $0.start && page <= $0.end }
    }
    return pages.isEmpty ? nil : pages
  }

  private func printRendered(
    options: PrintOptions?,
    showPanel: Bool,
    pageCount: Int,
    completion: @escaping (Result<Void, Error>) -> Void,
    makeView: ([Int], NSSize) -> NSView
  ) {
    guard let pages = selectedPageIndices(ranges: options?.pageRanges, pageCount: pageCount)
    else {
      completion(.failure(PigeonError(code: "INVALID_PAGE_RANGE",
                                      message: "Page ranges select no page")))
      return
    }
    let (printInfo, defaults) = buildPrintInfo(options: options)
    // A single range goes to the panel's "Range from … to …" over the whole
    // document, where the user can see and edit it. The panel can't express a
    // discontinuous selection, so for those the view holds only the pages.
    var viewPages = pages
    if options?.pageRanges?.count == 1, let first = pages.first, let last = pages.last {
      let attrs = printInfo.dictionary()
      attrs[NSPrintInfo.AttributeKey.allPages] = false
      attrs[NSPrintInfo.AttributeKey.firstPage] = first + 1
      attrs[NSPrintInfo.AttributeKey.lastPage] = last + 1
      viewPages = Array(0..<pageCount)
    }
    // Settings the options changed from the printer defaults.
    let requested = printInfo.printSettings.filter { key, value in
      !(defaults[key].map { ($0 as AnyObject).isEqual(value) } ?? false)
    }
    // The view re-reads paper and margins when paginating (see PaperPrintView).
    let view = makeView(viewPages, printInfo.paperSize)
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

  /// Outcome of attempting a silent `lp` print job.
  private enum LpResult {
    /// `lp` could not be spawned at all (e.g. the app is sandboxed).
    case launchFailed
    /// `lp` ran to completion with the given exit status (0 == success).
    case completed(Int32)
  }

  private func printViaLp(url: URL, options: PrintOptions?,
                          completion: @escaping (LpResult) -> Void) {
    var args: [String] = []
    if let addr = options?.printerAddress, !addr.isEmpty {
      args += ["-d", addr]
    }
    if let copies = options?.copies, copies > 1 {
      args += ["-n", "\(copies)"]
    }
    if options?.landscape == true {
      args += ["-o", "orientation-requested=4"]
    }
    if options?.color == false {
      args += ["-o", "print-color-mode=monochrome"]
    }
    if let duplex = options?.duplexMode {
      let sides = switch duplex {
      case .none:      "one-sided"
      case .longEdge:  "two-sided-long-edge"
      case .shortEdge: "two-sided-short-edge"
      }
      args += ["-o", "sides=\(sides)"]
    }
    if let pageRanges = cupsPageRanges(options?.pageRanges) {
      args += ["-o", "page-ranges=\(pageRanges)"]
    }
    if let ps = options?.pageSize {
      if !ps.name.isEmpty {
        // Most CUPS drivers accept the well-known name directly (e.g. "A4").
        args += ["-o", "media=\(ps.name)"]
      } else if let w = ps.width, let h = ps.height {
        args += ["-o", "media=Custom.\(Int(w * mmToPts))x\(Int(h * mmToPts))"]
      }
    }
    if let m = options?.margins {
      // Best-effort: honored by CUPS' built-in filters, ignored by drivers
      // that manage their own imageable area.
      args += ["-o", "page-top=\(Int(m.top * mmToPts))"]
      args += ["-o", "page-bottom=\(Int(m.bottom * mmToPts))"]
      args += ["-o", "page-left=\(Int(m.left * mmToPts))"]
      args += ["-o", "page-right=\(Int(m.right * mmToPts))"]
    }
    args.append(url.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
    process.arguments = args

    // Run lp off the platform thread and wait for it, so the actual print
    // outcome (not merely whether the process spawned) is reported back.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try process.run()
      } catch {
        completion(.launchFailed)
        return
      }
      process.waitUntilExit()
      completion(.completed(process.terminationStatus))
    }
  }

  /// Formats [ranges] as a CUPS `page-ranges` value (e.g. `"2-6,9,15"`).
  /// Returns nil when the selection is unset or empty (print all pages).
  private func cupsPageRanges(_ ranges: [PageRange]?) -> String? {
    guard let ranges, !ranges.isEmpty else { return nil }
    return ranges.map { $0.start == $0.end ? "\($0.start)" : "\($0.start)-\($0.end)" }
      .joined(separator: ",")
  }
}

private extension PigeonError {
  convenience init(code: String, message: String) {
    self.init(code: code, message: message, details: nil)
  }
}
