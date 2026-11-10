import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 380)
        } detail: {
            VStack(spacing: 0) {
                switch model.mode {
                case .scans: ScanDetailView()
                case .compose: ComposerView()
                }
                if !model.status.isEmpty {
                    Divider()
                    StatusBar()
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Scans: check and save what you scanned. Compose: put parts of scans side by side on a page.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.mode == .compose {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!model.canUndo).help("Undo (⌘Z)")
                    Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
                }
                Button { model.openProject() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a project (⌘O)")
                Button { model.saveProject() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .help("Save the project: scans and layout, to carry on later (⌘S)")
                Button { model.exportCurrent() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help(model.mode == .compose ? "Save the output pages as PDF, PNG, JPEG or TIFF (⌘E)" : "Save the scans as PDF, PNG, JPEG or TIFF (⌘E)")
                    .disabled(model.mode == .scans ? model.scans.isEmpty : false)
                Button { model.printCurrent() } label: { Label("Print", systemImage: "printer") }
                    .help(model.mode == .compose ? "Print the output pages (⌘P)" : "Print the scans (⌘P)")
                    .disabled(model.mode == .scans ? model.scans.isEmpty : false)
            }
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !model.lastSaved.isEmpty && model.status.hasPrefix("Saved") {
                Button("Show in Finder") { model.revealLastSaved() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Button { model.status = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
