import AppKit
import QuartzCore

/// A view showing content measured in its own units (scan pixels, page millimetres), fitted to the view and
/// zoomable with a pinch or ⌘-scroll. Images live in Core Animation layers on `stage`, so moving and
/// zooming is composited on the GPU; handles and guides are drawn on `overlay` above them.
class ZoomableCanvas: NSView {
    let stage = StageView()
    let overlay = OverlayView()
    var padding: CGFloat = 28

    var contentSize: CGSize = .zero {
        didSet {
            guard oldValue != contentSize else { return }
            zoom = 1
            focus = nil
            transformChanged()
        }
    }

    private(set) var zoom: CGFloat = 1
    /// The content point shown at the view's centre; nil means the content's centre.
    private var focus: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for v in [stage, overlay] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        overlay.drawHandler = { [unowned self] in self.drawOverlay() }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return max(0.0001, min((bounds.width - 2 * padding) / contentSize.width, (bounds.height - 2 * padding) / contentSize.height))
    }

    /// View points per content unit.
    var scale: CGFloat { fitScale * zoom }

    /// Where the content's origin sits in the view.
    var origin: CGPoint {
        let f = focus ?? CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        return CGPoint(x: (bounds.midX - f.x * scale).rounded(), y: (bounds.midY - f.y * scale).rounded())
    }

    var contentRectInView: CGRect {
        CGRect(origin: origin, size: CGSize(width: contentSize.width * scale, height: contentSize.height * scale))
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }

    func toContent(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }

    func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        transformChanged()
    }

    /// Re-lays the layers and redraws the overlay after the content moved, zoomed or changed.
    func transformChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStage()
        CATransaction.commit()
        overlay.needsDisplay = true
    }

    /// Subclasses position their layers on `stage.root` here (view coordinates, y down).
    func layoutStage() {}

    /// Subclasses draw handles and guides here, in view coordinates.
    func drawOverlay() {}

    // MARK: Zooming and panning

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: location(event))
    }

    override func smartMagnify(with event: NSEvent) {
        if zoom > 1 { resetZoom() } else { zoom(by: 2.5, at: location(event)) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            zoom(by: exp(event.scrollingDeltaY * step), at: location(event))
            return
        }
        guard zoom > 1 else { return super.scrollWheel(with: event) }
        pan(byView: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    func pan(byView delta: CGSize) {
        let f = focus ?? CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        focus = clampFocus(CGPoint(x: f.x - delta.width / scale, y: f.y - delta.height / scale))
        transformChanged()
    }

    func zoom(by factor: CGFloat, at point: CGPoint) {
        guard factor.isFinite, factor > 0, contentSize.width > 0 else { return }
        let anchor = toContent(point)
        let newZoom = min(max(zoom * factor, 1), 16)
        guard newZoom != zoom else { return }
        zoom = newZoom
        if zoom <= 1.0001 {
            zoom = 1
            focus = nil
        } else {
            // Keep the content under the pointer where it is.
            focus = clampFocus(CGPoint(x: anchor.x - (point.x - bounds.midX) / scale, y: anchor.y - (point.y - bounds.midY) / scale))
        }
        transformChanged()
    }

    func resetZoom() {
        zoom = 1
        focus = nil
        transformChanged()
    }

    private func clampFocus(_ f: CGPoint) -> CGPoint {
        CGPoint(x: min(max(f.x, 0), contentSize.width), y: min(max(f.y, 0), contentSize.height))
    }
}

/// Holds the image layers. `root` has a top-left origin to match the flipped views around it.
final class StageView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        root.isGeometryFlipped = true
        root.masksToBounds = true
        layer?.addSublayer(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }
}

/// Draws on top of the layers and lets every click through to the canvas.
final class OverlayView: NSView {
    var drawHandler: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawHandler?() }
}

/// Shared drawing helpers for the overlays.
enum OverlayStyle {
    static var accent: NSColor { .controlAccentColor }

    static func strokeOutline(_ points: [CGPoint], in ctx: CGContext, width: CGFloat = 1.5) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        let path = ctx.path
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(width + 2)
        ctx.strokePath()
        if let path { ctx.addPath(path) }
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    static func handle(at p: CGPoint, in ctx: CGContext, radius: CGFloat = 4.5) {
        let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r)
    }

    static func turnKnob(from edge: CGPoint, to knob: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.25)
        ctx.move(to: edge)
        ctx.addLine(to: knob)
        ctx.strokePath()
        let r = CGRect(x: knob.x - 6, y: knob.y - 6, width: 12, height: 12)
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r)
        // A small arc arrow inside, so it reads as "turn".
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.2)
        ctx.addArc(center: knob, radius: 3, startAngle: -.pi * 0.9, endAngle: .pi * 0.5, clockwise: false)
        ctx.strokePath()
    }

    /// A label in a dark rounded box, centred horizontally on `point` with its top at `point.y`.
    static func label(_ text: String, at point: CGPoint, bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var box = CGRect(x: point.x - size.width / 2 - 7, y: point.y, width: size.width + 14, height: size.height + 6)
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, bounds.minY + 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    static func hint(_ text: String, in rect: CGRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: p,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = s.boundingRect(with: CGSize(width: rect.width - 40, height: 200), options: .usesLineFragmentOrigin).height
        s.draw(with: CGRect(x: rect.minX + 20, y: rect.midY - h / 2, width: rect.width - 40, height: h), options: .usesLineFragmentOrigin)
    }
}
