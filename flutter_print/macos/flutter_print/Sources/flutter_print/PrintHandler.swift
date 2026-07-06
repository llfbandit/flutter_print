import Cocoa
import FlutterMacOS
import PDFKit

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
                                      message: "File not found: \(filePath)",
                                      details: nil)))
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    let ext = fileURL.pathExtension.lowercased()

    if ext == "pdf" {
      guard let doc = PDFDocument(url: fileURL) else {
        completion(.failure(PigeonError(code: "INVALID_FILE",
                                        message: "Cannot open PDF", details: nil)))
        return
      }
      // Restrict to the selected pages (all pages when unset/empty). When the
      // selection matches nothing there is nothing to print — report success.
      let pages = selectedPageIndices(ranges: options?.pageRanges, pageCount: doc.pageCount)
      if pages.isEmpty { completion(.success(())); return }
      printRendered(url: fileURL, options: options, showPanel: showPanel,
                    completion: completion) { info in
        let l = self.layout(for: info)
        return PDFPagePrintView(document: doc, pages: pages,
                                paperSize: l.paper, contentRect: l.content)
      }
    } else if let image = NSImage(contentsOf: fileURL) {
      // An image is a single page: skip it when the selection excludes page 1.
      let pages = selectedPageIndices(ranges: options?.pageRanges, pageCount: 1)
      if pages.isEmpty { completion(.success(())); return }
      printRendered(url: fileURL, options: options, showPanel: showPanel,
                    completion: completion) { info in
        let l = self.layout(for: info)
        return ImagePrintView(
          image: image,
          bounds: NSRect(origin: .zero, size: l.paper),
          contentRect: l.content)
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
        case .completed(let status) where status == 0:
          completion(.success(()))
        case .completed(let status):
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "lp exited with status \(status)",
                                          details: nil)))
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
                                        message: "Cannot open file: \(fileURL.path)",
                                        details: nil)))
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

  private func buildPrintInfo(options: PrintOptions?) -> NSPrintInfo {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo

    // Each option is applied only when provided; unset fields keep the system
    // default print settings.
    if let landscape = options?.landscape {
      info.orientation = landscape ? .landscape : .portrait
    }

    if let duplex = options?.duplexMode {
      let mode: PMDuplexMode
      switch duplex {
      case .none:      mode = PMDuplexMode(kPMDuplexNone)
      case .longEdge:  mode = PMDuplexMode(kPMDuplexNoTumble)
      case .shortEdge: mode = PMDuplexMode(kPMDuplexTumble)
      }
      PMSetDuplex(OpaquePointer(info.pmPrintSettings()), mode)
      info.updateFromPMPrintSettings()
    }

    // Force greyscale output when colour is disabled. Entries added to
    // printSettings are forwarded to the print job as CUPS options, so this
    // mirrors the `print-color-mode` option used by the lp fallback and lets
    // the direct (no-panel) PDF/image path honour `color` as well. When colour
    // is enabled we leave the setting untouched so the printer keeps its
    // default mode.
    if options?.color == false {
      info.printSettings["print-color-mode"] = "monochrome"
    }

    let mmToPts: CGFloat = 72.0 / 25.4

    // Paper size is set in natural (portrait) dimensions; NSPrintInfo rotates
    // it to match `orientation` automatically, so no manual landscape swap.
    if let ps = options?.pageSize {
      let sizeApplied = applyNamedPaper(ps.name, to: info)
      if !sizeApplied, let w = ps.width, let h = ps.height {
        info.paperSize = NSSize(width: CGFloat(w) * mmToPts, height: CGFloat(h) * mmToPts)
      }
    }

    if let m = options?.margins {
      info.topMargin    = CGFloat(m.top)    * mmToPts
      info.bottomMargin = CGFloat(m.bottom) * mmToPts
      info.leftMargin   = CGFloat(m.left)   * mmToPts
      info.rightMargin  = CGFloat(m.right)  * mmToPts
    } else {
      // No margins requested: fill the whole sheet. Without this the inherited
      // NSPrintInfo.shared defaults (~1 inch each side) would silently shrink
      // the rendered PDF/image.
      info.topMargin = 0
      info.bottomMargin = 0
      info.leftMargin = 0
      info.rightMargin = 0
    }

    if let copies = options?.copies {
      PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(copies), false)
      info.updateFromPMPrintSettings()
    }

    if let name = options?.printerAddress, let printer = NSPrinter(name: name) {
      info.printer = printer
    }

    return info
  }

  /// Resolves [ranges] into a sorted list of 0-based document page indices to
  /// print. Returns every page (`0..<pageCount`) when [ranges] is nil or empty,
  /// and an empty array when the selection matches no page in the document.
  private func selectedPageIndices(ranges: [PageRange]?, pageCount: Int) -> [Int] {
    guard pageCount > 0 else { return [] }
    guard let ranges, !ranges.isEmpty else { return Array(0..<pageCount) }
    return (0..<pageCount).filter { idx in
      let page = Int64(idx + 1)
      return ranges.contains { page >= $0.start && page <= $0.end }
    }
  }

  /// Paper size (already oriented by NSPrintInfo) and the content rect both
  /// custom print views draw into (paper minus the requested margins).
  private func layout(for info: NSPrintInfo) -> (paper: NSSize, content: NSRect) {
    let paper = info.paperSize
    let content = NSRect(
      x: info.leftMargin,
      y: info.bottomMargin,
      width:  max(0, paper.width  - info.leftMargin - info.rightMargin),
      height: max(0, paper.height - info.topMargin  - info.bottomMargin))
    return (paper, content)
  }

  private func printRendered(
    url: URL,
    options: PrintOptions?,
    showPanel: Bool,
    completion: @escaping (Result<Void, Error>) -> Void,
    makeView: (NSPrintInfo) throws -> NSView
  ) {
    let printInfo = buildPrintInfo(options: options)
    let view: NSView
    do {
      view = try makeView(printInfo)
    } catch {
      completion(.failure(error))
      return
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
      } else {
        // run() is synchronous and returns whether the job succeeded.
        if op.run() {
          completion(.success(()))
        } else {
          completion(.failure(PigeonError(code: "PRINT_ERROR",
                                          message: "Print operation failed",
                                          details: nil)))
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
      switch duplex {
      case .none:      args += ["-o", "sides=one-sided"]
      case .longEdge:  args += ["-o", "sides=two-sided-long-edge"]
      case .shortEdge: args += ["-o", "sides=two-sided-short-edge"]
      }
    }
    if let pageRanges = cupsPageRanges(options?.pageRanges) {
      args += ["-o", "page-ranges=\(pageRanges)"]
    }
    let mmToPts = 72.0 / 25.4
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

  @discardableResult
  private func applyNamedPaper(_ name: String, to info: NSPrintInfo) -> Bool {
    let sizes: [String: (Double, Double)] = [
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
    guard let (w, h) = sizes[name] else { return false }
    let k: CGFloat = 72.0 / 25.4
    info.paperSize = NSSize(width: CGFloat(w) * k, height: CGFloat(h) * k)
    return true
  }
}
