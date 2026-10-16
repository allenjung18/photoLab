import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// The loupe's filmstrip: its items are the visible photos, a click goes
/// through the grid's rules, its cells key the grid's one thumbnail cache,
/// and its show/hide choice is remembered in the injected defaults.
@MainActor
final class FilmstripTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-filmstrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "photolab-filmstrip-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makePhotos(_ names: [String]) throws {
        for name in names {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }

    private func library(_ names: [String] = ["a.png", "b.png", "c.png", "d.png"]) throws -> Library {
        try makePhotos(names)
        let lib = Library(rememberFolder: false, defaults: defaults)
        lib.open(folder)
        return lib
    }

    private func id(_ lib: Library, _ name: String) throws -> Photo.ID {
        try XCTUnwrap(lib.photos.first { $0.name == name }, "no photo \(name)").id
    }

    func testTheStripsItemsAreTheVisiblePhotosUnderAFilter() throws {
        let lib = try library()
        let b = try id(lib, "b.png"), c = try id(lib, "c.png")
        XCTAssertEqual(Filmstrip.items(for: lib).map(\.id), lib.visiblePhotos.map(\.id))
        XCTAssertEqual(Filmstrip.items(for: lib).count, 4)
        lib.setFlag(.pick, for: [c])
        lib.setFlag(.reject, for: [b])
        lib.filter = .picks
        let ids = Filmstrip.items(for: lib).map(\.id)
        XCTAssertEqual(ids, [c])
        XCTAssertFalse(ids.contains(b), "a rejected photo is absent under Picks")
    }

    func testAClickMovesTheLoupesPhotoAndAShiftClickExtendsTheSelection() throws {
        let lib = try library()
        let a = try id(lib, "a.png"), b = try id(lib, "b.png"), c = try id(lib, "c.png")
        Filmstrip.click(a, in: lib)
        XCTAssertEqual(lib.selection, a)
        Filmstrip.click(c, in: lib)
        XCTAssertEqual(lib.selection, c, "the loupe's photo moved")
        XCTAssertEqual(lib.selectedIDs, [c])
        Filmstrip.click(a, in: lib)
        Filmstrip.click(c, in: lib, extending: true)
        XCTAssertEqual(lib.selectedIDs, [a, b, c])
        XCTAssertEqual(lib.selection, a, "the anchor is kept")
        Filmstrip.click(b, in: lib, toggling: true)
        XCTAssertEqual(lib.selectedIDs, [a, c])
    }

    func testACellsKeyIsTheGridsThumbnailKeyForAnEditedPhotoAndItsBadgesMatch() throws {
        let lib = try library()
        let a = try id(lib, "a.png"), b = try id(lib, "b.png")
        var r = Recipe.neutral
        r.set(.exposure, to: 1)
        lib.setRecipe(r, for: a)
        lib.setRating(3, for: [a])
        lib.click(a)
        let items = Filmstrip.items(for: lib)
        let item = try XCTUnwrap(items.first { $0.id == a })
        XCTAssertEqual(item.key, Thumbnails.Key(a, recipe: lib.recipe(for: a)))
        XCTAssertFalse(item.key.isPlain)
        XCTAssertTrue(item.edited)
        XCTAssertEqual(item.marks.rating, 3)
        XCTAssertTrue(item.anchor)
        let plain = try XCTUnwrap(items.first { $0.id == b })
        XCTAssertTrue(plain.key.isPlain)
        XCTAssertFalse(plain.edited)
    }

    func testTheViewMenuItemTogglesTheChoiceAndARelaunchRemembersIt() throws {
        let lib = Library(rememberFolder: true, defaults: defaults)
        XCTAssertTrue(lib.showFilmstrip, "shown by default")
        let command = AppCommand.command(.filmstrip)
        XCTAssertEqual(command.placement, .view)
        command.perform(CommandContext(library: lib))
        XCTAssertFalse(lib.showFilmstrip)
        XCTAssertFalse(Library(rememberFolder: true, defaults: defaults).showFilmstrip, "remembered")
        command.perform(CommandContext(library: lib))
        XCTAssertTrue(Library(rememberFolder: true, defaults: defaults).showFilmstrip)
    }
}
