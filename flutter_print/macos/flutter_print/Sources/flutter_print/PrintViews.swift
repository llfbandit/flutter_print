import Cocoa
import PDFKit

/// Largest rect with [size]'s aspect ratio that fits centred in [rect].
private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
  let scale = min(rect.width / size.width, rect.height / size.height)
  let w = size.width * scale, h = size.height * scale
  return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

/// A print view with one page per sheet. It reads paper and margins again on
/// each pagination, so changes in the panel apply.
class PaperPrintView: NSView {
  /// Sheet minus margins, in unflipped coordinates.
  private(set) var contentRect: NSRect

  /// 1-based pages to print; empty prints all. Ranges still apply after
  /// re-pagination.
  var pageRanges: [ClosedRange<Int>] = []

  /// Document page the next draw(_:) draws.
  private(set) var currentPage = 0

  /// Page count at the current layout.
  var documentPageCount: Int { 1 }

  /// 0-based document pages to print. NSView sees them as pages 1…n, so the
  /// job can skip pages (e.g. 2–6,9).
  var pages: [Int] {
    let all = 0..<documentPageCount
    if pageRanges.isEmpty { return Array(all) }
    return all.filter { i in pageRanges.contains { $0.contains(i + 1) } }
  }

  /// [pages] at the last pagination.
  private var printedPages: [Int] = []

  init(paperSize: NSSize) {
    contentRect = NSRect(origin: .zero, size: paperSize)
    super.init(frame: contentRect)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Adopts the paper and margins of [info]. Subclasses paginate here.
  func layOut(for info: NSPrintInfo) {
    setFrameSize(info.paperSize)
    contentRect = Self.contentRect(for: info)
  }

  /// The paper size minus [info]'s margins.
  static func contentRect(for info: NSPrintInfo) -> NSRect {
    let paper = info.paperSize
    return NSRect(
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
    // Map the 1-based output page to the document page.
    currentPage = printedPages[page - 1]
    return bounds
  }
}

class ImagePrintView: PaperPrintView {
  private let image: NSImage

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
  private let document: PDFDocument

  init(document: PDFDocument, paperSize: NSSize) {
    self.document = document
    super.init(paperSize: paperSize)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var documentPageCount: Int { document.pageCount }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let page = document.page(at: currentPage) else { return }

    // Use the size as shown: the crop box, turned by the page rotation.
    let box = page.bounds(for: .cropBox)
    let size = page.rotation % 180 == 0 ? box.size : NSSize(width: box.height, height: box.width)
    let fit = aspectFit(size, in: contentRect)

    ctx.saveGState()

    let s = fit.width / size.width
    ctx.translateBy(x: fit.minX, y: fit.minY)
    ctx.scaleBy(x: s, y: s)
    // Applies the crop box and the rotation.
    page.draw(with: .cropBox, to: ctx)

    ctx.restoreGState()
  }
}

/// Prints styled text (plain text, RTF, HTML, Word…) paginated by [TextPages].
class DocumentPrintView: PaperPrintView {
  private let text: TextPages

  init(text: TextPages, paperSize: NSSize) {
    self.text = text
    super.init(paperSize: paperSize)
  }

  required init?(coder: NSCoder) { fatalError() }

  // Text lays out top-down.
  override var isFlipped: Bool { true }

  override var documentPageCount: Int { text.pageCount }

  override func layOut(for info: NSPrintInfo) {
    super.layOut(for: info)
    text.layOut(in: Self.textRect(for: info))
  }

  /// Text area of a sheet, in flipped coordinates. Stays in the printable
  /// area, even with zero margins.
  static func textRect(for info: NSPrintInfo) -> NSRect {
    let r = contentRect(for: info).intersection(info.imageablePageBounds)
    return NSRect(x: r.minX, y: info.paperSize.height - r.maxY, width: r.width, height: r.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    text.draw(page: currentPage)
  }
}

/// Splits styled text into pages. Not a view, so it can run off the main thread.
final class TextPages: NSObject, NSLayoutManagerDelegate {
  private let storage: NSTextStorage
  private let layoutManager = NSLayoutManager()
  // Use one container: layout slows down with each added container.
  private let container = NSTextContainer()
  private var textRect = NSRect.zero
  /// Glyphs of each page, and the page's top in the container.
  private var pages: [(glyphs: NSRange, top: CGFloat)] = []

  init(text: NSAttributedString) {
    storage = NSTextStorage(attributedString: text)
    super.init()
    layoutManager.delegate = self
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
  }

  var pageCount: Int { max(1, pages.count) }

  /// Paginates the text into [rect]-sized pages, unless already done.
  func layOut(in rect: NSRect) {
    guard rect != textRect else { return }
    textRect = rect
    fitAttachments()
    container.size = NSSize(width: rect.width, height: .greatestFiniteMagnitude)

    // Break between lines: before a line that overflows, and after a page break.
    let text = storage.string as NSString
    let all = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
    var start = 0, top: CGFloat = 0, pageBreak = false
    pages = []
    layoutManager.enumerateLineFragments(forGlyphRange: all) { line, _, _, glyphs, _ in
      if glyphs.location > start, pageBreak || line.maxY - top > rect.height {
        self.pages.append((NSRange(start..<glyphs.location), top))
        start = glyphs.location
        top = line.minY
      }
      let chars = self.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      pageBreak = chars.length > 0 && text.character(at: NSMaxRange(chars) - 1) == 0x0C
    }
    pages.append((NSRange(start..<all.length), top))
  }

  /// Draws [page] into its text area.
  func draw(page: Int) {
    guard page < pages.count else { return }
    let (glyphs, top) = pages[page]
    let origin = NSPoint(x: textRect.minX, y: textRect.minY - top)
    layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
    layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
  }

  // One container can't break pages: turn page breaks into line breaks, and
  // let layOut(in:) start the new page.
  func layoutManager(_ layoutManager: NSLayoutManager,
                     shouldUse action: NSLayoutManager.ControlCharacterAction,
                     forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
    action == .containerBreak ? .lineBreak : action
  }

  /// Scales down images larger than the text area, so the sheet doesn't cut them.
  private func fitAttachments() {
    // Containers pad each line on both sides.
    let width = textRect.width - 2 * container.lineFragmentPadding
    let height = textRect.height
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      // Cell attachments (HTML, RTFD) ignore `bounds`: use the image instead.
      // Decode it from the file, as the cell is main-thread only.
      if attachment.image == nil,
         let data = attachment.fileWrapper?.regularFileContents,
         let image = NSImage(data: data) {
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
}
