import AppKit
import QuartzCore

enum ClipAction {
    case bringToFront, sendToBack, rotateLeft, rotateRight, actualSize, delete
}

/// An output page: drag placed areas to move them (they snap to the margins, the centre and each other),
/// drag a corner to resize, and drag the knob to turn them.
final class PageCanvasView: ZoomableCanvas {
    var onSelect: ((UUID?) -> Void)?
    var onCommit: ((Clip) -> Void)?
    var onAction: ((ClipAction) -> Void)?

    var scans: [String: ScannedPage] = [:]
    var margin = 5.0

    var page: ComposedPage? {
        didSet {
            guard page != oldValue, drag == nil else { return }
            contentSize = page?.size ?? .zero
            transformChanged()
        }
    }

    var selectedClipID: UUID? {
        didSet { if oldValue != selectedClipID { overlay.needsDisplay = true } }
    }

    private let paperLayer = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]
    private var images: [String: CGImage] = [:]

    private enum Drag {
        case move(start: CGPoint, from: Clip)
        case resize(corner: Int, from: Clip)
        case turn(from: Clip)
        case pan(last: CGPoint)
    }

    private var drag: Drag?
    private var live: Clip?
    private var guides: (x: Double?, y: Double?) = (nil, nil)
    private static let knobDistance: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        paperLayer.backgroundColor = NSColor.white.cgColor
        paperLayer.shadowOpacity = 0.3
        paperLayer.shadowRadius = 8
        paperLayer.shadowOffset = CGSize(width: 0, height: 3)
        paperLayer.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        paperLayer.borderWidth = 0.5
        paperLayer.masksToBounds = false
        stage.root.addSublayer(paperLayer)
    }

    /// The clips as shown, with the one being dragged in its live position.
    private var clips: [Clip] {
        guard let page else { return [] }
        guard let live else { return page.clips }
        return page.clips.map { $0.id == live.id ? live : $0 }
    }

    private var shownSelection: Clip? {
        if let live { return live }
        return selectedClipID.flatMap { page?.find($0) }
    }

    // MARK: Layers

    override func layoutStage() {
        guard page != nil else {
            paperLayer.isHidden = true
            clipLayers.values.forEach { $0.removeFromSuperlayer() }
            clipLayers = [:]
            return
        }
        paperLayer.isHidden = false
        paperLayer.frame = contentRectInView
        paperLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: paperLayer.bounds.size), transform: nil)

        var seen = Set<UUID>()
        for (i, clip) in clips.enumerated() {
            seen.insert(clip.id)
            let layer = clipLayers[clip.id] ?? makeClipLayer(clip.id)
            let key = imageKey(clip)
            if layer.name != key {
                layer.name = key
                layer.contents = image(for: clip)
            }
            layer.zPosition = CGFloat(i)
            layer.bounds = CGRect(x: 0, y: 0, width: clip.width * scale, height: clip.height * scale)
            layer.position = toView(clip.center)
            layer.setAffineTransform(CGAffineTransform(rotationAngle: clip.rotationDegrees * .pi / 180))
        }
        for (id, layer) in clipLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers[id] = nil
        }
    }

    private func makeClipLayer(_ id: UUID) -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.allowsEdgeAntialiasing = true
        layer.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerTopEdge, .layerBottomEdge]
        layer.backgroundColor = NSColor.white.cgColor
        stage.root.addSublayer(layer)
        clipLayers[id] = layer
        return layer
    }

    private func imageKey(_ c: Clip) -> String { "\(c.sourceID)|\(c.crop)|\(c.straightenDegrees)" }

    /// The clip cut from the scan's preview: sharp on screen, quick to make.
    private func image(for clip: Clip) -> CGImage? {
        let key = imageKey(clip)
        if let cached = images[key] { return cached }
        guard let scan = scans[clip.sourceID] else { return nil }
        let img = ClipRenderer.extract(from: scan.preview, scale: scan.previewScale, crop: clip.crop,
                                       straighten: clip.straightenDegrees, gray: scan.isGray)
        if images.count > 200 { images.removeAll() }
        images[key] = img
        return img
    }

    // MARK: Hit testing

    private func knob(_ c: Clip) -> (edge: CGPoint, knob: CGPoint) {
        let edge = toView(c.toPage(CGPoint(x: 0, y: -c.height / 2)))
        return (edge, edge + CGPoint(x: 0, y: -1).rotated(degrees: c.rotationDegrees) * Self.knobDistance)
    }

    private func clip(at viewPoint: CGPoint) -> Clip? {
        let p = toContent(viewPoint)
        return clips.last { $0.contains(p) }
    }

    private enum Hit { case knob(Clip), corner(Int, Clip), clip(Clip), none }

    private func hit(_ p: CGPoint) -> Hit {
        if let sel = shownSelection {
            if p.distance(to: knob(sel).knob) <= 10 { return .knob(sel) }
            for i in 0..<4 where p.distance(to: toView(sel.corner(i))) <= 8 { return .corner(i, sel) }
        }
        if let c = clip(at: p) { return .clip(c) }
        return .none
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard page != nil else { return }
        let p = location(event)
        if event.modifierFlags.contains(.control) && zoom > 1 {
            drag = .pan(last: p)
            return
        }
        switch hit(p) {
        case let .knob(c):
            drag = .turn(from: c)
        case let .corner(i, c):
            drag = .resize(corner: i, from: c)
        case let .clip(c):
            drag = .move(start: toContent(p), from: c)
            if selectedClipID != c.id {
                selectedClipID = c.id
                onSelect?(c.id)
            }
            NSCursor.closedHand.set()
        case .none:
            if selectedClipID != nil {
                selectedClipID = nil
                onSelect?(nil)
            }
            if zoom > 1 { drag = .pan(last: p) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let page else { return }
        let p = location(event)
        let c = toContent(p)
        let free = event.modifierFlags.contains(.option)
        switch drag {
        case let .pan(last):
            pan(byView: CGSize(width: p.x - last.x, height: p.y - last.y))
            self.drag = .pan(last: p)
            return

        case let .move(start, from):
            var moved = from.movedBy(dx: c.x - start.x, dy: c.y - start.y)
            guides = (nil, nil)
            if !free {
                let snap = Snapping.snapBox(moved.bounds,
                                            guidesX: Snapping.guidesX(page, margin: margin, excluding: from.id),
                                            guidesY: Snapping.guidesY(page, margin: margin, excluding: from.id),
                                            threshold: 6 / scale)
                moved = moved.movedBy(dx: snap.x.offset, dy: snap.y.offset)
                guides = (snap.x.guide, snap.y.guide)
            }
            live = moved

        case let .resize(corner, from):
            // Measured along the clip's own diagonal from the opposite corner, which stays put.
            let opposite = from.corner((corner + 2) % 4)
            let sx: Double = (corner == 1 || corner == 2) ? 1 : -1
            let sy: Double = corner >= 2 ? 1 : -1
            let v = (c - opposite).rotated(degrees: -from.rotationDegrees)
            let diagonal = CGPoint(x: sx * from.width, y: sy * from.height)
            let f = (v.x * diagonal.x + v.y * diagonal.y) / (diagonal.length * diagonal.length)
            var newScale = max(from.scale * f, 2 / min(from.naturalWidth, from.naturalHeight), 0.02)
            if !free && abs(newScale - 1) < 0.02 { newScale = 1 }
            let w = from.naturalWidth * newScale, h = from.naturalHeight * newScale
            let center = opposite + CGPoint(x: sx * w / 2, y: sy * h / 2).rotated(degrees: from.rotationDegrees)
            live = from.withScale(newScale).movedTo(x: center.x, y: center.y)

        case let .turn(from):
            let d = c - from.center
            var angle = atan2(d.y, d.x) * 180 / .pi + 90
            if event.modifierFlags.contains(.shift) {
                angle = (angle / 15).rounded() * 15
            } else if !free {
                let quarter = (angle / 90).rounded() * 90
                if abs(angle - quarter) < 3 { angle = quarter }
            }
            live = from.rotatedTo((angle * 10).rounded() / 10)
        }
        transformChanged()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        guides = (nil, nil)
        if let live, let page, page.find(live.id) != live {
            self.page = page.with(live) // show it in place until the model catches up
            self.live = nil
            onCommit?(live)
        }
        live = nil
        transformChanged()
        updateCursor(location(event))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(location(event)) }

    override func cursorUpdate(with event: NSEvent) { updateCursor(location(event)) }

    private func updateCursor(_ p: CGPoint) {
        guard drag == nil else { return }
        switch hit(p) {
        case .knob: NSCursor.pointingHand.set()
        case .corner: NSCursor.crosshair.set()
        case .clip: NSCursor.openHand.set()
        case .none: NSCursor.arrow.set()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = clip(at: location(event)) else { return nil }
        if selectedClipID != c.id {
            selectedClipID = c.id
            onSelect?(c.id)
        }
        let menu = NSMenu()
        let items: [(String, ClipAction)] = [
            ("Bring to Front", .bringToFront), ("Send to Back", .sendToBack), ("", .delete),
            ("Rotate Left", .rotateLeft), ("Rotate Right", .rotateRight), ("Actual Size", .actualSize), ("", .delete),
            ("Remove from Page", .delete),
        ]
        for (title, action) in items {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = MenuActionItem(title: title) { [weak self] in self?.onAction?(action) }
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let clip = shownSelection else { return super.keyDown(with: event) }
        let flags = event.modifierFlags
        switch event.keyCode {
        case 51, 117: onAction?(.delete); return // delete, forward delete
        case 53: selectedClipID = nil; onSelect?(nil); return // escape
        default: break
        }
        if let ch = event.charactersIgnoringModifiers, ch == "[" || ch == "]" {
            let step = flags.contains(.shift) ? 15 : (flags.contains(.option) || flags.contains(.control)) ? 0.1 : 1
            onCommit?(clip.rotatedBy(ch == "]" ? step : -step))
            return
        }
        let step = flags.contains(.shift) ? 5.0 : 0.5
        let delta: CGPoint? = switch event.keyCode {
        case 123: CGPoint(x: -step, y: 0)
        case 124: CGPoint(x: step, y: 0)
        case 125: CGPoint(x: 0, y: step)
        case 126: CGPoint(x: 0, y: -step)
        default: nil
        }
        if let delta { onCommit?(clip.movedBy(dx: delta.x, dy: delta.y)) } else { super.keyDown(with: event) }
    }

    // MARK: Drawing

    override func drawOverlay() {
        guard let ctx = NSGraphicsContext.current?.cgContext, let page else { return }
        let paper = contentRectInView

        // Margins, faintly.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.75)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.stroke(paper.insetBy(dx: margin * scale, dy: margin * scale))
        ctx.restoreGState()

        if page.clips.isEmpty {
            OverlayStyle.hint("Select an area of a scan on the left, then choose Place on Page.\nPlace as many as you like, from as many scans as you like.", in: paper)
        }

        // Snap guides.
        ctx.setStrokeColor(NSColor.systemPink.cgColor)
        ctx.setLineWidth(1)
        if let gx = guides.x {
            let x = toView(CGPoint(x: gx, y: 0)).x.rounded() + 0.5
            ctx.move(to: CGPoint(x: x, y: paper.minY))
            ctx.addLine(to: CGPoint(x: x, y: paper.maxY))
        }
        if let gy = guides.y {
            let y = toView(CGPoint(x: 0, y: gy)).y.rounded() + 0.5
            ctx.move(to: CGPoint(x: paper.minX, y: y))
            ctx.addLine(to: CGPoint(x: paper.maxX, y: y))
        }
        ctx.strokePath()

        guard let sel = shownSelection else { return }
        let pts = (0..<4).map { toView(sel.corner($0)) }
        OverlayStyle.strokeOutline(pts, in: ctx)
        let k = knob(sel)
        OverlayStyle.turnKnob(from: k.edge, to: k.knob, in: ctx)
        for p in pts { OverlayStyle.handle(at: p, in: ctx) }

        let bottom = pts.map(\.y).max()!
        let cx = pts.map(\.x).reduce(0, +) / 4
        OverlayStyle.label(Self.sizeText(sel), at: CGPoint(x: cx, y: bottom + 10), bounds: bounds)
    }

    static func sizeText(_ c: Clip) -> String {
        let w = c.isQuarterTurned ? c.height : c.width, h = c.isQuarterTurned ? c.width : c.height
        var text = "\(Units.format(w)) × \(Units.format(h)) mm · \(Int((c.scale * 100).rounded()))%"
        if c.rotationDegrees != 0 && !c.isQuarterTurned && c.rotationDegrees != 180 {
            text += " · ↻ \(AppModel.formatAngle(c.rotationDegrees))"
        }
        return text
    }
}

/// A menu item that runs a closure.
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
