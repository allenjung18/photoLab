import SwiftUI

/// What a command acts on: the library, plus the preset and export stores
/// for the two commands that need them (Save Preset, Export). Tests build it
/// over a library alone.
@MainActor
struct CommandContext {
    let library: Library
    var presets: PresetLibrary? = nil
    var exports: ExportQueue? = nil
    /// A context menu on one photo pins what the commands act on: the
    /// targets (`Library.contextTargets(for:)`) and the one photo the
    /// single-photo commands (Copy Settings, Reset Photo) take. Nil for the
    /// menus and keys, which act on the batch targets and the anchor.
    var targetIDs: [Photo.ID]? = nil
    var subjectID: Photo.ID? = nil

    var targets: [Photo.ID] { targetIDs ?? library.batchTargets }
    var subject: Photo.ID? { subjectID ?? library.selection }
}

/// One key-driven action: its title, its key, the menu that lists it, when it
/// is enabled and what it does. `AppCommand.all` is the one table every key
/// in the app comes from: the menus (`CommandItems`) and the hidden shortcuts
/// (`HiddenShortcuts`) are both built from it, so a key is typed once, here.
///
/// A key with modifiers is bound on its menu item. A bare key (no modifiers)
/// is bound on `HiddenShortcuts` only and shown in its menu item's title: a
/// menu key equivalent is global to the app, so a bare one would fire while
/// the user types into a text field (the Save Preset name, the export
/// suffix); the hidden buttons live in the main window's view hierarchy and
/// never see a sheet's or an alert's keystrokes.
@MainActor
struct AppCommand: Identifiable {
    enum Name: String, CaseIterable {
        case openFolder, openPhotos, export, saveToPhotos
        case undo, redo
        case copySettings, pasteSettings, syncSettings, selectAll
        case savePreset
        case grid, loupe, zoom, compare, showOriginal, clipping, filmstrip, info, previous, next
        case pick, reject, unflag
        case rate0, rate1, rate2, rate3, rate4, rate5
        case crop, resetPhoto
        case sortCaptureDate, sortName, sortRating, sortEdited, sortAscending, sortDescending
        case back, open
    }

    /// The `CommandGroup` or `CommandMenu` an item sits in; `sort` is the
    /// View › Sort By submenu and the grid bar's Sort menu; `keysOnly` has no
    /// menu item (Escape, Return).
    enum Placement: CaseIterable {
        case newItem, importExport, undoRedo, pasteboard, presets, view, sort, photo, keysOnly

        /// The menu bar menu that lists the placement's items; nil for
        /// `keysOnly`.
        var menuTitle: String? {
            switch self {
            case .newItem, .importExport: "File"
            case .undoRedo, .pasteboard: "Edit"
            case .view, .sort: "View"
            case .photo: "Photo"
            case .presets: "Presets"
            case .keysOnly: nil
            }
        }

        /// True when the app adds that menu itself (`CommandMenu`, titled
        /// `menuTitle`). False when SwiftUI already supplies it: the items go
        /// into a `CommandGroup` of that menu, since a `CommandMenu` of a
        /// supplied menu's name is a second menu of that name beside it.
        var addsMenu: Bool { self == .photo || self == .presets }

        /// The menus SwiftUI supplies to a `WindowGroup` app with a toolbar
        /// (besides the app menu): never the title of a `CommandMenu`.
        static let suppliedMenus: Set<String> = ["File", "Edit", "View", "Window", "Help"]
    }

    let name: Name
    let title: String
    let key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let placement: Placement
    /// Items of one placement in different sections get a divider between.
    var section = 0
    /// A title that changes with the state (Export's photo count); `title`
    /// when nil.
    var dynamicTitle: (@MainActor (CommandContext) -> String)? = nil
    /// A checkmark in the menu (Grid, Loupe, the view toggles).
    var isOn: (@MainActor (CommandContext) -> Bool)? = nil
    var isEnabled: @MainActor (CommandContext) -> Bool = { _ in true }
    let perform: @MainActor (CommandContext) -> Void

    nonisolated var id: Name { name }

    /// No modifiers: bound on `HiddenShortcuts`, never on a menu item.
    var isBareKey: Bool { key != nil && modifiers.isEmpty }

    /// The menu item's title: a bare key is spelled out after the title,
    /// since it is not the item's key equivalent.
    func menuTitle(_ context: CommandContext) -> String {
        let base = dynamicTitle?(context) ?? title
        guard isBareKey, let key else { return base }
        return "\(base) (\(Self.label(for: key)))"
    }

    static func label(for key: KeyEquivalent) -> String {
        switch key {
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .return: return "↩"
        case .escape: return "⎋"
        default: return String(key.character).uppercased()
        }
    }

    static func command(_ name: Name) -> AppCommand {
        all.first { $0.name == name }!
    }

    static func items(in placement: Placement) -> [AppCommand] {
        all.filter { $0.placement == placement }
    }

    // MARK: The table

    static let all: [AppCommand] = [
        // File
        AppCommand(name: .openFolder, title: "Open Folder…", key: "o", placement: .newItem,
                   perform: { $0.library.chooseFolder() }),
        AppCommand(name: .openPhotos, title: "Open Photos Library…", key: "o", modifiers: [.command, .shift],
                   placement: .newItem, perform: { $0.library.choosePhotosAlbum() }),
        // Export the selection (one photo in the loupe, the multi-selection
        // in the grid): the options sheet, then the queue.
        AppCommand(name: .export, title: "Export…", key: "e", modifiers: [.command, .shift],
                   placement: .importExport,
                   dynamicTitle: { c in
                       let n = c.targets.count
                       return n > 1 ? "Export \(n) Photos…" : "Export…"
                   },
                   isEnabled: { c in !c.targets.isEmpty && c.exports?.isRunning != true },
                   perform: { c in c.exports?.requestExport(from: c.library, ids: c.targets) }),
        // The selected photo's edit written into Photos itself (a Photos
        // album's edited photo only): Photos shows it and can revert it; the
        // export above makes a new asset instead.
        AppCommand(name: .saveToPhotos, title: "Save to Photos", key: nil, placement: .importExport,
                   isEnabled: { $0.library.canSaveToPhotos },
                   perform: { c in Task { await c.library.saveToPhotos() } }),

        // Edit: undo and redo act on the selected photo's edit history; there
        // are no text fields in the window, so its own undo manager is unused.
        AppCommand(name: .undo, title: "Undo", key: "z", placement: .undoRedo,
                   isEnabled: { $0.library.canUndo }, perform: { $0.library.undo() }),
        AppCommand(name: .redo, title: "Redo", key: "z", modifiers: [.command, .shift], placement: .undoRedo,
                   isEnabled: { $0.library.canRedo }, perform: { $0.library.redo() }),
        // Copy / paste a photo's settings; select every photo in the grid.
        AppCommand(name: .copySettings, title: "Copy Settings", key: "c", modifiers: [.command, .shift],
                   placement: .pasteboard,
                   isEnabled: { $0.subject != nil },
                   perform: { c in if let id = c.subject { c.library.copySettings(from: id) } }),
        AppCommand(name: .pasteSettings, title: "Paste Settings…", key: "v", modifiers: [.command, .shift],
                   placement: .pasteboard,
                   isEnabled: { c in c.library.copiedSettings != nil && !c.targets.isEmpty },
                   perform: { $0.library.requestPaste(for: $0.targets) }),
        AppCommand(name: .syncSettings, title: "Sync Settings…", key: nil, placement: .pasteboard,
                   isEnabled: { $0.library.selectedIDs.count >= 2 },
                   perform: { $0.library.requestSync() }),
        AppCommand(name: .selectAll, title: "Select All Photos", key: "a", placement: .pasteboard, section: 1,
                   isEnabled: { c in !c.library.loupe && !c.library.photos.isEmpty },
                   perform: { $0.library.selectAll() }),

        // Presets: save the selected photo's look (the menu then lists every
        // preset, applied to the selection; those have no key).
        AppCommand(name: .savePreset, title: "Save Preset…", key: "p", modifiers: [.command, .shift],
                   placement: .presets,
                   isEnabled: { c in c.library.loupe && c.library.selection != nil },
                   perform: { $0.presets?.saveRequested = true }),

        // View: Lightroom's G / E and Z, the before/after keys, the clipping
        // warning, and the arrows that move the selection.
        AppCommand(name: .grid, title: "Grid", key: "g", modifiers: [], placement: .view,
                   isOn: { !$0.library.loupe },
                   perform: { $0.library.loupe = false }),
        AppCommand(name: .loupe, title: "Loupe", key: "e", modifiers: [], placement: .view,
                   isOn: { $0.library.loupe },
                   isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { enterLoupe($0.library) }),
        // Fit or 1:1 at the middle of the photo, in the loupe only (a click
        // on the photo zooms at that point instead).
        AppCommand(name: .zoom, title: "Zoom to 1:1", key: "z", modifiers: [], placement: .view,
                   isOn: { c in c.library.loupe && c.library.loupeZoom != .fit },
                   isEnabled: { c in c.library.loupe && c.library.selection != nil },
                   perform: { $0.library.toggleZoom() }),
        // Before and After side by side; from the grid it opens the loupe.
        AppCommand(name: .compare, title: "Before and After", key: "y", modifiers: [], placement: .view, section: 1,
                   isOn: { c in c.library.compare && c.library.loupe },
                   isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { c in
                       let lib = c.library
                       if lib.loupe { lib.compare.toggle() } else { lib.compare = true; enterLoupe(lib) }
                   }),
        AppCommand(name: .showOriginal, title: "Show Original", key: "\\", modifiers: [], placement: .view,
                   section: 1, isOn: { $0.library.showBefore },
                   perform: { $0.library.showBefore.toggle() }),
        AppCommand(name: .clipping, title: "Clipping Warning", key: "j", modifiers: [], placement: .view,
                   section: 1, isOn: { $0.library.showClipping },
                   perform: { $0.library.showClipping.toggle() }),
        AppCommand(name: .filmstrip, title: "Filmstrip", key: "f", modifiers: [], placement: .view,
                   section: 1, isOn: { $0.library.showFilmstrip },
                   perform: { $0.library.showFilmstrip.toggle() }),
        // The loupe panel's Info section; from the grid it opens the loupe
        // with the section shown.
        AppCommand(name: .info, title: "Info", key: "i", placement: .view, section: 1,
                   isOn: { c in c.library.showInfo && c.library.loupe },
                   isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { c in
                       let lib = c.library
                       if lib.loupe { lib.showInfo.toggle() } else { lib.showInfo = true; enterLoupe(lib) }
                   }),
        AppCommand(name: .previous, title: "Previous Photo", key: .leftArrow, modifiers: [], placement: .view,
                   section: 2, isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { $0.library.select(offset: -1) }),
        AppCommand(name: .next, title: "Next Photo", key: .rightArrow, modifiers: [], placement: .view,
                   section: 2, isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { $0.library.select(offset: 1) }),

        // Photo: flag and rate the batch targets (every selected photo in
        // the grid, the one photo in the loupe), then Crop and Reset Photo.
        flag(.pick, title: "Pick", key: "p"),
        flag(.reject, title: "Reject", key: "x"),
        flag(nil, title: "Unflag", key: "u"),
        rate(0), rate(1), rate(2), rate(3), rate(4), rate(5),
        // Crop mode: the crop's handles on the photo, in the loupe only
        // (Lightroom's R). Esc leaves it as well (Back).
        AppCommand(name: .crop, title: "Crop", key: "r", modifiers: [], placement: .photo, section: 2,
                   isOn: { c in c.library.loupe && c.library.cropMode },
                   isEnabled: { c in c.library.loupe && c.library.selection != nil },
                   perform: { $0.library.cropMode.toggle() }),
        AppCommand(name: .resetPhoto, title: "Reset Photo", key: "r", modifiers: [.command, .shift],
                   placement: .photo, section: 2,
                   isEnabled: { c in c.subject.map { c.library.isEdited($0) } ?? false },
                   perform: { c in if let id = c.subject { c.library.resetRecipe(for: id) } }),

        // Sort By: the key (one checked), then the direction. No keys.
        sort(.captureDate, name: .sortCaptureDate),
        sort(.name, name: .sortName),
        sort(.rating, name: .sortRating),
        sort(.edited, name: .sortEdited),
        AppCommand(name: .sortAscending, title: "Ascending", key: nil, placement: .sort, section: 1,
                   isOn: { $0.library.sort.ascending },
                   isEnabled: { $0.library.source != nil },
                   perform: { $0.library.sort.ascending = true }),
        AppCommand(name: .sortDescending, title: "Descending", key: nil, placement: .sort, section: 1,
                   isOn: { !$0.library.sort.ascending },
                   isEnabled: { $0.library.source != nil },
                   perform: { $0.library.sort.ascending = false }),

        // Keys with no menu item: Escape leaves crop mode, else the loupe
        // (from the grid it collapses the selection), Return opens it. Return is enabled only
        // when there is a photo to open, as Loupe (E) is: the Welcome view
        // has none, and its Open Folder… button holds Return there.
        AppCommand(name: .back, title: "Back", key: .escape, modifiers: [], placement: .keysOnly,
                   perform: { c in
                       if c.library.cropMode {
                           c.library.cropMode = false
                       } else if c.library.loupe {
                           c.library.loupe = false
                       } else {
                           c.library.collapseSelection()
                       }
                   }),
        AppCommand(name: .open, title: "Open in Loupe", key: .return, modifiers: [], placement: .keysOnly,
                   isEnabled: { !$0.library.visiblePhotos.isEmpty },
                   perform: { enterLoupe($0.library) }),
    ]

    private static func sort(_ key: SortKey, name: Name) -> AppCommand {
        AppCommand(name: name, title: key.label, key: nil, placement: .sort,
                   isOn: { $0.library.sort.key == key },
                   isEnabled: { $0.library.source != nil },
                   perform: { $0.library.sort.key = key })
    }

    private static func flag(_ flag: Marks.Flag?, title: String, key: KeyEquivalent) -> AppCommand {
        let name: Name = switch flag { case .pick: .pick; case .reject: .reject; case nil: .unflag }
        return AppCommand(name: name, title: title, key: key, modifiers: [], placement: .photo,
                          isEnabled: { !$0.targets.isEmpty },
                          perform: { $0.library.setFlag(flag, for: $0.targets) })
    }

    private static func rate(_ n: Int) -> AppCommand {
        let names: [Name] = [.rate0, .rate1, .rate2, .rate3, .rate4, .rate5]
        let title = n == 0 ? "No Rating" : n == 1 ? "1 Star" : "\(n) Stars"
        return AppCommand(name: names[n], title: title, key: KeyEquivalent(Character(String(n))), modifiers: [],
                          placement: .photo, section: 1,
                          isEnabled: { !$0.targets.isEmpty },
                          perform: { $0.library.setRating(n, for: $0.targets) })
    }

    /// The loupe on the selection, or on the first visible photo when none.
    private static func enterLoupe(_ library: Library) {
        if library.selection == nil { library.selection = library.visiblePhotos.first?.id }
        library.loupe = library.selection != nil
    }
}

/// The menu items of one placement, in table order, a divider between
/// sections.
struct CommandItems: View {
    let placement: AppCommand.Placement
    let context: CommandContext

    var body: some View {
        let items = AppCommand.items(in: placement)
        ForEach(Array(items.enumerated()), id: \.element.id) { i, command in
            if i > 0, items[i - 1].section != command.section { Divider() }
            CommandMenuItem(command: command, context: context)
        }
    }
}

/// One menu item: a checkable toggle when the command has a state, a button
/// otherwise; the key equivalent only when the key has modifiers.
struct CommandMenuItem: View {
    let command: AppCommand
    let context: CommandContext

    var body: some View {
        Group {
            if let isOn = command.isOn {
                Toggle(command.menuTitle(context), isOn: Binding(
                    get: { isOn(context) },
                    set: { _ in command.perform(context) }))
            } else {
                Button(command.menuTitle(context)) { command.perform(context) }
            }
        }
        .modifier(MenuKey(command: command))
        .disabled(!command.isEnabled(context))
    }
}

private struct MenuKey: ViewModifier {
    let command: AppCommand

    func body(content: Content) -> some View {
        if let key = command.key, !command.isBareKey {
            content.keyboardShortcut(key, modifiers: command.modifiers)
        } else {
            content
        }
    }
}

/// The bare keys (`AppCommand.isBareKey`), as hidden zero-size buttons in the
/// main window so they work whatever has focus there and never reach a sheet
/// or an alert's text field.
struct HiddenShortcuts: View {
    @Environment(Library.self) private var library

    static var commands: [AppCommand] { AppCommand.all.filter(\.isBareKey) }

    var body: some View {
        let context = CommandContext(library: library)
        Group {
            ForEach(Self.commands) { command in
                Button("") { command.perform(context) }
                    .keyboardShortcut(command.key!, modifiers: command.modifiers)
                    .disabled(!command.isEnabled(context))
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
