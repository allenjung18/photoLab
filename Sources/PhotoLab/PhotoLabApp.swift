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
                        library.restoreLastSource()
                    }
                }
        }
        .commands {
            // Every item and key comes from `AppCommand.all` (Commands.swift);
            // the bare keys are bound on `HiddenShortcuts` and only named here.
            CommandGroup(replacing: .newItem) { CommandItems(placement: .newItem, context: context) }
            CommandGroup(replacing: .importExport) { CommandItems(placement: .importExport, context: context) }
            CommandGroup(replacing: .undoRedo) { CommandItems(placement: .undoRedo, context: context) }
            CommandGroup(after: .pasteboard) {
                Divider()
                CommandItems(placement: .pasteboard, context: context)
            }
            CommandMenu("View") { CommandItems(placement: .view, context: context) }
            CommandMenu("Photo") { CommandItems(placement: .photo, context: context) }
            // Presets: save the selected photo's look, or apply one by name to
            // the selection (every selected photo in the grid, one undo step).
            CommandMenu("Presets") {
                CommandItems(placement: .presets, context: context)
                Divider()
                ForEach(presets.presets) { preset in
                    Button(preset.name) { library.apply(preset, to: library.batchTargets) }
                        .disabled(library.batchTargets.isEmpty)
                }
            }
        }
    }

    private var context: CommandContext {
        CommandContext(library: library, presets: presets, exports: exports)
    }
}
