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
        let expected: [KeyEquivalent] = ["g", "e", "y", "\\", "j", "f", "p", "x", "u",
                                         "0", "1", "2", "3", "4", "5",
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
        XCTAssertEqual(view, [.grid, .loupe, .compare, .showOriginal, .clipping, .filmstrip, .previous, .next])
        let photo = AppCommand.items(in: .photo).map(\.name)
        XCTAssertEqual(photo, [.pick, .reject, .unflag, .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .resetPhoto])
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
        XCTAssertEqual(AppCommand.command(.resetPhoto).menuTitle(ctx), "Reset Photo")
        XCTAssertEqual(AppCommand.command(.export).menuTitle(ctx), "Export…")
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
