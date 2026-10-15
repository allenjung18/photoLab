import SwiftUI
import AppKit

@main
struct PhotoLabApp: App {
    @State private var library = Library()
    @State private var presets = PresetLibrary()
    @State private var exports = ExportQueue(remember: true)
    /// The launch open runs once: a window re-created later (the last one
    /// closed, then the Dock icon) must not reopen the argument and wipe the
    /// selection and history.
    @State private var launched = false

    init() {
        // Running from `swift run` has no bundle; make the process a real
        // foreground app so the window and menu bar appear.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("PhotoLab") {
            ContentView()
                .environment(library)
                .environment(presets)
                .environment(exports)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    guard !launched else { return }
                    launched = true
                    // `PhotoLab <folder>` opens that folder; otherwise the last
                    // one. Flags (`-NSDocumentRevisionsDebugMode` from Xcode,
                    // `-psn_…` from Finder) are not paths and are skipped.
                    if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                        library.open(URL(fileURLWithPath: arg))
                    } else {
                        library.restoreLastFolder()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.chooseFolder() }
                    .keyboardShortcut("o")
            }
            // Export the selection (one photo in the loupe, the multi-selection
            // in the grid): the options sheet, then the queue.
            CommandGroup(replacing: .importExport) {
                Button(exportTitle) { export() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.batchTargets.isEmpty || exports.isRunning)
            }
            // Copy / paste a photo's settings; select every photo in the grid.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Settings") {
                    if let id = library.selection { library.copySettings(from: id) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(library.selection == nil)
                Button("Paste Settings…") { library.requestPaste() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(library.copiedSettings == nil || library.batchTargets.isEmpty)
                Button("Sync Settings…") { library.requestSync() }
                    .disabled(library.selectedIDs.count < 2)
                Divider()
                Button("Select All Photos") { library.selectAll() }
                    .keyboardShortcut("a")
                    .disabled(library.loupe || library.photos.isEmpty)
            }
            // Undo and redo act on the selected photo's edit history; there
            // are no text fields, so the window's own undo manager is unused.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { library.undo() }
                    .keyboardShortcut("z")
                    .disabled(!library.canUndo)
                Button("Redo") { library.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!library.canRedo)
            }
            CommandGroup(after: .undoRedo) {
                Divider()
                Button("Reset Photo") {
                    if let id = library.selection { library.resetRecipe(for: id) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library.selection.map { !library.isEdited($0) } ?? true)
            }
            // Presets: save the selected photo's look, or apply one by name to
            // the selection (every selected photo in the grid, one undo step).
            CommandMenu("Presets") {
                Button("Save Preset…") { presets.saveRequested = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!library.loupe || library.selection == nil)
                Divider()
                ForEach(presets.presets) { preset in
                    Button(preset.name) { library.apply(preset, to: library.batchTargets) }
                        .disabled(library.batchTargets.isEmpty)
                }
            }
        }
    }

    private var exportTitle: String {
        let n = library.batchTargets.count
        return n > 1 ? "Export \(n) Photos…" : "Export…"
    }

    private func export() {
        exports.requestExport(from: library)
    }
}
