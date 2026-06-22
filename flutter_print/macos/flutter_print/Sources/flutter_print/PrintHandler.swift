import Cocoa
import FlutterMacOS
import PDFKit

extension FlutterPrintPlugin {
  func print(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPanel: false)
  }

  func printPreview(filePath: String, options: PrintOptions?) throws {
    try handlePrint(filePath: filePath, options: options, showPanel: true)
  }

  private func handlePrint(filePath: String, options: PrintOptions?, showPanel: Bool) throws {
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw PigeonError(code: "FILE_NOT_FOUND",
                        message: "File not found: \(filePath)",
                        details: nil)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    let ext = fileURL.pathExtension.lowercased()

    if ext == "pdf" {
      guard let doc = PDFDocument(url: fileURL) else {
        throw PigeonError(code: "INVALID_FILE", message: "Cannot open PDF", details: nil)
      }
      try printRendered(url: fileURL, options: options, showPanel: showPanel) { info in
        let ps = info.paperSize
        let paperSize: NSSize = info.orientation == .landscape
          ? NSSize(width: max(ps.width, ps.height), height: min(ps.width, ps.height))
          : NSSize(width: min(ps.width, ps.height), height: max(ps.width, ps.height))
        return PDFPagePrintView(document: doc, paperSize: paperSize)
      }
    } else if let image = NSImage(contentsOf: fileURL) {
      try printRendered(url: fileURL, options: options, showPanel: showPanel) { info in
        ImagePrintView(image: image, bounds: info.imageablePageBounds)
      }
    } else if showPanel {
      DispatchQueue.main.async { NSWorkspace.shared.open(fileURL) }
    } else {
      try printViaLp(url: fileURL, options: options)
    }
  }

  private func buildPrintInfo(options: PrintOptions?) -> NSPrintInfo {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    let isLandscape = options?.landscape ?? false
    info.orientation = isLandscape ? .landscape : .portrait

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

    let mmToPts: CGFloat = 72.0 / 25.4

    if let ps = options?.pageSize {
      let sizeApplied = applyNamedPaper(ps.name, to: info, landscape: isLandscape)
      if !sizeApplied, let w = ps.width, let h = ps.height {
        let wPts = CGFloat(w) * mmToPts
        let hPts = CGFloat(h) * mmToPts
        info.paperSize = isLandscape
          ? NSSize(width: hPts, height: wPts)
          : NSSize(width: wPts, height: hPts)
      }
    }

    if let m = options?.margins {
      info.topMargin    = CGFloat(m.top)    * mmToPts
      info.bottomMargin = CGFloat(m.bottom) * mmToPts
      info.leftMargin   = CGFloat(m.left)   * mmToPts
      info.rightMargin  = CGFloat(m.right)  * mmToPts
    }

    PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(options?.copies ?? 1), false)
    info.updateFromPMPrintSettings()

    if let name = options?.printerAddress, let printer = NSPrinter(name: name) {
      info.printer = printer
    }

    return info
  }

  private func printRendered(
    url: URL,
    options: PrintOptions?,
    showPanel: Bool,
    makeView: (NSPrintInfo) throws -> NSView
  ) throws {
    let printInfo = buildPrintInfo(options: options)
    let view = try makeView(printInfo)
    DispatchQueue.main.async {
      let op = NSPrintOperation(view: view, printInfo: printInfo)
      op.showsPrintPanel = showPanel
      op.showsProgressPanel = !showPanel
      // Attach as a sheet on the app's visible window so macOS can show the
      // print panel correctly. run() (app-modal) fails with "does not support
      // printing" when called outside a user-event context.
      let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
      if showPanel, let window {
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
      } else {
        op.run()
      }
    }
  }

  private func printViaLp(url: URL, options: PrintOptions?) throws {
    var args: [String] = []
    if let addr = options?.printerAddress, !addr.isEmpty {
      args += ["-d", addr]
    }
    if (options?.copies ?? 1) > 1 {
      args += ["-n", "\(options!.copies)"]
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
    args.append(url.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
    process.arguments = args
    try process.run()
  }

  @discardableResult
  private func applyNamedPaper(_ name: String, to info: NSPrintInfo, landscape: Bool) -> Bool {
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
    info.paperSize = landscape
      ? NSSize(width: CGFloat(h) * k, height: CGFloat(w) * k)
      : NSSize(width: CGFloat(w) * k, height: CGFloat(h) * k)
    return true
  }
}
