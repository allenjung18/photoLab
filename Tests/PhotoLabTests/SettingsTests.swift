import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import PhotoLab

/// The Settings window's one store (`AppSettings`): its defaults, a round
/// trip through the injected defaults (never the real ones), the keys
/// earlier builds wrote read back unchanged, the grid reading the thumbnail
/// size, the preview quality's pixel size, the launch reopen switched off,
/// and the sort pickers driving the sort chunk's per-kind choice.
@MainActor
final class SettingsTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "photolab-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFolder(_ name: String, files: [String] = ["b.png", "a.png", "c.png"]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let url = dir.appendingPathComponent(file)
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

    private func names(_ lib: Library) -> [String] { lib.photos.map(\.name) }

    func testDefaults() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.gridThumbnailSize, AppSettings.defaultThumbnailSize)
        XCTAssertEqual(s.gridThumbnailSize, 180, "the grid's size before the slider existed")
        XCTAssertEqual(s.previewQuality, .full, "every screen pixel, as before")
        XCTAssertTrue(s.reopenLastSource, "the launch reopen is on, as before")
        XCTAssertTrue(s.showFilmstrip)
        XCTAssertFalse(s.showInfo)
        XCTAssertEqual(s.sort(for: .folder), .folderDefault)
        XCTAssertEqual(s.sort(for: .photos), .photosDefault)
        XCTAssertNil(s.lastSource)
        XCTAssertEqual(s.recents, [])
        XCTAssertNil(s.exportOptions)
        XCTAssertNil(defaults.object(forKey: AppSettings.Key.gridThumbnailSize), "reading writes nothing")
    }

    func testRoundTripThroughTheInjectedDefaults() {
        let s = AppSettings(defaults: defaults)
        s.gridThumbnailSize = 240
        s.previewQuality = .fast
        s.reopenLastSource = false
        s.showFilmstrip = false
        s.showInfo = true
        s.setSort(PhotoSort(key: .rating, ascending: false), for: .folder)
        s.lastSource = .photos(albumID: "album-1")
        s.recents = [RecentSource(kind: .folder, id: "/tmp/x", title: "x")]
        var options = ExportOptions.default
        options.suffix = "-settings"
        s.exportOptions = options
        s.exportFolder = "/tmp/out"
        s.exportAlbum = ""
        s.exportTarget = "photos"

        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.gridThumbnailSize, 240)
        XCTAssertEqual(again.previewQuality, .fast)
        XCTAssertFalse(again.reopenLastSource)
        XCTAssertFalse(again.showFilmstrip)
        XCTAssertTrue(again.showInfo)
        XCTAssertEqual(again.sort(for: .folder), PhotoSort(key: .rating, ascending: false))
        XCTAssertEqual(again.sort(for: .photos), .photosDefault, "the other kind untouched")
        XCTAssertEqual(again.lastSource, .photos(albumID: "album-1"))
        XCTAssertEqual(again.recents.map(\.title), ["x"])
        XCTAssertEqual(again.exportOptions, options)
        XCTAssertEqual(again.exportFolder, "/tmp/out")
        XCTAssertEqual(again.exportAlbum, "")
        XCTAssertEqual(again.exportTarget, "photos")

        // Out of range is clamped, in memory and on disk.
        again.gridThumbnailSize = 10_000
        XCTAssertEqual(again.gridThumbnailSize, AppSettings.thumbnailSizes.upperBound)
        XCTAssertEqual(AppSettings(defaults: defaults).gridThumbnailSize, AppSettings.thumbnailSizes.upperBound)
        defaults.set(1, forKey: AppSettings.Key.gridThumbnailSize)
        XCTAssertEqual(AppSettings(defaults: defaults).gridThumbnailSize, AppSettings.thumbnailSizes.lowerBound)
    }

    /// The keys earlier builds wrote are the keys this one reads: a user's
    /// saved filmstrip, Info, sort, last folder, recents and export choices
    /// come back through the one store.
    func testEarlierBuildsKeysAreReadBackUnchanged() throws {
        let dir = try makeFolder("old")
        defaults.set(false, forKey: "showFilmstrip")
        defaults.set(true, forKey: "showInfo")
        defaults.set("rating.descending", forKey: "sort.folder")
        defaults.set("name.ascending", forKey: "sort.photos")
        defaults.set(dir.path, forKey: "lastFolder")
        defaults.set("folder", forKey: "lastSourceKind")
        let recent = RecentSource(kind: .folder, id: dir.path, title: "old")
        defaults.set(try JSONEncoder().encode([recent]), forKey: "recentSources")
        defaults.set(base.path, forKey: "exportFolder")
        defaults.set("Trips", forKey: "exportPhotosAlbum")
        defaults.set("photos", forKey: "exportTarget")

        let lib = Library(rememberFolder: true, defaults: defaults)
        XCTAssertFalse(lib.showFilmstrip)
        XCTAssertTrue(lib.showInfo)
        XCTAssertEqual(lib.storedSort(for: .folder), PhotoSort(key: .rating, ascending: false))
        XCTAssertEqual(lib.storedSort(for: .photos), PhotoSort(key: .name, ascending: true))
        XCTAssertEqual(lib.settings.lastSource, .folder(path: dir.path))
        XCTAssertEqual(lib.recentSources().map(\.title), ["old"])
        lib.restoreLastSource()
        XCTAssertEqual(lib.folder?.standardizedFileURL, dir.standardizedFileURL)

        let queue = ExportQueue(settings: AppSettings(defaults: defaults))
        XCTAssertEqual(queue.folder?.standardizedFileURL, base.standardizedFileURL)
        XCTAssertEqual(queue.album, "Trips")
        XCTAssertTrue(queue.prefersPhotos)
    }

    func testTheGridReadsTheThumbnailSize() {
        let s = AppSettings(defaults: defaults)
        func minimum() -> CGFloat? {
            guard case .adaptive(let min, _) = GridView.columns(for: s).first?.size else { return nil }
            return min
        }
        XCTAssertEqual(minimum(), 180)
        s.gridThumbnailSize = 260
        XCTAssertEqual(minimum(), 260, "the slider's size is the cells' minimum width")
        guard case .adaptive(_, let max) = GridView.columns(for: s).first?.size else { return XCTFail("adaptive") }
        XCTAssertEqual(max, 377)
    }

    func testPreviewQualityScalesTheFitFrameOnly() {
        XCTAssertEqual(PreviewQuality.full.pixelSize(2000), 2000)
        XCTAssertEqual(PreviewQuality.balanced.pixelSize(2000), 1500)
        XCTAssertEqual(PreviewQuality.fast.pixelSize(2000), 1000)
        XCTAssertEqual(PreviewQuality.fast.pixelSize(1), 1, "never below one pixel")
    }

    func testReopenLastSourceOffSkipsTheReopen() throws {
        let dir = try makeFolder("last")
        Library(rememberFolder: true, defaults: defaults).open(dir)

        let off = Library(rememberFolder: true, defaults: defaults)
        off.settings.reopenLastSource = false
        off.restoreLastSource()
        XCTAssertNil(off.source, "off: the Welcome view")
        XCTAssertEqual(off.recentSources().map(\.title), ["last"], "Open Recent still lists it")

        let on = Library(rememberFolder: true, defaults: defaults)
        XCTAssertFalse(on.settings.reopenLastSource, "the choice is remembered")
        on.settings.reopenLastSource = true
        on.restoreLastSource()
        XCTAssertEqual(on.folder?.standardizedFileURL, dir.standardizedFileURL, "on: the last folder opens")
    }

    func testSettingsSortDrivesTheSortChunksChoice() throws {
        let dir = try makeFolder("s")
        let lib = Library(rememberFolder: true, defaults: defaults)
        // No source open: only remembered.
        lib.setDefaultSort(PhotoSort(key: .name, ascending: false), for: .folder)
        XCTAssertEqual(defaults.string(forKey: "sort.folder"), "name.descending", "the sort chunk's key")
        lib.open(dir)
        XCTAssertEqual(lib.sort, PhotoSort(key: .name, ascending: false), "a folder opens in it")
        XCTAssertEqual(names(lib), ["c.png", "b.png", "a.png"])
        // The open source's kind: it re-sorts at once.
        lib.setDefaultSort(PhotoSort(key: .name, ascending: true), for: .folder)
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(defaults.string(forKey: "sort.folder"), "name.ascending")
        // The other kind: remembered, the open grid untouched.
        lib.setDefaultSort(PhotoSort(key: .rating, ascending: true), for: .photos)
        XCTAssertEqual(lib.sort, PhotoSort(key: .name, ascending: true))
        XCTAssertEqual(lib.defaultSort(for: .photos), PhotoSort(key: .rating, ascending: true))
        // The grid's Sort menu changes what Settings shows.
        lib.sort = PhotoSort(key: .edited, ascending: false)
        XCTAssertEqual(lib.defaultSort(for: .folder), PhotoSort(key: .edited, ascending: false))
        XCTAssertEqual(lib.settings.sort(for: .folder), PhotoSort(key: .edited, ascending: false))
    }

    func testAQuietStoreReadsAndWritesNothing() {
        defaults.set(250, forKey: AppSettings.Key.gridThumbnailSize)
        defaults.set(false, forKey: AppSettings.Key.reopenLastSource)
        let quiet = AppSettings(defaults: defaults, persistent: false)
        XCTAssertEqual(quiet.gridThumbnailSize, AppSettings.defaultThumbnailSize, "reads nothing")
        XCTAssertTrue(quiet.reopenLastSource)
        quiet.gridThumbnailSize = 200
        quiet.previewQuality = .balanced
        quiet.lastSource = .folder(path: "/tmp/q")
        XCTAssertEqual(quiet.gridThumbnailSize, 200, "held in memory")
        XCTAssertEqual(defaults.double(forKey: AppSettings.Key.gridThumbnailSize), 250, "writes nothing")
        XCTAssertNil(defaults.object(forKey: AppSettings.Key.previewQuality))
        XCTAssertNil(defaults.object(forKey: AppSettings.Key.lastFolder))
    }
}
