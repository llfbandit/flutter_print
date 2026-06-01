import Cocoa
import FlutterMacOS
import PDFKit

public class FlutterPrintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPrintPlugin()
    FlutterPrintApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
  }
}

// MARK: - FlutterPrintApi

extension FlutterPrintPlugin: FlutterPrintApi {
  func print(filePath: String, options: PrintOptions) throws {
    try handlePrint(filePath: filePath, options: options, showPanel: false)
  }

  func printPreview(filePath: String, options: PrintOptions) throws {
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
      let defaultName = NSPrintInfo.shared.printer.name
      let printers = NSPrinter.printerNames.map { name in
        PrinterInfo(
          label: name,
          address: name,
          isDefault: name == defaultName,
          capabilities: PrinterCapabilities(
            supportsColor: nil,
            supportsDuplex: nil,
            maxCopies: nil,
            supportedPageSizes: []
          )
        )
      }
      completion(.success(printers))
    }
  }
}

// MARK: - Private

private extension FlutterPrintPlugin {
  func handlePrint(filePath: String, options: PrintOptions, showPanel: Bool) throws {
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw PigeonError(code: "FILE_NOT_FOUND",
                        message: "File not found: \(filePath)",
                        details: nil)
    }

    let fileURL = URL(fileURLWithPath: filePath)

    let ext = fileURL.pathExtension.lowercased()
    if ext == "pdf" {
      try printRendered(url: fileURL, options: options, showPanel: showPanel) { info in
        guard let doc = PDFDocument(url: fileURL) else {
          throw PigeonError(code: "INVALID_FILE", message: "Cannot open PDF", details: nil)
        }
        return PDFPagePrintView(document: doc)
      }
    } else if let image = NSImage(contentsOf: fileURL) {
      try printRendered(url: fileURL, options: options, showPanel: showPanel) { info in
        ImagePrintView(image: image, bounds: info.imageablePageBounds)
      }
    } else if showPanel {
      // Preview: open in the default viewer so the user can print from there.
      DispatchQueue.main.async { NSWorkspace.shared.open(fileURL) }
    } else {
      // Other types: delegate to CUPS via lp.
      try printViaLp(url: fileURL, options: options)
    }
  }

  func buildPrintInfo(options: PrintOptions) -> NSPrintInfo {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    let isLandscape = options.landscape
    info.orientation = isLandscape ? .landscape : .portrait

    if let duplex = options.duplexMode {
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

    if let ps = options.pageSize {
      var sizeApplied = false
      if let name = ps.name {
        sizeApplied = applyNamedPaper(name, to: info, landscape: isLandscape)
      }
      if !sizeApplied, let w = ps.width, let h = ps.height {
        let wPts = CGFloat(w) * mmToPts
        let hPts = CGFloat(h) * mmToPts
        info.paperSize = isLandscape
          ? NSSize(width: hPts, height: wPts)
          : NSSize(width: wPts, height: hPts)
      }
    }

    if let m = options.margins {
      info.topMargin    = CGFloat(m.top)    * mmToPts
      info.bottomMargin = CGFloat(m.bottom) * mmToPts
      info.leftMargin   = CGFloat(m.left)   * mmToPts
      info.rightMargin  = CGFloat(m.right)  * mmToPts
    }

    PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(options.copies), false)
    info.updateFromPMPrintSettings()

    if let name = options.printerAddress, let printer = NSPrinter(name: name) {
      info.printer = printer
    }

    return info
  }

  func printRendered(
    url: URL,
    options: PrintOptions,
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

  func printViaLp(url: URL, options: PrintOptions) throws {
    var args: [String] = []
    if let addr = options.printerAddress, !addr.isEmpty {
      args += ["-d", addr]
    }
    if options.copies > 1 {
      args += ["-n", "\(options.copies)"]
    }
    if options.landscape {
      args += ["-o", "orientation-requested=4"]
    }
    if !options.color {
      args += ["-o", "print-color-mode=monochrome"]
    }
    if let duplex = options.duplexMode {
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
  func applyNamedPaper(_ name: String, to info: NSPrintInfo, landscape: Bool) -> Bool {
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

// MARK: - Print views

private class ImagePrintView: NSView {
  let image: NSImage

  init(image: NSImage, bounds: NSRect) {
    self.image = image
    super.init(frame: bounds)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSMakeRange(1, 1)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect { bounds }

  override func draw(_ dirtyRect: NSRect) {
    let imgSize = image.size
    guard imgSize.width > 0, imgSize.height > 0 else { return }
    let scale = min(bounds.width / imgSize.width, bounds.height / imgSize.height)
    let drawRect = NSRect(
      x: bounds.midX - imgSize.width  * scale / 2,
      y: bounds.midY - imgSize.height * scale / 2,
      width:  imgSize.width  * scale,
      height: imgSize.height * scale)
    image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
  }
}

private class PDFPagePrintView: NSView {
  let document: PDFDocument
  private var currentPage = 0

  init(document: PDFDocument) {
    self.document = document
    let bounds = document.page(at: 0)?.bounds(for: .cropBox)
      ?? NSRect(x: 0, y: 0, width: 595, height: 842)
    super.init(frame: bounds)
  }

  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { false }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSMakeRange(1, document.pageCount)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect {
    currentPage = page - 1
    return document.page(at: currentPage)?.bounds(for: .cropBox) ?? frame
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let page = document.page(at: currentPage) else { return }
    ctx.saveGState()
    page.draw(with: .cropBox, to: ctx)
    ctx.restoreGState()
  }
}
