import SwiftUI

/// The selected scan, large, with saving and printing.
struct ScanDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let scan = model.selectedScan {
            VStack(spacing: 0) {
                Image(decorative: scan.preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scan.name).fontWeight(.semibold)
                        Text("\(scan.sizeDescription) · \(scan.pixelWidth) × \(scan.pixelHeight) px")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.deleteScan(scan.id) } label: { Image(systemName: "trash") }
                        .help("Delete this scan (⌫)")
                    Picker("Print size", selection: $model.printSize) {
                        ForEach(PrintSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    Button("Save…") { model.exportScans([scan]) }
                        .help("Save this scan as PDF, PNG, JPEG or TIFF")
                    Button("Print…") { model.printScans([scan]) }
                        .help("Print this scan")
                    Button {
                        model.mode = .compose
                    } label: {
                        Label("Select an Area", systemImage: "crop")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Cut parts of this scan out and arrange them on a page")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView {
                Label("No scans yet", systemImage: "scanner")
            } description: {
                Text("Put a page on the scanner and select Scan.\nYou can also import images or PDFs (⌘I), or drop them on the scan list.")
            } actions: {
                Button("Import Images…") { model.importImages(Dialogs.openImages()) }
            }
        }
    }
}
