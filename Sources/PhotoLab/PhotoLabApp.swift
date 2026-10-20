import SwiftUI
import AppKit

/// The last responder an action message reaches. Edit › Select All (⌘A, the
/// system's item) sends `selectAll:` down the responder chain: a focused
/// text field takes it and selects its text; otherwise it arrives here and
/// selects the photos (`AppCommand.Name.selectAll`, enabled as that command is).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var context: (() -> CommandContext)?

    @objc func selectAll(_ sender: Any?) {
        guard let context = context?() else { return }
        let command = AppCommand.command(.selectAll)
        if command.isEnabled(context) { command.perform(context) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(selectAll(_:)) else { return true }
        return context.map { AppCommand.command(.selectAll).isEnabled($0()) } ?? false
    }
}

@main
struct PhotoLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The one `AppSettings` (UserDefaults.standard): the library, the
    /// export queue and the importer remember into it, and the Settings window edits it.
    @State private var library: Library
    @State private var presets = PresetLibrary()
    @State private var exports: ExportQueue
    @State private var imports: Importer
    /// The launch open runs once: a window re-created later (the last one
    /// closed, then the Dock icon) must not reopen the argument and wipe the
    /// selection and history.
    @State private var launched = false

    init() {
        // A live tour (`LiveTour`) runs on settings of its own and a trash
        // inside its run directory; the stores already point there.
        let settings = LiveTour.isActive ? LiveTour.makeSettings() : AppSettings()
        let trasher: any FileTrasher = LiveTour.trasher ?? LiveFileTrasher()
        _library = State(initialValue: Library(settings: settings, collections: .app, style: StyleStore(), trasher: trasher))
        _exports = State(initialValue: ExportQueue(settings: settings))
        _imports = State(initialValue: Importer(settings: settings))
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
                .environment(imports)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    guard !launched else { return }
                    launched = true
                    let (library, presets, exports, imports) = (library, presets, exports, imports)
                    appDelegate.context = {
                        CommandContext(library: library, presets: presets, exports: exports, imports: imports)
                    }
                    if LiveTour.isActive {
                        LiveTour.start(library: library, presets: presets, exports: exports)
                        return
                    }
                    // `PhotoLab <folder>` opens that folder; otherwise the last
                    // one, unless Settings says not to (`restoreLastSource`).
                    // Flags (`-NSDocumentRevisionsDebugMode` from Xcode,
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
            CommandGroup(replacing: .newItem) {
                CommandItems(placement: .newItem, context: context, sections: 0..<1)
                OpenCollectionMenu().environment(library)
                OpenRecentMenu().environment(library)
                Divider()
                CommandItems(placement: .newItem, context: context, sections: 1..<Int.max)
            }
            CommandGroup(replacing: .importExport) { CommandItems(placement: .importExport, context: context) }
            CommandGroup(replacing: .undoRedo) { CommandItems(placement: .undoRedo, context: context) }
            CommandGroup(after: .pasteboard) {
                Divider()
                CommandItems(placement: .pasteboard, context: context)
            }
            // SwiftUI supplies the View menu (the toolbar items, Enter Full
            // Screen): the view items go into it, after the toolbar items,
            // so there is one View menu (`Placement.addsMenu`).
            CommandGroup(after: .toolbar) {
                Divider()
                CommandItems(placement: .view, context: context)
                Divider()
                ShowFilterMenu().environment(library)
                Menu("Sort By") { CommandItems(placement: .sort, context: context) }
            }
            CommandMenu(AppCommand.Placement.photo.menuTitle!) {
                CommandItems(placement: .photo, context: context, sections: 0..<4)
                Divider()
                AddToCollectionMenu(context: context).environment(library)
                CommandItems(placement: .photo, context: context, sections: 4..<Int.max)
            }
            // Presets: save the selected photo's look, or apply one by name to
            // the selection (every selected photo in the grid, one undo step).
            CommandMenu(AppCommand.Placement.presets.menuTitle!) {
                CommandItems(placement: .presets, context: context)
                Divider()
                ForEach(presets.presets) { preset in
                    Button(preset.name) { library.apply(preset, to: library.batchTargets) }
                        .disabled(library.batchTargets.isEmpty)
                }
            }
        }
        // PhotoLab › Settings… (⌘, from SwiftUI's Settings scene, not the
        // command table): the window over `library.settings`.
        Settings {
            SettingsView()
                .environment(library)
        }
    }

    private var context: CommandContext {
        CommandContext(library: library, presets: presets, exports: exports, imports: imports)
    }
}
