import Cocoa
import PDFKit

/// Largest rect with [size]'s aspect ratio that fits centred in [rect].
private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
  let scale = min(rect.width / size.width, rect.height / size.height)
  let w = size.width * scale, h = size.height * scale
  return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

class ImagePrintView: NSView {
  let image: NSImage
  /// Area within the sheet the image is allowed to occupy (paper size minus
  /// the requested margins), in the view's coordinate system.
  private let contentRect: NSRect

  init(image: NSImage, paperSize: NSSize, contentRect: NSRect) {
    self.image = image
    self.contentRect = contentRect
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSMakeRange(1, 1)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect { bounds }

  override func draw(_ dirtyRect: NSRect) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    image.draw(in: aspectFit(image.size, in: contentRect),
               from: .zero, operation: .copy, fraction: 1)
  }
}

class PDFPagePrintView: NSView {
  let document: PDFDocument
  /// 0-based indices of the document pages to print, in output order. Lets the
  /// print job skip pages (and support discontinuous selections like 2–6,9,15)
  /// while NSView still sees a contiguous 1..pages.count range.
  private let pages: [Int]
  /// Area within the sheet each page is scaled into (paper size minus the
  /// requested margins), in the view's coordinate system.
  private let contentRect: NSRect
  private var currentPage = 0

  init(document: PDFDocument, pages: [Int], paperSize: NSSize, contentRect: NSRect) {
    self.document = document
    self.pages = pages
    self.contentRect = contentRect
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSMakeRange(1, pages.count)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect {
    // `page` is the 1-based output position; map it to the document page index.
    currentPage = pages[page - 1]
    return bounds
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let page = document.page(at: currentPage),
          let cgPage = page.pageRef else { return }

    let pageRect = page.bounds(for: .cropBox)
    let fit = aspectFit(pageRect.size, in: contentRect)

    ctx.saveGState()

    let s = fit.width / pageRect.width
    ctx.translateBy(x: fit.minX, y: fit.minY)
    ctx.scaleBy(x: s, y: s)
    ctx.drawPDFPage(cgPage)

    ctx.restoreGState()
  }
}
