import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// Open Recent and reopening where you left off: the list in the injected
/// defaults (never the real ones), and each source's anchor, view and
/// filter restored when it opens again.
@MainActor
final class RecentsTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "photolab-recents-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFolder(_ name: String, photos: Int = 4) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...photos {
            let url = dir.appendingPathComponent("IMG_000\(i).png")
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        return dir
    }

    private func library() -> Library { Library(rememberFolder: true, defaults: defaults) }

    private func titles(_ lib: Library) -> [String] { lib.recentSources().map(\.title) }

    func testOrderDedupeCapAndClear() throws {
        let lib = library()
        var dirs: [URL] = []
        for i in 1...12 { dirs.append(try makeFolder("d\(i)", photos: 1)) }
        for d in dirs { lib.open(d) }
        // Cap 10, most recent first.
        XCTAssertEqual(titles(lib), (3...12).reversed().map { "d\($0)" })
        // Reopening one moves it to the top, once.
        lib.open(dirs[5])
        XCTAssertEqual(titles(lib).first, "d6")
        XCTAssertEqual(titles(lib).filter { $0 == "d6" }.count, 1)
        XCTAssertEqual(titles(lib).count, 10)
        // Another Library on the same defaults sees the same list.
        XCTAssertEqual(titles(library()), titles(lib))
        lib.clearRecents()
        XCTAssertEqual(titles(lib), [])
        XCTAssertEqual(titles(library()), [])
    }

    func testMissingFolderIsPrunedWhenListed() throws {
        let lib = library()
        let a = try makeFolder("a", photos: 1), b = try makeFolder("b", photos: 1)
        lib.open(a)
        lib.open(b)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(titles(lib), ["b"])
        XCTAssertEqual(titles(library()), ["b"], "forgotten, not just hidden")
    }

    func testQuietLibraryWritesNothing() throws {
        let quiet = Library(rememberFolder: false, defaults: defaults)
        quiet.open(try makeFolder("q", photos: 1))
        XCTAssertNil(defaults.data(forKey: "recentSources"))
    }

    func testPhotosAlbumListedWhileStillThere() throws {
        let client = PhotosTests.FakePhotoKit(status: .authorized)
        client.albumList = [PhotosTests.trip]
        client.assetsByAlbum = [PhotosTests.trip.id: []]
        let access = PhotosAccess(client: client, sidecarDirectory: base.appendingPathComponent("sc"),
                                  originalsDirectory: base.appendingPathComponent("orig"))
        let lib = library()
        lib.open(album: PhotosTests.trip, access: access)
        XCTAssertEqual(lib.recentSources(access: access).map(\.title), ["Trip"])
        client.albumList = []
        XCTAssertEqual(lib.recentSources(access: access), [], "a gone album is dropped")
        let denied = PhotosTests.FakePhotoKit(status: .notDetermined)
        let cold = PhotosAccess(client: denied, sidecarDirectory: access.sidecarDirectory,
                                originalsDirectory: access.originalsDirectory)
        XCTAssertEqual(lib.recentSources(access: cold), [])
        XCTAssertEqual(denied.requestCalls, 0, "listing never prompts")
    }

    func testReopenRestoresAnchorViewAndFilter() throws {
        let a = try makeFolder("a"), b = try makeFolder("b")
        let lib = library()
        lib.open(a)
        let ids = lib.photos.map(\.id)
        lib.setFlag(.pick, for: [ids[2]])
        lib.setFlag(.pick, for: [ids[3]])
        lib.filter = .picks
        lib.selection = ids[2]
        lib.loupe = true
        lib.open(b)
        XCTAssertEqual(lib.filter, .all)
        XCTAssertNil(lib.selection)
        XCTAssertFalse(lib.loupe)

        // From the recents list.
        let entry = try XCTUnwrap(lib.recentSources().first { $0.title == "a" })
        lib.openRecent(entry)
        XCTAssertEqual(lib.selection, ids[2])
        XCTAssertTrue(lib.loupe)
        XCTAssertEqual(lib.filter, .picks)

        // From launch, in a new Library on the same defaults.
        let relaunched = library()
        relaunched.restoreLastSource()
        XCTAssertEqual(relaunched.selection, ids[2])
        XCTAssertTrue(relaunched.loupe)
        XCTAssertEqual(relaunched.filter, .picks)

        // From Open Folder (a plain open of the same path).
        lib.open(b)
        lib.open(a)
        XCTAssertEqual(lib.selection, ids[2])
        XCTAssertEqual(lib.filter, .picks)
    }

    func testGonePhotoFallsBackToTheGrid() throws {
        let a = try makeFolder("a"), b = try makeFolder("b")
        let lib = library()
        lib.open(a)
        let gone = lib.photos[2]
        lib.selection = gone.id
        lib.loupe = true
        lib.open(b)
        try FileManager.default.removeItem(at: try XCTUnwrap(gone.fileURL))
        lib.open(a)
        XCTAssertNil(lib.selection)
        XCTAssertFalse(lib.loupe)
        XCTAssertEqual(lib.photos.count, 3)
    }

    func testPhotoHiddenByRestoredFilterFallsBack() throws {
        let a = try makeFolder("a"), b = try makeFolder("b")
        let lib = library()
        lib.open(a)
        let id = lib.photos[1].id
        lib.setFlag(.pick, for: [id])
        lib.filter = .picks
        lib.selection = id
        lib.loupe = true
        // Unpick it behind the filter's back: the anchor leaves, state saved without one.
        lib.open(b)
        lib.open(a)
        XCTAssertEqual(lib.selection, id)
        lib.open(b)
        // Edit the sidecar so the photo is no longer a pick, then reopen.
        let other = library()
        other.open(a)
        other.filter = .all
        other.setFlag(nil, for: [id])
        other.open(b)
        // Restore the stale state by hand: anchor id, loupe, Picks filter.
        var list = try JSONDecoder().decode([RecentSource].self, from: try XCTUnwrap(defaults.data(forKey: "recentSources")))
        let i = try XCTUnwrap(list.firstIndex { $0.title == "a" })
        list[i].state = SourceViewState(anchor: id, loupe: true, filter: "picks")
        defaults.set(try JSONEncoder().encode(list), forKey: "recentSources")
        other.open(a)
        XCTAssertEqual(other.filter, .picks)
        XCTAssertNil(other.selection)
        XCTAssertFalse(other.loupe)
    }

    func testFilterStorageKeysRoundTrip() {
        for f in PhotoFilter.allCases { XCTAssertEqual(PhotoFilter(storageKey: f.storageKey), f) }
        XCTAssertNil(PhotoFilter(storageKey: "bogus"))
    }
}
