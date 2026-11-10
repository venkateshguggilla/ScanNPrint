import SwiftUI

@main
struct ScanNPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("ScanNPrint", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        #if DEBUG
        DebugSnapshot.install()
        #endif
    }

    /// .snp projects and images opened from Finder, the Dock or "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.cleanUp()
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }
                .keyboardShortcut("n")
            Button("Open Project…") { model.openProject() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.saveProject() }
                .keyboardShortcut("s")
            Button("Save Project As…") { model.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Images…") { model.importImages(Dialogs.openImages()) }
                .keyboardShortcut("i")
            Button("Export…") { model.exportCurrent() }
                .keyboardShortcut("e")
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model.printCurrent() }
                .keyboardShortcut("p")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        CommandGroup(before: .toolbar) {
            Button("Scans") { model.mode = .scans }
                .keyboardShortcut("1")
            Button("Compose") { model.mode = .compose }
                .keyboardShortcut("2")
            Divider()
        }
        CommandMenu("Scan") {
            Button("Scan") { model.scan() }
                .keyboardShortcut("r")
                .disabled(!model.scanner.isReady || model.scanner.isScanning)
            Button("Look for Scanners and Printers Again") { model.refreshDevices() }
            Divider()
            Button("Select Whole Page") { model.mode = .compose; model.selectWholePage() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Auto-detect Content") { model.mode = .compose; model.autoDetect() }
                .keyboardShortcut("d")
            Button("Place on Page") { model.place() }
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
