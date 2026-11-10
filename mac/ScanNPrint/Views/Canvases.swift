import SwiftUI

/// SwiftUI wrapper for the crop selector. The view keeps its own state while dragging and reports back on release.
struct CropSelector: NSViewRepresentable {
    let scan: ScannedPage?
    let selection: Selection?
    let model: AppModel

    func makeNSView(context: Context) -> CropSelectorView {
        let view = CropSelectorView(frame: .zero)
        view.onPlace = { model.place() }
        return view
    }

    func updateNSView(_ view: CropSelectorView, context: Context) {
        view.scan = scan
        view.setSelection(selection)
        let id = scan?.id
        view.onChange = { s in if let id { model.setSelection(s, for: id) } }
    }
}

struct PageCanvas: NSViewRepresentable {
    let page: ComposedPage
    let scans: [String: ScannedPage]
    let selectedClipID: UUID?
    let model: AppModel

    func makeNSView(context: Context) -> PageCanvasView {
        let view = PageCanvasView(frame: .zero)
        view.margin = AppModel.margin
        view.onSelect = { model.selectedClipID = $0 }
        view.onCommit = { model.commit($0) }
        view.onAction = { action in
            switch action {
            case .bringToFront: model.bringToFront()
            case .sendToBack: model.sendToBack()
            case .rotateLeft: model.rotateSelected(by: -90)
            case .rotateRight: model.rotateSelected(by: 90)
            case .actualSize: model.setSelectedScale(1)
            case .delete: model.deleteSelectedClip()
            }
        }
        return view
    }

    func updateNSView(_ view: PageCanvasView, context: Context) {
        view.scans = scans
        view.page = page
        view.selectedClipID = selectedClipID
    }
}
