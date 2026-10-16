import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The command table (`AppCommand.all`): every key is typed once, no two
/// commands share a key, the hidden shortcuts and the menus are both built
/// from it, and each command does what its title says.
@MainActor
final class CommandsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct Combo: Hashable, CustomStringConvertible {
        let key: Character
        let modifiers: Int
        var description: String { "\(key.unicodeScalars.map { String($0.value, radix: 16) }) mods \(modifiers)" }
    }

    private func combo(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> Combo {
        Combo(key: key.character, modifiers: modifiers.rawValue)
    }

    /// Keys the system's own menus hold (Quit, Close, Hide, Minimize,
    /// Settings, Cut, Copy, Paste): a table key on one of them is a collision.
    private var systemKeys: [Combo] {
        ["q", "w", "h", "m", ",", "x", "c", "v"].map { combo(KeyEquivalent(Character($0)), .command) }
    }

    // MARK: Keys

    func testEveryKeyAndModifiersIsUniqueAcrossTheTableAndTheSystemMenus() {
        var seen: [Combo: AppCommand.Name] = [:]
        for command in AppCommand.all {
            guard let key = command.key else { continue }
            let c = combo(key, command.modifiers)
            XCTAssertNil(seen[c], "\(command.name) shares \(c) with \(seen[c].map { "\($0)" } ?? "")")
            XCTAssertFalse(systemKeys.contains(c), "\(command.name) takes a system menu key \(c)")
            seen[c] = command.name
        }
        XCTAssertGreaterThan(seen.count, 25)
    }

    func testEveryNameIsInTheTableOnce() {
        let names = AppCommand.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(Set(names), Set(AppCommand.Name.allCases))
    }

    func testHiddenShortcutsAreTheTablesBareKeysAndKeepEveryKeyTheyHad() {
        XCTAssertEqual(HiddenShortcuts.commands.map(\.name), AppCommand.all.filter(\.isBareKey).map(\.name))
        XCTAssertTrue(HiddenShortcuts.commands.allSatisfy { $0.modifiers.isEmpty && $0.key != nil })
        let keys = Set(HiddenShortcuts.commands.map { $0.key!.character })
        let expected: [KeyEquivalent] = ["g", "e", "z", "y", "\\", "j", "f", "p", "x", "u",
                                         "0", "1", "2", "3", "4", "5", "r", "w",
                                         .return, .escape, .leftArrow, .rightArrow]
        XCTAssertEqual(keys, Set(expected.map(\.character)))
    }

    /// No hand-typed key outside the table: the only `.keyboardShortcut(`
    /// calls with a key in the sources are Commands.swift's; elsewhere only
    /// a sheet's default and cancel buttons.
    func testNoKeyIsTypedOutsideTheTable() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotoLab")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "Commands.swift" })
        for file in files where file.lastPathComponent != "Commands.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains(".keyboardShortcut(") {
                XCTAssertTrue(line.contains(".defaultAction") || line.contains(".cancelAction"),
                              "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    func testTheViewAndPhotoMenusListEveryBareKeyButEscapeAndReturn() {
        let view = AppCommand.items(in: .view).map(\.name)
        XCTAssertEqual(view, [.grid, .loupe, .zoom, .compare, .showOriginal, .clipping, .filmstrip, .info, .previous, .next])
        let photo = AppCommand.items(in: .photo).map(\.name)
        XCTAssertEqual(photo, [.pick, .reject, .unflag, .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .crop, .whiteBalance, .autoTone, .resetPhoto, .keywords])
        XCTAssertEqual(AppCommand.items(in: .keysOnly).map(\.name), [.back, .open])
        // The File, Edit and Presets items stay where they were.
        XCTAssertEqual(AppCommand.items(in: .newItem).map(\.name), [.openFolder, .openPhotos])
        XCTAssertEqual(AppCommand.items(in: .importExport).map(\.name), [.export, .saveToPhotos])
        XCTAssertEqual(AppCommand.items(in: .undoRedo).map(\.name), [.undo, .redo])
        XCTAssertEqual(AppCommand.items(in: .pasteboard).map(\.name),
                       [.copySettings, .pasteSettings, .syncSettings, .selectAll])
        XCTAssertEqual(AppCommand.items(in: .presets).map(\.name), [.savePreset])
    }

    func testABareKeyIsNamedInItsMenuTitleAndAModifiedOneIsNot() {
        let lib = Library(rememberFolder: false)
        let ctx = CommandContext(library: lib)
        XCTAssertEqual(AppCommand.command(.pick).menuTitle(ctx), "Pick (P)")
        XCTAssertEqual(AppCommand.command(.previous).menuTitle(ctx), "Previous Photo (←)")
        XCTAssertEqual(AppCommand.command(.showOriginal).menuTitle(ctx), "Show Original (\\)")
        XCTAssertEqual(AppCommand.command(.rate3).menuTitle(ctx), "3 Stars (3)")
        XCTAssertEqual(AppCommand.command(.zoom).menuTitle(ctx), "Zoom to 1:1 (Z)")
        XCTAssertEqual(AppCommand.command(.resetPhoto).menuTitle(ctx), "Reset Photo")
        XCTAssertEqual(AppCommand.command(.export).menuTitle(ctx), "Export…")
    }

    // MARK: Menus

    /// One View menu (UI-27): the view items go into the View menu SwiftUI
    /// supplies, never a `CommandMenu("View")` beside it. A placement the app
    /// adds a menu for has a title SwiftUI does not supply; every other one
    /// sits in a supplied menu.
    func testNoPlacementAddsASecondMenuOfASuppliedName() {
        XCTAssertEqual(AppCommand.Placement.view.menuTitle, "View")
        XCTAssertFalse(AppCommand.Placement.view.addsMenu, "the View items go into SwiftUI's own View menu")
        for placement in AppCommand.Placement.allCases {
            guard let title = placement.menuTitle else {
                XCTAssertEqual(placement, .keysOnly)
                continue
            }
            if placement.addsMenu {
                XCTAssertFalse(AppCommand.Placement.suppliedMenus.contains(title),
                               "\(placement) adds a second \(title) menu")
            } else {
                XCTAssertTrue(AppCommand.Placement.suppliedMenus.contains(title),
                              "\(placement) sits in \(title), which nothing supplies")
            }
        }
        let added = AppCommand.Placement.allCases.filter(\.addsMenu).compactMap(\.menuTitle)
        XCTAssertEqual(added, ["Presets", "Photo"])
    }

    /// The app's `.commands` take every `CommandMenu` title from the table, so
    /// the test above covers the menu bar: no literal title in the sources.
    func testEveryCommandMenuTitleComesFromTheTable() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotoLab")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var menus = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("CommandMenu(")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                menus += 1
                XCTAssertTrue(line.contains("CommandMenu(AppCommand.Placement."),
                              "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(menus, AppCommand.Placement.allCases.filter(\.addsMenu).count)
    }

    /// Return on the Welcome view is its Open Folder… (UI-28): the hidden
    /// Open in Loupe key is disabled while there is no photo to open, so the
    /// default button is the only Return.
    func testOpenInLoupeIsDisabledWithNoPhoto() throws {
        let empty = CommandContext(library: Library(rememberFolder: false))
        XCTAssertNil(empty.library.source, "the Welcome view")
        XCTAssertFalse(AppCommand.command(.open).isEnabled(empty))
        XCTAssertTrue(HiddenShortcuts.commands.contains { $0.name == .open })
        let (lib, ctx, ids) = try openThree()
        XCTAssertNil(lib.selection)
        run(.open, ctx)
        XCTAssertTrue(lib.loupe, "Return with no selection opens the first photo")
        XCTAssertEqual(lib.selection, ids[0])
    }

    // MARK: Each command does what its title says

    private func makePhoto(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func openThree() throws -> (Library, CommandContext, [Photo.ID]) {
        for n in ["a.png", "b.png", "c.png"] { try makePhoto(n) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.photos.count, 3)
        return (lib, CommandContext(library: lib), lib.photos.map(\.id))
    }

    private func run(_ name: AppCommand.Name, _ ctx: CommandContext, file: StaticString = #filePath, line: UInt = #line) {
        let command = AppCommand.command(name)
        XCTAssertTrue(command.isEnabled(ctx), "\(name) disabled", file: file, line: line)
        command.perform(ctx)
    }

    func testFlagAndRatingKeysMarkEveryBatchTarget() throws {
        let (lib, ctx, ids) = try openThree()
        XCTAssertFalse(AppCommand.command(.pick).isEnabled(ctx), "nothing selected")
        lib.selectAll()
        run(.pick, ctx)
        XCTAssertEqual(ids.map { lib.flag(for: $0) }, [.pick, .pick, .pick])
        run(.reject, ctx)
        XCTAssertEqual(ids.map { lib.flag(for: $0) }, [.reject, .reject, .reject])
        run(.unflag, ctx)
        XCTAssertEqual(ids.map { lib.flag(for: $0) }, [nil, nil, nil])
        run(.rate3, ctx)
        XCTAssertEqual(ids.map { lib.rating(for: $0) }, [3, 3, 3])
        lib.selection = ids[1]
        run(.rate5, ctx)
        XCTAssertEqual(ids.map { lib.rating(for: $0) }, [3, 5, 3])
        run(.rate0, ctx)
        XCTAssertEqual(ids.map { lib.rating(for: $0) }, [3, 0, 3])
    }

    func testViewKeysSwitchTheViewAndToggleTheOverlays() throws {
        let (lib, ctx, ids) = try openThree()
        // Y from the grid opens the loupe on the first photo, side by side.
        run(.compare, ctx)
        XCTAssertTrue(lib.compare)
        XCTAssertTrue(lib.loupe)
        XCTAssertEqual(lib.selection, ids[0])
        run(.compare, ctx)
        XCTAssertFalse(lib.compare)
        XCTAssertTrue(lib.loupe)
        run(.clipping, ctx)
        XCTAssertTrue(lib.showClipping)
        XCTAssertEqual(AppCommand.command(.clipping).isOn?(ctx), true)
        run(.clipping, ctx)
        XCTAssertFalse(lib.showClipping)
        run(.showOriginal, ctx)
        XCTAssertTrue(lib.showBefore)
        run(.next, ctx)
        XCTAssertEqual(lib.selection, ids[1])
        run(.previous, ctx)
        XCTAssertEqual(lib.selection, ids[0])
        run(.grid, ctx)
        XCTAssertFalse(lib.loupe)
        XCTAssertEqual(AppCommand.command(.grid).isOn?(ctx), true)
        run(.loupe, ctx)
        XCTAssertTrue(lib.loupe)
        run(.back, ctx)
        XCTAssertFalse(lib.loupe)
        lib.selectAll()
        run(.back, ctx)
        XCTAssertEqual(lib.selectedIDs, [ids[0]])
        run(.open, ctx)
        XCTAssertTrue(lib.loupe)
    }

    /// Z toggles fit and 1:1 at the middle, in the loupe only; the arrows
    /// (even at either end), a new photo and leaving the loupe return to
    /// fit.
    func testZTogglesOneToOneAndEveryPhotoChangeReturnsToFit() throws {
        let (lib, ctx, ids) = try openThree()
        XCTAssertFalse(AppCommand.command(.zoom).isEnabled(ctx), "the grid has no zoom")
        run(.loupe, ctx)
        run(.zoom, ctx)
        XCTAssertEqual(lib.loupeZoom, .actual(center: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(AppCommand.command(.zoom).isOn?(ctx), true)
        run(.zoom, ctx)
        XCTAssertEqual(lib.loupeZoom, .fit)
        XCTAssertEqual(AppCommand.command(.zoom).isOn?(ctx), false)

        run(.zoom, ctx)
        run(.next, ctx)
        XCTAssertEqual(lib.selection, ids[1])
        XCTAssertEqual(lib.loupeZoom, .fit, "→ returns to fit")
        lib.selection = ids[0]
        run(.zoom, ctx)
        run(.previous, ctx)
        XCTAssertEqual(lib.selection, ids[0], "already the first photo")
        XCTAssertEqual(lib.loupeZoom, .fit, "← at the first photo still returns to fit")
        lib.loupeZoom = .actual(center: CGPoint(x: 0.2, y: 0.7))
        lib.click(ids[2])
        XCTAssertEqual(lib.loupeZoom, .fit, "a filmstrip click is a photo change")
        run(.zoom, ctx)
        run(.back, ctx)
        XCTAssertFalse(lib.loupe)
        XCTAssertEqual(lib.loupeZoom, .fit, "leaving the loupe")
        XCTAssertFalse(AppCommand.command(.zoom).isOn?(ctx) ?? true)
    }

    /// R toggles crop mode, in the loupe only; entering returns the zoom to
    /// fit and ends compare; Esc leaves crop mode before it leaves the
    /// loupe; Z, compare and leaving the loupe end it too.
    func testRTogglesCropModeAndEscLeavesItBeforeTheLoupe() throws {
        let (lib, ctx, _) = try openThree()
        XCTAssertFalse(AppCommand.command(.crop).isEnabled(ctx), "the grid has no crop mode")
        run(.loupe, ctx)
        run(.zoom, ctx)
        run(.compare, ctx)
        XCTAssertTrue(lib.compare)
        run(.crop, ctx)
        XCTAssertTrue(lib.cropMode)
        XCTAssertEqual(AppCommand.command(.crop).isOn?(ctx), true)
        XCTAssertEqual(lib.loupeZoom, .fit, "entering crop mode returns to fit")
        XCTAssertFalse(lib.compare, "entering crop mode ends compare")
        run(.crop, ctx)
        XCTAssertFalse(lib.cropMode, "R again leaves it")

        run(.crop, ctx)
        run(.back, ctx)
        XCTAssertFalse(lib.cropMode, "Esc leaves crop mode")
        XCTAssertTrue(lib.loupe, "and not the loupe")
        run(.back, ctx)
        XCTAssertFalse(lib.loupe)

        run(.loupe, ctx)
        run(.crop, ctx)
        run(.zoom, ctx)
        XCTAssertFalse(lib.cropMode, "Z leaves crop mode")
        XCTAssertNotEqual(lib.loupeZoom, .fit)
        run(.crop, ctx)
        run(.compare, ctx)
        XCTAssertFalse(lib.cropMode, "compare leaves crop mode")
        run(.crop, ctx)
        run(.grid, ctx)
        XCTAssertFalse(lib.cropMode, "leaving the loupe leaves crop mode")
    }

    /// W arms the white-balance eyedropper, in the loupe only, as a bare
    /// key in the Photo menu; arming it leaves crop mode and compare; Esc
    /// puts it down before it leaves the loupe; crop mode, compare and
    /// leaving the loupe disarm it. Tool state: no recipe changes.
    func testWArmsTheWhiteBalancePickerAndEscPutsItDownFirst() throws {
        let command = AppCommand.command(.whiteBalance)
        XCTAssertEqual(command.key, "w")
        XCTAssertTrue(command.isBareKey)
        XCTAssertEqual(command.placement, .photo)
        let (lib, ctx, ids) = try openThree()
        XCTAssertFalse(command.isEnabled(ctx), "the grid has no eyedropper")
        run(.loupe, ctx)
        run(.crop, ctx)
        run(.whiteBalance, ctx)
        XCTAssertTrue(lib.whiteBalancePicking)
        XCTAssertEqual(command.isOn?(ctx), true)
        XCTAssertFalse(lib.cropMode, "arming leaves crop mode")
        run(.whiteBalance, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "W again puts it down")

        run(.crop, ctx)
        run(.whiteBalance, ctx)
        run(.back, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "Esc puts it down")
        XCTAssertTrue(lib.loupe, "and not the loupe")
        run(.back, ctx)
        XCTAssertFalse(lib.loupe)

        run(.loupe, ctx)
        run(.compare, ctx)
        run(.whiteBalance, ctx)
        XCTAssertFalse(lib.compare, "arming ends compare")
        run(.compare, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "compare puts it down")
        run(.compare, ctx)
        run(.whiteBalance, ctx)
        run(.crop, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "crop mode puts it down")
        run(.crop, ctx)
        run(.whiteBalance, ctx)
        run(.next, ctx)
        XCTAssertTrue(lib.whiteBalancePicking, "kept across photos, like the other tools")
        run(.grid, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "leaving the loupe puts it down")
        for id in ids { XCTAssertEqual(lib.recipe(for: id), .neutral, "tool state is not an edit") }
    }

    func testEditAndPhotoMenuItemsActOnTheSelection() throws {
        let (lib, ctx, ids) = try openThree()
        XCTAssertFalse(AppCommand.command(.resetPhoto).isEnabled(ctx))
        lib.selection = ids[0]
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: ids[0])
        run(.copySettings, ctx)
        XCTAssertNotNil(lib.copiedSettings)
        run(.resetPhoto, ctx)
        XCTAssertFalse(lib.isEdited(ids[0]))
        run(.undo, ctx)
        XCTAssertTrue(lib.isEdited(ids[0]))
        run(.redo, ctx)
        XCTAssertFalse(lib.isEdited(ids[0]))
        XCTAssertFalse(AppCommand.command(.syncSettings).isEnabled(ctx))
        run(.selectAll, ctx)
        XCTAssertEqual(lib.selectedIDs, Set(ids))
        XCTAssertEqual(AppCommand.command(.export).menuTitle(ctx), "Export 3 Photos…")
        // Save Preset needs the loupe; it raises the preset store's alert.
        XCTAssertFalse(AppCommand.command(.savePreset).isEnabled(ctx))
    }
}
