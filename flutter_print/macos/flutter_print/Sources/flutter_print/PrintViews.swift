import Cocoa
import PDFKit

class ImagePrintView: NSView {
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

class PDFPagePrintView: NSView {
  let document: PDFDocument
  private var currentPage = 0

  init(document: PDFDocument, paperSize: NSSize) {
    self.document = document
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSMakeRange(1, document.pageCount)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect {
    currentPage = page - 1
    return bounds
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let page = document.page(at: currentPage),
          let cgPage = page.pageRef else { return }

    let pageRect = page.bounds(for: .cropBox)
    let target = bounds

    ctx.saveGState()

    let s = min(target.width / pageRect.width, target.height / pageRect.height)
    ctx.translateBy(x: (target.width  - pageRect.width  * s) / 2,
                    y: (target.height - pageRect.height * s) / 2)
    ctx.scaleBy(x: s, y: s)
    ctx.drawPDFPage(cgPage)

    ctx.restoreGState()
  }
}
