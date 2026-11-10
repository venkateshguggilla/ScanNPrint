#if DEBUG
import AppKit

/// Debug builds only: renders the main window to a PNG when another process posts
/// `com.venky.ScanNPrint.debug.snapshot` with the file path as the object. Used for checking the UI from scripts.
enum DebugSnapshot {
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.venky.ScanNPrint.debug.snapshot"),
                                                            object: nil, queue: .main) { note in
            guard let path = note.object as? String, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped == false && view.isFlipped {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                try? ImageFile.write([image], to: URL(fileURLWithPath: path), type: .png, dpi: 72 * scale)
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.venky.ScanNPrint.debug.command"),
                                                            object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            run(command)
        }
    }

    /// Scripted steps for exercising the app end to end.
    private static func run(_ command: String) {
        let model = AppModel.shared
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "mode-compose": model.mode = .compose
        case "mode-scans": model.mode = .scans
        case "detect": model.autoDetect()
        case "place": model.place()
        case "whole": model.selectWholePage()
        case "select-scan": if let n = Int(parts[1]), model.scans.indices.contains(n) { model.selectedScanID = model.scans[n].id }
        case "select-clip": if let n = Int(parts[1]), model.currentPage.clips.indices.contains(n) { model.selectedClipID = model.currentPage.clips[n].id }
        case "rotate": if let d = Double(parts[1]) { model.rotateSelected(by: d) }
        case "landscape": model.setPaper(model.currentPage.paper ?? .a4, landscape: true)
        case "undo": model.undo()
        case "export": if parts.count > 1 {
            let url = URL(fileURLWithPath: parts[1])
            _ = try? Exporter.export(model.composition, scans: model.scansByID, format: .from(url), to: url)
        }
        case "export-scans": if parts.count > 1 {
            let url = URL(fileURLWithPath: parts[1])
            _ = try? Exporter.export(model.scans, format: .from(url), to: url)
        }
        case "save-project": if parts.count > 1 {
            let url = URL(fileURLWithPath: parts[1])
            _ = try? ProjectFile.save(Project(scans: model.allScans.map {
                ProjectScan(id: $0.id, imageURL: $0.url, dpi: Int($0.dpi), pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                            inScanList: $0.inScanList, selection: nil)
            }, composition: model.composition), to: url, createdBy: "debug")
        }
        case "state":
            let page = model.currentPage
            let lines = ["mode=\(model.mode.rawValue) scans=\(model.scans.count) pages=\(model.composition.pages.count) page=\(Int(page.widthMm))x\(Int(page.heightMm))",
                         "selection=\(model.currentSelection.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height)) @\($0.straighten)" } ?? "-")"]
                + page.clips.map { "clip \(PageCanvasView.sizeText($0)) at \(Int($0.centerX)),\(Int($0.centerY)) straighten=\($0.straightenDegrees)" }
                + ["status=\(model.status)", "scanner=\(model.scanner.status) printers=\(model.printers)"]
            try? lines.joined(separator: "\n").write(toFile: parts.count > 1 ? parts[1] : "/tmp/snp-state.txt", atomically: true, encoding: .utf8)
        default: break
        }
    }
}
#endif
