import SwiftUI

/// Side-by-side composing: select an area of a scan on the left, arrange it on the output page on the right.
struct ComposerView: View {
    var body: some View {
        HSplitView {
            SelectPane()
                .frame(minWidth: 300, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            ArrangePane()
                .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PaneHeader<Trailing: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }
}

private struct SelectPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.selectedScan
        VStack(spacing: 0) {
            PaneHeader(number: 1, title: "Select an area") {
                if let scan {
                    Text(scan.name).foregroundStyle(.secondary)
                }
            }
            Divider()
            ZStack {
                CropSelector(scan: scan, selection: scan.map(model.selection(for:)), model: model)
                if scan == nil {
                    ContentUnavailableView("No scan to select from", systemImage: "crop",
                                           description: Text("Scan a page or import an image, then select the part you want."))
                }
            }
            Divider()
            controls(scan)
                .padding(12)
                .background(.bar)
                .disabled(scan == nil)
        }
    }

    @ViewBuilder
    private func controls(_ scan: ScannedPage?) -> some View {
        let straighten = Binding(
            get: { model.currentSelection?.straighten ?? 0 },
            set: { model.setStraighten(($0 * 100).rounded() / 100) })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.selectWholePage() } label: { Label("Whole Page", systemImage: "rectangle.dashed") }
                    .help("Select the entire scan (⇧⌘A)")
                Button { model.autoDetect() } label: {
                    HStack(spacing: 5) {
                        if model.isDetecting { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                        Text("Auto-detect")
                    }
                }
                .disabled(model.isDetecting)
                .help("Select what's on the glass, ignoring the empty background, and straighten it if it's crooked (⌘D)")
                Spacer()
                if let scan {
                    Text(model.selectionDescription(for: scan))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("Straighten").foregroundStyle(.secondary)
                Slider(value: straighten, in: -45...45)
                    .controlSize(.small)
                    .help("Turn the frame to match crooked content. Drag the knob above the frame, or press [ and ].")
                TextField("Angle", value: straighten, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 54)
                Text("°").foregroundStyle(.secondary)
                Button { model.setStraighten(0) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(straighten.wrappedValue == 0)
                    .help("Level")
            }
            Button { model.place() } label: {
                Label("Place on Page", systemImage: "arrow.right.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Put the selected area on the output page at actual size (Return, or double-click the selection)")
        }
    }
}

private struct ArrangePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.currentPage
        VStack(spacing: 0) {
            PaneHeader(number: 2, title: "Arrange") {
                Picker("Paper", selection: Binding(
                    get: { page.paper?.name ?? "" },
                    set: { name in if let p = PaperSize.named(name) { model.setPaper(p, landscape: page.isLandscape) } })) {
                    if page.paper == nil { Text("Custom").tag("") }
                    ForEach(PaperSize.standard) { Text($0.label).tag($0.name) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Output page size")
                Toggle("Landscape", isOn: Binding(
                    get: { page.isLandscape },
                    set: { model.setPaper(page.paper ?? PaperSize(name: "", widthMm: min(page.widthMm, page.heightMm),
                                                                  heightMm: max(page.widthMm, page.heightMm)), landscape: $0) }))
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)
            Divider()
            PageCanvas(page: page, scans: model.scansByID, selectedClipID: model.selectedClipID, model: model)
            Divider()
            footer(page)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    @ViewBuilder
    private func footer(_ page: ComposedPage) -> some View {
        let count = model.composition.pages.count
        HStack(spacing: 6) {
            Button { model.goToPage(model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0).help("Previous page")
            Text("Page \(model.pageIndex + 1) of \(count)")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 80)
            Button { model.goToPage(model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex >= count - 1).help("Next page")
            Button { model.addPage() } label: { Image(systemName: "plus.rectangle.portrait") }
                .help("Add an output page after this one")
            Button { model.deletePage() } label: { Image(systemName: "minus.rectangle.portrait") }
                .help(count == 1 ? "Clear this page" : "Remove this output page")
                .disabled(count == 1 && page.clips.isEmpty)

            Spacer(minLength: 12)

            ClipControls()
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
}

private struct ClipControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clip = model.selectedClip
        let percent = Binding(
            get: { ((clip?.scale ?? 1) * 1000).rounded() / 10 },
            set: { model.setSelectedScale($0 / 100) })
        HStack(spacing: 6) {
            Text("Print size").foregroundStyle(.secondary)
            TextField("Scale", value: percent, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .textFieldStyle(.roundedBorder)
            Text("%").foregroundStyle(.secondary)
            Button("100%") { model.setSelectedScale(1) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Back to actual size")
            Divider().frame(height: 16)
            Button { model.rotateSelected(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
            Button { model.rotateSelected(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
            Button { model.bringToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .help("Bring in front of overlapping areas")
            Button { model.deleteSelectedClip() } label: { Image(systemName: "trash") }.help("Remove from the page (⌫)")
        }
        .disabled(clip == nil)
    }
}
