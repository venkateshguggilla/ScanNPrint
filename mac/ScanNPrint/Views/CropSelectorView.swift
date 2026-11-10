import AppKit
import QuartzCore

/// Shows a scan and lets the user select a region of it like cropping: draw a frame, move it, resize it from
/// any side or corner, and turn it with the knob above it to straighten crooked content.
final class CropSelectorView: ZoomableCanvas {
    var onChange: ((Selection) -> Void)?
    var onPlace: (() -> Void)?

    var scan: ScannedPage? {
        didSet {
            guard scan !== oldValue else { return }
            drag = nil
            imageLayer.contents = scan?.preview
            imageLayer.isHidden = scan == nil
            contentSize = scan?.pixelSize ?? .zero
            transformChanged()
        }
    }

    private(set) var selection: Selection?
    private let imageLayer = CALayer()

    private enum Drag {
        case draw(start: CGPoint, before: Selection?)
        case move(start: CGPoint, from: Selection)
        case resize(sx: Int, sy: Int, from: Selection)
        case turn(from: Selection)
        case pan(last: CGPoint)
    }

    private var drag: Drag?
    private static let knobDistance: CGFloat = 26
    private static let grab: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        imageLayer.borderWidth = 0.5
        imageLayer.shadowOpacity = 0.25
        imageLayer.shadowRadius = 6
        imageLayer.shadowOffset = CGSize(width: 0, height: 2)
        stage.root.addSublayer(imageLayer)
    }

    /// Takes the model's selection unless the user is in the middle of changing it.
    func setSelection(_ s: Selection?) {
        guard drag == nil, s != selection else { return }
        selection = s
        overlay.needsDisplay = true
    }

    override func layoutStage() {
        imageLayer.frame = contentRectInView
        imageLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: imageLayer.bounds.size), transform: nil)
    }

    // MARK: Geometry

    private var imageRect: CGRect { CGRect(origin: .zero, size: contentSize) }

    /// A point on the scan in the selection's own frame (origin at its centre, turned with it).
    private func local(_ p: CGPoint, in s: Selection) -> CGPoint { (p - s.rect.center).rotated(degrees: -s.straighten) }

    private func fromLocal(_ l: CGPoint, in s: Selection) -> CGPoint { s.rect.center + l.rotated(degrees: s.straighten) }

    private func corners(_ s: Selection) -> [CGPoint] {
        let w = s.rect.width / 2, h = s.rect.height / 2
        return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map { toView(fromLocal($0, in: s)) }
    }

    private func knob(_ s: Selection) -> (edge: CGPoint, knob: CGPoint) {
        let top = fromLocal(CGPoint(x: 0, y: -s.rect.height / 2), in: s)
        let up = CGPoint(x: 0, y: -1).rotated(degrees: s.straighten)
        let edge = toView(top)
        return (edge, edge + up * Self.knobDistance)
    }

    private enum Hit {
        case knob, handle(Int, Int), inside, outside
    }

    private func hit(_ viewPoint: CGPoint) -> Hit {
        guard let s = selection else { return .outside }
        if viewPoint.distance(to: knob(s).knob) <= Self.grab + 2 { return .knob }
        let l = local(toContent(viewPoint), in: s)
        let w = s.rect.width / 2, h = s.rect.height / 2, g = Self.grab / scale
        let nearX: Int = abs(l.x + w) <= g ? -1 : abs(l.x - w) <= g ? 1 : 0
        let nearY: Int = abs(l.y + h) <= g ? -1 : abs(l.y - h) <= g ? 1 : 0
        let withinX = abs(l.x) <= w + g, withinY = abs(l.y) <= h + g
        if withinX && withinY && (nearX != 0 || nearY != 0) { return .handle(nearX, nearY) }
        if abs(l.x) <= w && abs(l.y) <= h { return .inside }
        return .outside
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard scan != nil else { return }
        let p = location(event)
        let c = toContent(p)
        if event.clickCount == 2, case .inside = hit(p) {
            onPlace?()
            return
        }
        if event.modifierFlags.contains(.option) || (zoom > 1 && event.modifierFlags.contains(.control)) {
            drag = .pan(last: p)
            NSCursor.closedHand.set()
            return
        }
        switch hit(p) {
        case .knob: if let s = selection { drag = .turn(from: s) }
        case let .handle(x, y): if let s = selection { drag = .resize(sx: x, sy: y, from: s) }
        case .inside: if let s = selection { drag = .move(start: c, from: s); NSCursor.closedHand.set() }
        case .outside: drag = .draw(start: clampToImage(c), before: selection)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, scan != nil else { return }
        let p = location(event)
        let c = toContent(p)
        let minSize = max(4, 6 / scale)
        switch drag {
        case let .pan(last):
            pan(byView: CGSize(width: p.x - last.x, height: p.y - last.y))
            self.drag = .pan(last: p)
            return

        case let .draw(start, before):
            let angle = before?.straighten ?? 0
            let b = clampToImage(c)
            if angle == 0 {
                selection = Selection(rect: CGRect(x: min(start.x, b.x), y: min(start.y, b.y),
                                                   width: max(abs(b.x - start.x), 1), height: max(abs(b.y - start.y), 1)))
            } else {
                // Draw in the turned frame so the frame keeps its angle.
                let l = (b - start).rotated(degrees: -angle)
                let center = start + (l * 0.5).rotated(degrees: angle)
                selection = Selection(rect: CGRect(centerX: center.x, centerY: center.y, width: max(abs(l.x), 1), height: max(abs(l.y), 1)),
                                      straighten: angle)
            }

        case let .move(start, from):
            var s = from
            s.rect = s.rect.offsetBy(dx: c.x - start.x, dy: c.y - start.y)
            selection = keepOnImage(s)

        case let .resize(sx, sy, from):
            let l = local(c, in: from)
            var x0 = -from.rect.width / 2, x1 = from.rect.width / 2
            var y0 = -from.rect.height / 2, y1 = from.rect.height / 2
            if sx < 0 { x0 = min(l.x, x1 - minSize) } else if sx > 0 { x1 = max(l.x, x0 + minSize) }
            if sy < 0 { y0 = min(l.y, y1 - minSize) } else if sy > 0 { y1 = max(l.y, y0 + minSize) }
            let center = fromLocal(CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2), in: from)
            var s = Selection(rect: CGRect(centerX: center.x, centerY: center.y, width: x1 - x0, height: y1 - y0), straighten: from.straighten)
            if s.straighten == 0 { s.rect = s.rect.intersection(imageRect) }
            if s.rect.width >= 1 && s.rect.height >= 1 { selection = s }

        case let .turn(from):
            let d = c - from.rect.center
            var angle = atan2(d.y, d.x) * 180 / .pi + 90
            if angle > 180 { angle -= 360 }
            if event.modifierFlags.contains(.shift) { angle = angle.rounded() }
            else if abs(angle) < 0.4 { angle = 0 }
            angle = min(max(angle, -Clip.maxStraightenDegrees), Clip.maxStraightenDegrees)
            var s = from
            s.straighten = (angle * 100).rounded() / 100
            selection = keepOnImage(s)
        }
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        if case let .draw(_, before) = d, let s = selection, s.rect.width * scale < 4 || s.rect.height * scale < 4 {
            // A click rather than a drag: keep what was there.
            selection = before
        }
        if case .pan = d {} else if let s = selection { onChange?(s) }
        overlay.needsDisplay = true
        updateCursor(location(event))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(location(event)) }

    override func cursorUpdate(with event: NSEvent) { updateCursor(location(event)) }

    private func updateCursor(_ p: CGPoint) {
        guard drag == nil, scan != nil else { return }
        switch hit(p) {
        case .knob: NSCursor.pointingHand.set()
        case let .handle(x, y):
            if x != 0 && y != 0 { NSCursor.crosshair.set() }
            else if x != 0 { NSCursor.resizeLeftRight.set() }
            else { NSCursor.resizeUpDown.set() }
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.crosshair.set()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard var s = selection else { return super.keyDown(with: event) }
        let fine = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control)
        switch event.charactersIgnoringModifiers {
        case "[", "]":
            let step = (fine ? 0.1 : 1) * (event.charactersIgnoringModifiers == "]" ? 1 : -1)
            s.straighten = min(max(((s.straighten + step) * 100).rounded() / 100, -Clip.maxStraightenDegrees), Clip.maxStraightenDegrees)
            selection = keepOnImage(s)
            onChange?(selection!)
            overlay.needsDisplay = true
        case "\r", "\u{3}":
            onPlace?()
        default:
            if let arrow = arrowDelta(event) {
                s.rect = s.rect.offsetBy(dx: arrow.x, dy: arrow.y)
                selection = keepOnImage(s)
                onChange?(selection!)
                overlay.needsDisplay = true
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func arrowDelta(_ event: NSEvent) -> CGPoint? {
        let step = (event.modifierFlags.contains(.shift) ? 20 : 2) / scale
        switch event.keyCode {
        case 123: return CGPoint(x: -step, y: 0)
        case 124: return CGPoint(x: step, y: 0)
        case 125: return CGPoint(x: 0, y: step)
        case 126: return CGPoint(x: 0, y: -step)
        default: return nil
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), contentSize.width), y: min(max(p.y, 0), contentSize.height))
    }

    /// A level frame stays inside the scan; a turned one may reach past it but keeps its centre on it.
    private func keepOnImage(_ s: Selection) -> Selection {
        var s = s
        if s.straighten == 0 {
            let w = min(s.rect.width, contentSize.width), h = min(s.rect.height, contentSize.height)
            s.rect = CGRect(x: min(max(s.rect.minX, 0), contentSize.width - w), y: min(max(s.rect.minY, 0), contentSize.height - h),
                            width: w, height: h)
        } else {
            let c = clampToImage(s.rect.center)
            s.rect = CGRect(centerX: c.x, centerY: c.y, width: s.rect.width, height: s.rect.height)
        }
        return s
    }

    // MARK: Drawing

    override func drawOverlay() {
        guard let ctx = NSGraphicsContext.current?.cgContext, let scan, let s = selection else { return }
        let pts = corners(s)

        // Dim everything outside the selection.
        ctx.saveGState()
        ctx.addRect(contentRectInView)
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        var turning = false
        if case .turn = drag { turning = true }
        if turning || s.straighten != 0 {
            // Thirds grid, to line content up against while straightening.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(turning ? 0.55 : 0.25).cgColor)
            ctx.setLineWidth(0.75)
            for t in [1.0 / 3, 2.0 / 3] {
                ctx.move(to: pts[0] + (pts[1] - pts[0]) * t)
                ctx.addLine(to: pts[3] + (pts[2] - pts[3]) * t)
                ctx.move(to: pts[0] + (pts[3] - pts[0]) * t)
                ctx.addLine(to: pts[1] + (pts[2] - pts[1]) * t)
            }
            ctx.strokePath()
        }

        OverlayStyle.strokeOutline(pts, in: ctx)
        let k = knob(s)
        OverlayStyle.turnKnob(from: k.edge, to: k.knob, in: ctx)
        for i in 0..<4 {
            OverlayStyle.handle(at: pts[i], in: ctx)
            OverlayStyle.handle(at: (pts[i] + pts[(i + 1) % 4]) * 0.5, in: ctx, radius: 3.5)
        }

        let w = Units.pixelsToMm(s.rect.width, dpi: scan.dpi), h = Units.pixelsToMm(s.rect.height, dpi: scan.dpi)
        var text = "\(Units.format(w)) × \(Units.format(h)) mm"
        if s.straighten != 0 || turning { text += "  ↻ \(AppModel.formatAngle(s.straighten))" }
        let bottom = pts.max { $0.y < $1.y }!
        let cx = pts.map(\.x).reduce(0, +) / 4
        OverlayStyle.label(text, at: CGPoint(x: cx, y: bottom.y + 10), bounds: bounds)
    }
}
