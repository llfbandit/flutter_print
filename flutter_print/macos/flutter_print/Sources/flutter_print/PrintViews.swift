import Cocoa
import PDFKit

class ImagePrintView: NSView {
  let image: NSImage
  /// Area within the sheet the image is allowed to occupy (paper size minus
  /// the requested margins), in the view's coordinate system.
  private let contentRect: NSRect

  init(image: NSImage, bounds: NSRect, contentRect: NSRect) {
    self.image = image
    self.contentRect = contentRect
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
    let scale = min(contentRect.width / imgSize.width, contentRect.height / imgSize.height)
    let drawRect = NSRect(
      x: contentRect.midX - imgSize.width  * scale / 2,
      y: contentRect.midY - imgSize.height * scale / 2,
      width:  imgSize.width  * scale,
      height: imgSize.height * scale)
    image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
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
    let target = contentRect

    ctx.saveGState()

    let s = min(target.width / pageRect.width, target.height / pageRect.height)
    ctx.translateBy(x: target.minX + (target.width  - pageRect.width  * s) / 2,
                    y: target.minY + (target.height - pageRect.height * s) / 2)
    ctx.scaleBy(x: s, y: s)
    ctx.drawPDFPage(cgPage)

    ctx.restoreGState()
  }
}
