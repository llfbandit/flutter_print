import Cocoa
import PDFKit

/// Largest rect with [size]'s aspect ratio that fits centred in [rect].
private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
  let scale = min(rect.width / size.width, rect.height / size.height)
  let w = size.width * scale, h = size.height * scale
  return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

/// A one-sheet-per-page print view sized to the print operation's paper.
/// Paper and margins are re-read on every pagination, so changes made in the
/// print panel (paper size, orientation) apply to the preview and the output.
class PaperPrintView: NSView {
  /// Area within the sheet content is scaled into (paper size minus the
  /// requested margins), in the view's coordinate system.
  private(set) var contentRect: NSRect

  /// Number of sheets the view prints.
  var pageCount: Int { 1 }

  init(paperSize: NSSize) {
    contentRect = NSRect(origin: .zero, size: paperSize)
    super.init(frame: contentRect)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    if let info = NSPrintOperation.current?.printInfo {
      let paper = info.paperSize
      setFrameSize(paper)
      contentRect = NSRect(
        x: info.leftMargin,
        y: info.bottomMargin,
        width:  max(0, paper.width  - info.leftMargin - info.rightMargin),
        height: max(0, paper.height - info.topMargin  - info.bottomMargin))
    }
    range.pointee = NSMakeRange(1, pageCount)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect { bounds }
}

class ImagePrintView: PaperPrintView {
  let image: NSImage

  init(image: NSImage, paperSize: NSSize) {
    self.image = image
    super.init(paperSize: paperSize)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    image.draw(in: aspectFit(image.size, in: contentRect),
               from: .zero, operation: .copy, fraction: 1)
  }
}

class PDFPagePrintView: PaperPrintView {
  let document: PDFDocument
  /// 0-based indices of the document pages to print, in output order. Lets the
  /// print job skip pages (and support discontinuous selections like 2–6,9,15)
  /// while NSView still sees a contiguous 1..pages.count range.
  private let pages: [Int]
  private var currentPage = 0

  init(document: PDFDocument, pages: [Int], paperSize: NSSize) {
    self.document = document
    self.pages = pages
    super.init(paperSize: paperSize)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var pageCount: Int { pages.count }

  override func rectForPage(_ page: Int) -> NSRect {
    // `page` is the 1-based output position; map it to the document page index.
    currentPage = pages[page - 1]
    return super.rectForPage(page)
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
