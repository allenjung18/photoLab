import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// Collections: saved sets of folder photos across folders. The store keeps
/// one JSON per collection in a temporary directory; a collection opens as
/// one source; each member's edit is written to (and read from) its own
/// folder's sidecar store; a missing member is counted, never dropped;
/// removing a member or deleting a collection never touches a photo; Open
/// Recent and the launch reopen bring a collection back. Every path here is
/// under a temporary directory and the defaults are a throwaway suite.
@MainActor
final class CollectionsTests: XCTestCase {
    private var base: URL!
    private var store: CollectionStore!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-collections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = CollectionStore(directory: base.appendingPathComponent("Collections", isDirectory: true))
        suite = "photolab-collections-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFolder(_ name: String, photos: [String]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in photos {
            let url = dir.appendingPathComponent(file)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        return dir
    }

    private func library(remember: Bool = false) -> Library {
        remember ? Library(rememberFolder: true, defaults: defaults, collections: store)
                 : Library(rememberFolder: false, collections: store)
    }

    private func id(_ lib: Library, _ name: String) -> Photo.ID {
        lib.photos.first { $0.name == name }!.id
    }

    private var bright: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        return r
    }

    private var contrasty: Recipe {
        var r = Recipe.neutral
        r.set(.contrast, to: 30)
        return r
    }

    /// Two folders, a collection "Trip" holding a1 (from A) and b2 (from B),
    /// each added while its own folder was open. Returns the library open
    /// on B, the folders and the collection.
    private func tripAcrossTwoFolders(_ lib: Library) throws -> (a: URL, b: URL, trip: PhotoCollection) {
        let a = try makeFolder("A", photos: ["a1.png", "a2.png"])
        let b = try makeFolder("B", photos: ["b1.png", "b2.png"])
        lib.open(a)
        let trip = try XCTUnwrap(lib.createCollection(named: "Trip", adding: [id(lib, "a1.png")]))
        lib.open(b)
        XCTAssertEqual(lib.addToCollection(trip.id, ids: [id(lib, "b2.png")]), 1)
        XCTAssertEqual(lib.addToCollection(trip.id, ids: [id(lib, "b2.png")]), 0, "a member is added once")
        return (a, b, try XCTUnwrap(store.load(trip.id)))
    }

    // MARK: The store

    func testStoreRoundTripInATemporaryDirectory() throws {
        let root = base.appendingPathComponent("A", isDirectory: true)
        let m = PhotoCollection.Member(file: root.appendingPathComponent("x y.png"), root: root)
        let c = PhotoCollection(name: "Keepers", members: [m])
        try store.save(c)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: c.id).path))
        XCTAssertEqual(store.url(for: c.id).deletingLastPathComponent().standardizedFileURL,
                       store.directory.standardizedFileURL)
        let back = try XCTUnwrap(store.load(c.id))
        XCTAssertEqual(back.name, "Keepers")
        XCTAssertEqual(back.members, [m])
        XCTAssertEqual(back.id, c.id)
        XCTAssertEqual(Int(back.created.timeIntervalSince1970), Int(c.created.timeIntervalSince1970))

        try store.save(PhotoCollection(name: "apples"))
        XCTAssertEqual(store.loadAll().collections.map(\.name), ["apples", "Keepers"], "by name, case-insensitive")

        // A file this build cannot read is listed, never overwritten.
        let bad = store.directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: bad)
        XCTAssertEqual(store.loadAll().unreadable.map(\.lastPathComponent), [bad.lastPathComponent])
        var newer = PhotoCollection(name: "Future")
        newer.version = PhotoCollection.currentVersion + 1
        try store.save(newer)
        XCTAssertNil(store.load(newer.id), "a newer version is refused")
        XCTAssertEqual(store.loadAll().collections.count, 2)

        XCTAssertThrowsError(try store.save(PhotoCollection(name: "  "))) {
            XCTAssertEqual($0 as? CollectionError, .emptyName)
        }

        try store.remove(c.id)
        XCTAssertNil(store.load(c.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }

    // MARK: Opening

    func testMembersOfTwoFoldersOpenAsOneSource() async throws {
        let lib = library()
        let (a, b, trip) = try tripAcrossTwoFolders(lib)
        XCTAssertEqual(trip.members.map(\.file.lastPathComponent), ["a1.png", "b2.png"])
        XCTAssertEqual(trip.members.map(\.root), [a, b], "each member keeps the folder it was added from")

        lib.open(collection: trip)
        XCTAssertNil(lib.openError)
        XCTAssertTrue(lib.source is CollectionSource)
        XCTAssertEqual(lib.source?.title, "Trip")
        XCTAssertEqual(Set(lib.photos.map(\.name)), ["a1.png", "b2.png"])
        XCTAssertNil(lib.folder, "a collection is not a folder")
        XCTAssertEqual(lib.sortKind, .folder, "a collection sorts like folder photos")
        XCTAssertEqual(lib.missingMembers, 0)
        let original = try await lib.originalFile(for: id(lib, "b2.png"))
        XCTAssertEqual(original.lastPathComponent, "b2.png")
    }

    /// The routing: an edit (recipe, flag, keyword) made while the
    /// collection is open is written to each member's own folder and read
    /// back by opening that folder; and an edit made in a folder is read by
    /// the collection.
    func testAnEditMadeInTheCollectionIsReadBackByOpeningItsFolder() throws {
        let lib = library()
        let (a, b, trip) = try tripAcrossTwoFolders(lib)
        // Made in folder B (open now), before the collection opens.
        lib.setFlag(.pick, for: [id(lib, "b2.png")])

        lib.open(collection: trip)
        let a1 = id(lib, "a1.png"), b2 = id(lib, "b2.png")
        XCTAssertEqual(lib.flag(for: b2), .pick, "the collection reads B's sidecar")
        lib.setRecipe(bright, for: a1)
        lib.setRecipe(contrasty, for: b2)
        lib.addKeywords(["harbour"], to: [b2])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SidecarStore(folder: a).url(for: a1).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SidecarStore(folder: b).url(for: b2).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SidecarStore(folder: a).url(for: b2).path), "b2's edit is not in A")

        lib.open(a)
        XCTAssertEqual(lib.recipe(for: id(lib, "a1.png")), bright)
        XCTAssertFalse(lib.isEdited(id(lib, "a2.png")))
        lib.open(b)
        XCTAssertEqual(lib.recipe(for: id(lib, "b2.png")), contrasty)
        XCTAssertEqual(lib.flag(for: id(lib, "b2.png")), .pick)
        XCTAssertEqual(lib.keywords(for: id(lib, "b2.png")), ["harbour"])
    }

    func testAMissingMemberIsCountedNotDropped() throws {
        let lib = library()
        let (_, b, trip) = try tripAcrossTwoFolders(lib)
        try FileManager.default.removeItem(at: b.appendingPathComponent("b2.png"))

        lib.open(collection: trip)
        XCTAssertNil(lib.openError)
        XCTAssertEqual(lib.photos.map(\.name), ["a1.png"])
        XCTAssertEqual(lib.missingMembers, 1)
        XCTAssertEqual((lib.source as? CollectionSource)?.missing.map(\.file.lastPathComponent), ["b2.png"])
        XCTAssertEqual(store.load(trip.id)?.members.count, 2, "the collection still holds it")

        // An edit to another member keeps the missing one in the file.
        lib.setRecipe(bright, for: id(lib, "a1.png"))
        lib.open(collection: try XCTUnwrap(store.load(trip.id)))
        XCTAssertEqual(lib.missingMembers, 1)
    }

    func testRemoveFromCollectionLeavesTheFileAndItsSidecarOnDisk() throws {
        let lib = library()
        let (a, _, trip) = try tripAcrossTwoFolders(lib)
        lib.open(collection: trip)
        let a1 = id(lib, "a1.png")
        lib.setRecipe(bright, for: a1)
        lib.selection = a1
        let ctx = CommandContext(library: lib)
        let remove = AppCommand.command(.removeFromCollection)
        XCTAssertTrue(remove.isEnabled(ctx))
        remove.perform(ctx)

        XCTAssertEqual(lib.photos.map(\.name), ["b2.png"])
        XCTAssertNil(lib.selection, "the removed anchor is not selected")
        XCTAssertEqual(store.load(trip.id)?.members.map(\.file.lastPathComponent), ["b2.png"])
        XCTAssertEqual(lib.openCollection?.members.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("a1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SidecarStore(folder: a).url(for: a1).path))
        lib.open(a)
        XCTAssertEqual(lib.recipe(for: id(lib, "a1.png")), bright, "the edit stays with the folder")

        // Remove is offered only while a collection is open.
        XCTAssertFalse(remove.isEnabled(CommandContext(library: lib)))
    }

    func testDeleteCollectionDeletesOnlyItsFileAndClosesIt() throws {
        let lib = library()
        let (a, b, trip) = try tripAcrossTwoFolders(lib)
        lib.open(collection: trip)
        lib.setRecipe(bright, for: id(lib, "a1.png"))
        let ctx = CommandContext(library: lib)
        AppCommand.command(.deleteCollection).perform(ctx)
        XCTAssertEqual(lib.deleteCollectionRequest?.id, trip.id, "a confirm first")
        lib.deleteCollection(trip.id)

        XCTAssertNil(store.load(trip.id))
        XCTAssertNil(lib.source, "the Welcome view")
        XCTAssertTrue(lib.photos.isEmpty)
        for file in [a.appendingPathComponent("a1.png"), b.appendingPathComponent("b2.png")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: a.appendingPathComponent(SidecarStore.directoryName).path))
    }

    // MARK: Recents and the launch reopen

    func testARecentsEntryReopensTheCollection() throws {
        let lib = library(remember: true)
        let (_, _, trip) = try tripAcrossTwoFolders(lib)
        lib.open(collection: trip)
        let entry = try XCTUnwrap(lib.recentSources().first)
        XCTAssertEqual(entry.kind, .collection)
        XCTAssertEqual(entry.title, "Trip")
        XCTAssertEqual(lib.settings.lastSource, .collection(id: trip.id.uuidString))
        lib.selection = id(lib, "b2.png")

        // A fresh library over the same defaults and store.
        let next = library(remember: true)
        let again = try XCTUnwrap(next.recentSources().first { $0.kind == .collection })
        next.openRecent(again)
        XCTAssertEqual((next.source as? CollectionSource)?.collection.id, trip.id)
        XCTAssertEqual(Set(next.photos.map(\.name)), ["a1.png", "b2.png"])
        XCTAssertEqual(next.selection.map { next.name(for: $0) }, "b2.png", "its view state comes back")

        let launch = library(remember: true)
        launch.restoreLastSource()
        XCTAssertEqual(launch.openCollection?.id, trip.id, "reopen-last opens the collection")

        // Deleted: the entry goes, and reopening it is refused.
        launch.deleteCollection(trip.id)
        XCTAssertFalse(launch.recentSources().contains { $0.kind == .collection })
        let stale = library(remember: true)
        stale.openRecent(again)
        XCTAssertNil(stale.source)
        XCTAssertNotNil(stale.openError)
    }

    // MARK: Commands

    /// New Collection… asks for a name over the targets; Add to Collection
    /// is off over a Photos album (a source of assets).
    func testNewCollectionAsksForANameAndAnAlbumCannotAdd() throws {
        let lib = library()
        let a = try makeFolder("A", photos: ["a1.png", "a2.png"])
        lib.open(a)
        lib.selectAll()
        let ctx = CommandContext(library: lib)
        let new = AppCommand.command(.newCollection)
        XCTAssertEqual(new.placement, .collection)
        XCTAssertTrue(new.isEnabled(ctx))
        new.perform(ctx)
        XCTAssertEqual(lib.newCollectionRequest?.targets.count, 2)
        XCTAssertNil(lib.createCollection(named: "   "), "an empty name is refused")
        XCTAssertNotNil(lib.collectionError)
        let made = try XCTUnwrap(lib.createCollection(named: "Both", adding: lib.newCollectionRequest!.targets))
        XCTAssertEqual(made.members.count, 2)
        XCTAssertEqual(lib.savedCollections().map(\.name), ["Both"])

        lib.open(AssetSource(directory: base.appendingPathComponent("flat", isDirectory: true)))
        XCTAssertNil(lib.openError)
        lib.selectAll()
        XCTAssertFalse(lib.canAddToCollection)
        XCTAssertFalse(new.isEnabled(CommandContext(library: lib)))
        XCTAssertEqual(lib.addToCollection(made.id, ids: lib.photos.map(\.id)), 0)

        // A library made without a store offers nothing.
        let none = Library(rememberFolder: false)
        none.open(a)
        XCTAssertFalse(none.canAddToCollection)
        XCTAssertTrue(none.savedCollections().isEmpty)
    }

    /// A source of assets (a stand-in for a Photos album): flat sidecars.
    private struct AssetSource: PhotoSource {
        let directory: URL
        var title: String { "Album" }
        func photos() throws -> [Photo] { [Photo(id: .asset("A/L0/001"), name: "one.heic")] }
        var sidecars: SidecarStore { SidecarStore(directory: directory, naming: .flat) }
        func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? { nil }
        func originalFile(for id: PhotoID) async throws -> URL { throw PhotoSourceError.notInThisSource(id) }
    }
}
