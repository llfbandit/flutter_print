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
  /// requested margins), in unflipped view coordinates.
  private(set) var contentRect: NSRect

  /// 1-based page ranges to print; empty prints every page. Kept as ranges
  /// rather than indices so they still apply after re-pagination.
  var pageRanges: [ClosedRange<Int>] = []

  /// Document page drawn by the next draw(_:).
  private(set) var currentPage = 0

  /// Number of pages in the document at the current layout.
  var documentPageCount: Int { 1 }

  /// 0-based document pages to print, in output order. Lets the job skip
  /// pages (discontinuous selections like 2–6,9,15) while NSView still sees a
  /// contiguous 1..n range.
  var pages: [Int] {
    let all = 0..<documentPageCount
    if pageRanges.isEmpty { return Array(all) }
    return all.filter { i in pageRanges.contains { $0.contains(i + 1) } }
  }

  /// [pages] as of the last pagination, used while printing each page.
  private var printedPages: [Int] = []

  init(paperSize: NSSize) {
    contentRect = NSRect(origin: .zero, size: paperSize)
    super.init(frame: contentRect)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Adopts [info]'s paper and margins. Subclasses re-paginate here.
  func layOut(for info: NSPrintInfo) {
    let paper = info.paperSize
    setFrameSize(paper)
    contentRect = NSRect(
      x: info.leftMargin,
      y: info.bottomMargin,
      width:  max(0, paper.width  - info.leftMargin - info.rightMargin),
      height: max(0, paper.height - info.topMargin  - info.bottomMargin))
  }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    if let info = NSPrintOperation.current?.printInfo { layOut(for: info) }
    printedPages = pages
    range.pointee = NSMakeRange(1, printedPages.count)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect {
    // `page` is the 1-based output position; map it to the document page.
    currentPage = printedPages[page - 1]
    return bounds
  }
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

  init(document: PDFDocument, paperSize: NSSize) {
    self.document = document
    super.init(paperSize: paperSize)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var documentPageCount: Int { document.pageCount }

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

/// Paginates styled text (plain text, RTF, HTML, Word…) onto the sheets.
class DocumentPrintView: PaperPrintView {
  private let storage: NSTextStorage
  private let layoutManager = NSLayoutManager()
  /// Area text flows into on each sheet, in flipped view coordinates.
  private var textRect = NSRect.zero

  init(text: NSAttributedString, paperSize: NSSize) {
    storage = NSTextStorage(attributedString: text)
    super.init(paperSize: paperSize)
    storage.addLayoutManager(layoutManager)
  }

  required init?(coder: NSCoder) { fatalError() }

  // Text lays out top-down.
  override var isFlipped: Bool { true }

  override var documentPageCount: Int { max(1, layoutManager.textContainers.count) }

  override func layOut(for info: NSPrintInfo) {
    super.layOut(for: info)
    // Keep text inside the printer's printable area, even with zero margins.
    let r = contentRect.intersection(info.imageablePageBounds)
    textRect = NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    fitAttachments()

    while !layoutManager.textContainers.isEmpty {
      layoutManager.removeTextContainer(at: 0)
    }
    // One text container per sheet, until all glyphs are placed.
    repeat {
      let container = NSTextContainer(size: textRect.size)
      layoutManager.addTextContainer(container)
      let range = layoutManager.glyphRange(for: container)
      if range.length == 0 || NSMaxRange(range) >= layoutManager.numberOfGlyphs { break }
    } while true
  }

  /// Scales images larger than the text area down to fit, so they aren't cut
  /// off at the bottom of the sheet.
  private func fitAttachments() {
    // Text containers inset each line by their padding on both sides.
    let padding = NSTextContainer().lineFragmentPadding
    let width = textRect.width - 2 * padding, height = textRect.height
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      // Cell-based attachments (from HTML/RTFD imports) ignore `bounds`; lay
      // their image out directly instead.
      if attachment.image == nil,
         let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image {
        attachment.image = image
        attachment.attachmentCell = nil
      }
      guard let natural = attachment.image?.size, natural.width > 0, natural.height > 0
      else { return }
      let scale = max(0, min(1, width / natural.width, height / natural.height))
      attachment.bounds = NSRect(x: 0, y: 0,
                                 width: natural.width * scale, height: natural.height * scale)
      layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let containers = layoutManager.textContainers
    guard currentPage < containers.count else { return }
    let range = layoutManager.glyphRange(for: containers[currentPage])
    layoutManager.drawBackground(forGlyphRange: range, at: textRect.origin)
    layoutManager.drawGlyphs(forGlyphRange: range, at: textRect.origin)
  }
}
