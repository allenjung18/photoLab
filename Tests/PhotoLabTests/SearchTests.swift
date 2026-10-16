import XCTest
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import PhotoLab

/// Search: the grid shows a photo when the filter admits its marks AND every
/// whitespace-separated term of `Library.searchText` is found in its name or
/// one of its keywords (case- and diacritic-insensitive), so every path that
/// walks `visiblePhotos` follows. While the search field has focus
/// (`Library.textEntryActive`) every bare-key command is disabled. Every
/// file lives under a temporary directory.
@MainActor
final class SearchTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makePhoto(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The library over `names`, and each photo's id by its name.
    private func openLibrary(_ names: [String]) throws -> (Library, [String: Photo.ID]) {
        for n in names { try makePhoto(n) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.photos.count, names.count)
        return (lib, Dictionary(uniqueKeysWithValues: lib.photos.map { ($0.name, $0.id) }))
    }

    private func shown(_ lib: Library) -> Set<String> { Set(lib.visiblePhotos.map(\.name)) }

    // MARK: Matching

    func testTermsAreANDed() throws {
        let (lib, _) = try openLibrary(["beach-day.png", "beach-night.png", "city-day.png"])
        lib.searchText = "beach"
        XCTAssertEqual(shown(lib), ["beach-day.png", "beach-night.png"])
        lib.searchText = "beach day"
        XCTAssertEqual(shown(lib), ["beach-day.png"], "every term must match, not any")
        lib.searchText = "  day   beach  "
        XCTAssertEqual(shown(lib), ["beach-day.png"], "terms split at any run of whitespace, in any order")
        lib.searchText = "beach dusk"
        XCTAssertTrue(lib.visiblePhotos.isEmpty)
        lib.searchText = "   "
        XCTAssertEqual(lib.visiblePhotos.count, 3, "a blank search shows every photo")
        XCTAssertFalse(lib.isNarrowed)
    }

    func testANameOrAKeywordMatchesEachTerm() throws {
        let (lib, ids) = try openLibrary(["IMG_001.png", "IMG_002.png", "IMG_003.png"])
        lib.addKeywords(["Sunset", "Harbor"], to: [ids["IMG_001.png"]!])
        lib.addKeywords(["Sunrise"], to: [ids["IMG_002.png"]!])
        lib.searchText = "sunset"
        XCTAssertEqual(shown(lib), ["IMG_001.png"], "a keyword matches")
        lib.searchText = "sun"
        XCTAssertEqual(shown(lib), ["IMG_001.png", "IMG_002.png"], "a substring of a keyword matches")
        lib.searchText = "003"
        XCTAssertEqual(shown(lib), ["IMG_003.png"], "a substring of the name matches")
        lib.searchText = "001 harbor"
        XCTAssertEqual(shown(lib), ["IMG_001.png"], "one term by the name, another by a keyword")
        lib.searchText = "002 harbor"
        XCTAssertTrue(lib.visiblePhotos.isEmpty, "the keyword is on another photo")
        XCTAssertTrue(lib.isNarrowed)
    }

    func testCaseAndDiacriticsAreIgnored() throws {
        let (lib, ids) = try openLibrary(["Ñandú.png", "plain.png"])
        lib.addKeywords(["Café"], to: [ids["plain.png"]!])
        for text in ["cafe", "CAFE", "café", "CAFÉ", "aFé"] {
            lib.searchText = text
            XCTAssertEqual(shown(lib), ["plain.png"], text)
        }
        for text in ["nandu", "NANDÚ", "ñandu"] {
            lib.searchText = text
            XCTAssertEqual(shown(lib), ["Ñandú.png"], text)
        }
    }

    /// A Photos asset the listing has not named yet matches by its keywords
    /// only, never by the identifier standing in for its name.
    func testAnUnnamedPhotoMatchesByKeywordsOnly() {
        let unnamed = Photo(id: .asset("1A2B-L0-001"), name: nil)
        XCTAssertFalse(unnamed.isNamed)
        XCTAssertFalse(PhotoSearch("1A2B").matches(unnamed, keywords: []))
        XCTAssertTrue(PhotoSearch("beach").matches(unnamed, keywords: ["Beach"]))
        XCTAssertFalse(PhotoSearch("1A2B beach").matches(unnamed, keywords: ["Beach"]))
        let named = unnamed.named("Shore.heic")
        XCTAssertTrue(PhotoSearch("shore beach").matches(named, keywords: ["Beach"]))
        XCTAssertTrue(PhotoSearch("").matches(unnamed, keywords: []), "an empty search matches every photo")
    }

    // MARK: With the filter and the selection

    func testSearchIsANDedWithTheFilter() throws {
        let (lib, ids) = try openLibrary(["beach-1.png", "beach-2.png", "city-1.png"])
        lib.setFlag(.pick, for: [ids["beach-1.png"]!, ids["city-1.png"]!])
        lib.filter = .picks
        XCTAssertEqual(shown(lib), ["beach-1.png", "city-1.png"])
        lib.searchText = "beach"
        XCTAssertEqual(shown(lib), ["beach-1.png"])
        XCTAssertTrue(lib.isVisible(ids["beach-1.png"]!))
        XCTAssertFalse(lib.isVisible(ids["beach-2.png"]!), "matches the search, not the filter")
        XCTAssertFalse(lib.isVisible(ids["city-1.png"]!), "matches the filter, not the search")
        lib.filter = .all
        XCTAssertEqual(shown(lib), ["beach-1.png", "beach-2.png"])
    }

    func testSelectionFollowsTheSearch() throws {
        let (lib, ids) = try openLibrary(["a-sea.png", "b-hill.png", "c-sea.png", "d-hill.png"])
        let order = lib.photos.map(\.name)
        XCTAssertEqual(order, ["a-sea.png", "b-hill.png", "c-sea.png", "d-hill.png"])
        // A hidden anchor moves to the next visible photo in sort order.
        lib.selection = ids["b-hill.png"]
        lib.searchText = "sea"
        XCTAssertEqual(lib.selection, ids["c-sea.png"])
        // Select All, the batch targets and the arrows walk the matches.
        lib.selectAll()
        XCTAssertEqual(Set(lib.batchTargets), [ids["a-sea.png"]!, ids["c-sea.png"]!])
        lib.selection = ids["a-sea.png"]
        lib.select(offset: 1)
        XCTAssertEqual(lib.selection, ids["c-sea.png"], "the arrow skips the hidden b")
        XCTAssertEqual(Filmstrip.items(for: lib).map(\.id), [ids["a-sea.png"]!, ids["c-sea.png"]!])
        // A click on a hidden photo is ignored; a keyword change re-applies it.
        lib.click(ids["d-hill.png"]!)
        XCTAssertEqual(lib.selection, ids["c-sea.png"])
        lib.addKeywords(["Seaside"], to: [ids["d-hill.png"]!])
        XCTAssertTrue(lib.isVisible(ids["d-hill.png"]!), "the new keyword matches")
        lib.selection = ids["c-sea.png"]
        lib.searchText = "seaside"
        XCTAssertEqual(lib.selection, ids["d-hill.png"], "c is hidden; d is the next match")
        lib.removeKeyword("Seaside", from: [ids["d-hill.png"]!])
        XCTAssertNil(lib.selection, "the last match lost its keyword")
        XCTAssertTrue(lib.batchTargets.isEmpty)
    }

    func testOpenResetsTheSearch() throws {
        let (lib, _) = try openLibrary(["one.png", "two.png"])
        lib.searchText = "one"
        XCTAssertEqual(lib.visiblePhotos.count, 1)
        lib.open(folder)
        XCTAssertEqual(lib.searchText, "")
        XCTAssertEqual(lib.visiblePhotos.count, 2)
        XCTAssertFalse(lib.isNarrowed)
    }

    func testKeywordTallyCountsTheSourcesKeywords() throws {
        let (lib, ids) = try openLibrary(["a.png", "b.png", "c.png"])
        XCTAssertTrue(lib.keywordTally.isEmpty)
        lib.addKeywords(["Sunset", "Harbor"], to: [ids["a.png"]!, ids["b.png"]!])
        lib.addKeywords(["sunset"], to: [ids["c.png"]!])
        lib.searchText = "harbor"
        let tally = lib.keywordTally
        XCTAssertEqual(tally.map(\.keyword), ["Harbor", "Sunset"])
        XCTAssertEqual(tally.map(\.count), [2, 3], "over every photo, not only the shown ones")
    }

    // MARK: Commands

    /// Every bare key (`AppCommand.isBareKey`) is disabled while the search
    /// field has focus, through `AppCommand.all`; a key with modifiers is not.
    func testEveryBareKeyIsDisabledWhileTyping() throws {
        let (lib, ids) = try openLibrary(["a.png", "b.png"])
        lib.selection = ids["a.png"]
        let ctx = CommandContext(library: lib)
        let bare = AppCommand.all.filter(\.isBareKey)
        XCTAssertEqual(bare.map(\.name), HiddenShortcuts.commands.map(\.name))
        XCTAssertGreaterThan(bare.count, 20)
        let enabledBefore = bare.filter { $0.isEnabled(ctx) }.map(\.name)
        XCTAssertTrue(enabledBefore.contains(.pick), "control: P is live in the grid")
        XCTAssertTrue(enabledBefore.contains(.back))
        lib.textEntryActive = true
        for command in bare {
            XCTAssertFalse(command.isEnabled(ctx), "\(command.name) fires while typing")
        }
        for name in [AppCommand.Name.search, .keywords, .export, .selectAll] {
            XCTAssertTrue(AppCommand.command(name).isEnabled(ctx), "\(name) has modifiers and stays on")
        }
        lib.textEntryActive = false
        XCTAssertEqual(bare.filter { $0.isEnabled(ctx) }.map(\.name), enabledBefore)
    }

    func testSearchPhotosIsCommandFAndLeavesTheLoupe() throws {
        let command = AppCommand.command(.search)
        XCTAssertEqual(command.key?.character, "f")
        XCTAssertEqual(command.modifiers, .command)
        XCTAssertEqual(command.placement, .pasteboard)
        XCTAssertFalse(command.isEnabled(CommandContext(library: Library(rememberFolder: false))),
                       "no photos, no search field")
        let (lib, ids) = try openLibrary(["a.png"])
        lib.selection = ids["a.png"]
        lib.loupe = true
        let ctx = CommandContext(library: lib)
        XCTAssertTrue(command.isEnabled(ctx))
        command.perform(ctx)
        XCTAssertFalse(lib.loupe, "the field is in the grid")
        XCTAssertTrue(lib.searchFocusRequested)
    }
}
