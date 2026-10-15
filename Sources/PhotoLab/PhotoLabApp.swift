import SwiftUI
import AppKit

@main
struct PhotoLabApp: App {
    @State private var library = Library()
    @State private var presets = PresetLibrary()

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
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    // `PhotoLab <folder>` opens that folder; otherwise the last one.
                    if let arg = CommandLine.arguments.dropFirst().first {
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
            // Presets: save the selected photo's look, or apply one by name.
            CommandMenu("Presets") {
                Button("Save Preset…") { presets.saveRequested = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!library.loupe || library.selection == nil)
                Divider()
                ForEach(presets.presets) { preset in
                    Button(preset.name) {
                        if let id = library.selection { library.apply(preset, to: id) }
                    }
                    .disabled(library.selection == nil)
                }
            }
        }
    }
}
