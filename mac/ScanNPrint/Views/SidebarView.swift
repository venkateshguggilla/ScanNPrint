import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let scanner = model.scanner
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    label("Scanner")
                    Picker("Scanner", selection: Binding(
                        get: { scanner.selected?.name ?? "" },
                        set: { model.selectScanner(named: $0) })) {
                        if scanner.scanners.isEmpty { Text("None found").tag("") }
                        ForEach(scanner.scanners, id: \.self) { s in Text(s.name ?? "Scanner").tag(s.name ?? "") }
                    }
                    .labelsHidden()
                    .disabled(scanner.scanners.isEmpty || scanner.isScanning)
                }
                GridRow {
                    label("Source")
                    Picker("Source", selection: $model.scanSource) {
                        ForEach(model.sourceOptions) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Resolution")
                    Picker("Resolution", selection: $model.dpi) {
                        ForEach(model.resolutionOptions, id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Color")
                    Picker("Color", selection: $model.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Scan area")
                    Picker("Scan area", selection: $model.scanAreaName) {
                        Text("Whole glass").tag("")
                        ForEach(PaperSize.standard) { Text($0.label).tag($0.name) }
                    }
                    .labelsHidden()
                    .disabled(model.scanSource != .flatbed)
                }
                GridRow {
                    label("Printer")
                    Picker("Printer", selection: $model.printerName) {
                        if model.printers.isEmpty { Text("None found").tag(String?.none) }
                        ForEach(model.printers, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .disabled(model.printers.isEmpty)
                }
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                if scanner.isScanning {
                    Button(role: .cancel) { scanner.cancel() } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Cancel")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button { model.scan() } label: {
                        Label("Scan", systemImage: "scanner").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!scanner.isReady)
                    .help("Scan with the settings above (⌘R)")
                }
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.large)
                    .help("Look for scanners and printers again")
                    .disabled(scanner.isScanning)
            }
            .padding(.top, 12)

            Text(scanner.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 6)

            Divider().padding(.vertical, 10)

            HStack {
                Text("Scans").font(.headline)
                if !model.scans.isEmpty {
                    Text("\(model.scans.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.importImages(Dialogs.openImages()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Import images or PDFs to use like scans (⌘I)")
            }
            .padding(.bottom, 4)

            ScanList()
        }
        .padding([.horizontal, .top], 12)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

private struct ScanList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selectedScan?.id }, set: { model.selectedScanID = $0 })) {
            ForEach(model.scans) { scan in
                ScanRow(scan: scan)
                    .tag(scan.id)
                    .contextMenu {
                        Button("Select an Area…") {
                            model.selectedScanID = scan.id
                            model.mode = .compose
                        }
                        Button("Save Scan…") { model.exportScans([scan]) }
                        Button("Print Scan…") { model.printScans([scan]) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteScan(scan.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -12)
        .onDeleteCommand { if let id = model.selectedScan?.id { model.deleteScan(id) } }
        .dropDestination(for: URL.self) { urls, _ in
            model.importImages(urls)
            return true
        }
        .overlay {
            if model.scans.isEmpty {
                Text("Scanned pages appear here.\nYou can also drop images or PDFs here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

private struct ScanRow: View {
    let scan: ScannedPage

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: scan.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 56)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name).fontWeight(.medium)
                Text(scan.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
