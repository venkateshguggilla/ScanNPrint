import AppKit

/// One printed sheet: its size and how to draw it in millimetres, y down.
struct PrintPage {
    var sizeMm: CGSize
    /// Scale down to the printable area. Otherwise it prints at actual size, centred on the paper.
    var fitToPaper: Bool
    var draw: (CGContext) -> Void
}

enum PrintController {
    static func run(_ pages: [PrintPage], title: String, printerName: String?, in window: NSWindow?) {
        guard let first = pages.first else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        if let name = printerName, let printer = NSPrinter(name: name) { info.printer = printer }
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        // Start with paper that matches the first page; the user can still pick another in the panel.
        let landscape = first.sizeMm.width > first.sizeMm.height
        info.orientation = landscape ? .landscape : .portrait
        if !first.fitToPaper || PaperSize.matching(width: first.sizeMm.width, height: first.sizeMm.height) != nil {
            info.paperSize = NSSize(width: Units.mmToPoints(first.sizeMm.width), height: Units.mmToPoints(first.sizeMm.height))
        }

        let view = PrintPagesView(pages: pages)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsCopies, .showsPageRange])
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

/// Lays the pages out one per sheet of whatever paper is chosen in the print panel.
private final class PrintPagesView: NSView {
    private let pages: [PrintPage]
    private var paper = NSSize(width: 595, height: 842)

    init(pages: [PrintPage]) {
        self.pages = pages
        super.init(frame: NSRect(x: 0, y: 0, width: 595, height: 842 * CGFloat(max(1, pages.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        paper = (NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared).paperSize
        setFrameSize(NSSize(width: paper.width, height: paper.height * CGFloat(pages.count)))
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let printable = info.imageablePageBounds // y up, from the paper's bottom-left
        for (i, page) in pages.enumerated() {
            let sheet = rectForPage(i + 1)
            guard sheet.intersects(dirtyRect) else { continue }
            let area = NSRect(x: sheet.minX + printable.minX, y: sheet.minY + paper.height - printable.maxY,
                              width: printable.width, height: printable.height)
            let w = Units.mmToPoints(page.sizeMm.width), h = Units.mmToPoints(page.sizeMm.height)
            var scale = 1.0
            var origin: CGPoint
            if page.fitToPaper {
                scale = min(area.width / w, area.height / h)
                origin = CGPoint(x: area.midX - w * scale / 2, y: area.midY - h * scale / 2)
            } else {
                origin = CGPoint(x: sheet.midX - w / 2, y: sheet.midY - h / 2)
            }
            ctx.saveGState()
            ctx.clip(to: sheet)
            ctx.translateBy(x: origin.x, y: origin.y)
            let k = scale * Units.mmToPoints(1)
            ctx.scaleBy(x: k, y: k)
            page.draw(ctx)
            ctx.restoreGState()
        }
    }
}
