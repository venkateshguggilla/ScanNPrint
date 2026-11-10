import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let scanNPrintProject = UTType(exportedAs: "com.venky.scannprint.project", conformingTo: .data)
}

/// Open and save panels and alerts.
enum Dialogs {
    enum SaveChoice { case save, discard, cancel }

    static func openProject() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.allowedContentTypes = [.scanNPrintProject]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Import Images"
        panel.message = "Choose photos, scans or PDFs to use like scans."
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveProject(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.message = "A project keeps the scans and the layout, so you can carry on later."
        panel.allowedContentTypes = [.scanNPrintProject]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A save panel with a format menu. Returns the file and the format chosen.
    static func saveExport(title: String, name: String) -> (URL, ExportFormat)? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.canSelectHiddenExtension = true

        let defaults = UserDefaults.standard
        var format = ExportFormat(rawValue: defaults.string(forKey: "exportFormat") ?? "") ?? .pdf
        panel.allowedContentTypes = [format.type]

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ExportFormat.allCases.map(\.title))
        popup.selectItem(at: ExportFormat.allCases.firstIndex(of: format) ?? 0)
        let handler = FormatHandler { index in
            format = ExportFormat.allCases[index]
            panel.allowedContentTypes = [format.type]
        }
        popup.target = handler
        popup.action = #selector(FormatHandler.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let note = NSTextField(labelWithString: "PNG and JPEG save one file per page.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [label, popup, note])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row

        let result = panel.runModal()
        _ = handler
        guard result == .OK, let url = panel.url else { return nil }
        defaults.set(format.rawValue, forKey: "exportFormat")
        return (url, format)
    }

    static func askToSave(name: String?) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = name.map { "Do you want to save the changes to “\($0)”?" } ?? "Do you want to save this project?"
        alert.informativeText = "Your scans and layout will be lost if you don't save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    static func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private final class FormatHandler: NSObject {
    let onChange: (Int) -> Void

    init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }

    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}
