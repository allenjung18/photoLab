import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The grid's order (`PhotoSort`): each key in both directions, ties by
/// name, photos with no capture date last, one function for a folder and a
/// Photos-like source, capture dates read once (EXIF, else the file's
/// date), the selection kept across a re-sort, the filmstrip and the arrows
/// following it, and the choice remembered per source kind.
@MainActor
final class SortTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-sort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "photolab-sort-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    private static func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// A JPEG whose EXIF `DateTimeOriginal` is `exif`, or a PNG with no
    /// EXIF whose file creation date is `fileDate`.
    @discardableResult
    private func writePhoto(_ name: String, in dir: URL, exif: String? = nil, fileDate: Date? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let type: UTType = exif != nil ? .jpeg : .png
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let exif {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exif]
        }
        CGImageDestinationAddImage(dest, syntheticImage(width: 16, height: 12), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        if let fileDate {
            try FileManager.default.setAttributes([.creationDate: fileDate, .modificationDate: fileDate],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    /// a.jpg shot 3 Jan, b.jpg shot 2 Jan (EXIF), c.png no EXIF, file dated 2020.
    private func folder() throws -> URL {
        let dir = base.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePhoto("a.jpg", in: dir, exif: "2024:01:03 10:00:00")
        try writePhoto("b.jpg", in: dir, exif: "2024:01:02 10:00:00")
        try writePhoto("c.png", in: dir, fileDate: Self.day(2020, 6, 1))
        return dir
    }

    private func names(_ lib: Library) -> [String] { lib.photos.map(\.name) }

    /// A source that is not a folder (sorts like a Photos album), whose
    /// listing carries capture dates the way `PhotosSource` does.
    private struct AlbumSource: PhotoSource {
        var title = "Album"
        var listed: [Photo]
        var directory: URL
        func photos() throws -> [Photo] { listed }
        var sidecars: SidecarStore { SidecarStore(directory: directory, naming: .flat) }
        func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? { nil }
        func originalFile(for id: PhotoID) async throws -> URL { throw PhotoSourceError.notInThisSource(id) }
    }

    private func album() throws -> AlbumSource {
        let dir = base.appendingPathComponent("album-sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AlbumSource(listed: [
            Photo(id: .asset("Z/L0/001"), name: "IMG_0010.HEIC", captureDate: Self.day(2024, 3, 2)),
            Photo(id: .asset("Y/L0/001"), name: "IMG_0002.HEIC", captureDate: nil),
            Photo(id: .asset("X/L0/001"), name: "IMG_0001.HEIC", captureDate: Self.day(2024, 3, 1)),
        ], directory: dir)
    }

    // MARK: The function

    private let rows: [Photo] = [
        Photo(id: .file(URL(fileURLWithPath: "/s/IMG_10.jpg")), name: "IMG_10.jpg", captureDate: SortTests.day(2024, 1, 2)),
        Photo(id: .asset("B/L0/001"), name: "IMG_2.heic", captureDate: SortTests.day(2024, 1, 1)),
        Photo(id: .file(URL(fileURLWithPath: "/s/IMG_3.jpg")), name: "IMG_3.jpg", captureDate: nil),
        Photo(id: .asset("D/L0/001"), name: "IMG_1.heic", captureDate: SortTests.day(2024, 1, 3)),
    ]
    private let ratings: [String: Int] = ["IMG_10.jpg": 3, "IMG_2.heic": 5, "IMG_3.jpg": 3, "IMG_1.heic": 0]
    private let edits: Set<String> = ["IMG_3.jpg", "IMG_1.heic"]

    private func order(_ key: SortKey, ascending: Bool) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
        return PhotoSort(key: key, ascending: ascending).sorted(
            rows, captureDate: \.captureDate,
            rating: { self.ratings[byID[$0]!]! }, edited: { self.edits.contains(byID[$0]!) }).map(\.name)
    }

    func testEachKeyInBothDirectionsFilesAndAssetsThroughOneFunction() {
        XCTAssertEqual(order(.captureDate, ascending: true), ["IMG_2.heic", "IMG_10.jpg", "IMG_1.heic", "IMG_3.jpg"])
        XCTAssertEqual(order(.captureDate, ascending: false), ["IMG_1.heic", "IMG_10.jpg", "IMG_2.heic", "IMG_3.jpg"],
                       "the undated photo is last in both directions")
        XCTAssertEqual(order(.name, ascending: true), ["IMG_1.heic", "IMG_2.heic", "IMG_3.jpg", "IMG_10.jpg"],
                       "Finder's order: IMG_2 before IMG_10")
        XCTAssertEqual(order(.name, ascending: false), ["IMG_10.jpg", "IMG_3.jpg", "IMG_2.heic", "IMG_1.heic"])
        XCTAssertEqual(order(.rating, ascending: false), ["IMG_2.heic", "IMG_3.jpg", "IMG_10.jpg", "IMG_1.heic"],
                       "the two 3-star photos tie and go by name, IMG_3 before IMG_10")
        XCTAssertEqual(order(.rating, ascending: true), ["IMG_1.heic", "IMG_3.jpg", "IMG_10.jpg", "IMG_2.heic"],
                       "a tie goes by name ascending whatever the direction")
        XCTAssertEqual(order(.edited, ascending: false), ["IMG_1.heic", "IMG_3.jpg", "IMG_2.heic", "IMG_10.jpg"],
                       "descending: edited first, each group by name")
        XCTAssertEqual(order(.edited, ascending: true), ["IMG_2.heic", "IMG_10.jpg", "IMG_1.heic", "IMG_3.jpg"])
    }

    func testTiesAndMissingDatesAreTotalAndStable() {
        let same = Self.day(2024, 5, 5)
        let photos = [
            Photo(id: .asset("C"), name: "b.jpg", captureDate: same),
            Photo(id: .asset("B"), name: "a.jpg", captureDate: nil),
            Photo(id: .asset("A"), name: "b.jpg", captureDate: same),
            Photo(id: .asset("D"), name: "a.jpg", captureDate: same),
            Photo(id: .asset("E"), name: "0.jpg", captureDate: nil),
        ]
        let sort = PhotoSort(key: .captureDate, ascending: true)
        let once = sort.sorted(photos, captureDate: \.captureDate, rating: { _ in 0 }, edited: { _ in false })
        XCTAssertEqual(once.map(\.id), [.asset("D"), .asset("A"), .asset("C"), .asset("E"), .asset("B")],
                       "equal dates by name then id; the two undated last, by name")
        let again = sort.sorted(once.reversed(), captureDate: \.captureDate, rating: { _ in 0 }, edited: { _ in false })
        XCTAssertEqual(again, once, "the order does not depend on the input order")
    }

    func testTheStorageKeyRoundTripsAndRejectsJunk() {
        for key in SortKey.allCases {
            for asc in [true, false] {
                let s = PhotoSort(key: key, ascending: asc)
                XCTAssertEqual(PhotoSort(storageKey: s.storageKey), s)
            }
        }
        XCTAssertEqual(PhotoSort.photosDefault.storageKey, "captureDate.ascending")
        XCTAssertNil(PhotoSort(storageKey: "size.ascending"))
        XCTAssertNil(PhotoSort(storageKey: "name.up"))
        XCTAssertNil(PhotoSort(storageKey: ""))
    }

    // MARK: Capture dates

    func testCaptureDateIsExifElseTheFileDateAndIsReadOncePerPhoto() throws {
        let dir = try folder()
        XCTAssertEqual(CaptureDates.read(dir.appendingPathComponent("b.jpg")), Self.day(2024, 1, 2),
                       "EXIF DateTimeOriginal, in local time")
        XCTAssertNil(CaptureDates.exifDate(dir.appendingPathComponent("c.png")))
        XCTAssertEqual(CaptureDates.read(dir.appendingPathComponent("c.png")), Self.day(2020, 6, 1),
                       "no EXIF: the file's creation date")

        var reads: [String] = []
        let lib = Library(rememberFolder: false,
                          captureDates: CaptureDates(reader: { reads.append($0.lastPathComponent); return CaptureDates.read($0) }))
        lib.open(dir)
        XCTAssertEqual(lib.sort, .folderDefault)
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"])
        XCTAssertTrue(reads.isEmpty, "the name sort reads no dates")

        lib.sort = PhotoSort(key: .captureDate, ascending: true)
        XCTAssertEqual(names(lib), ["c.png", "b.jpg", "a.jpg"])
        lib.sort.ascending = false
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"])
        lib.resort()
        XCTAssertEqual(reads.sorted(), ["a.jpg", "b.jpg", "c.png"], "each file read once, then cached")
    }

    func testAFolderAndAnAlbumSortThroughTheSameRule() throws {
        let lib = Library(rememberFolder: false)
        lib.open(try album())
        XCTAssertEqual(lib.sort, .photosDefault, "an album opens oldest capture first")
        XCTAssertEqual(names(lib), ["IMG_0001.HEIC", "IMG_0010.HEIC", "IMG_0002.HEIC"],
                       "the listing's dates, the undated photo last")
        lib.sort = PhotoSort(key: .name, ascending: true)
        XCTAssertEqual(names(lib), ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0010.HEIC"])

        lib.open(try folder())
        XCTAssertEqual(lib.sort, .folderDefault, "nothing remembered: a folder opens by name")
        lib.sort = PhotoSort(key: .captureDate, ascending: true)
        let expected = lib.sort.sorted(lib.photos, captureDate: { CaptureDates.read($0.fileURL!) },
                                       rating: { _ in 0 }, edited: { _ in false })
        XCTAssertEqual(lib.photos, expected, "the library's order is PhotoSort's")
    }

    // MARK: The library

    func testSelectionAndAnchorSurviveAReSortAndTheArrowsAndFilmstripFollowIt() throws {
        let lib = Library(rememberFolder: false)
        lib.open(try folder())
        let a = lib.photos[0].id, b = lib.photos[1].id
        lib.click(a)
        lib.click(b, toggling: true)
        XCTAssertEqual(lib.selection, b)
        lib.loupe = true

        lib.sort = PhotoSort(key: .captureDate, ascending: true)   // c, b, a
        XCTAssertEqual(lib.selection, b, "the anchor stays")
        XCTAssertEqual(lib.selectedIDs, [a, b], "the multi-selection stays")
        XCTAssertTrue(lib.loupe, "the loupe stays open")
        XCTAssertEqual(lib.visibleIndex, 1, "b is second in capture order")
        XCTAssertEqual(Filmstrip.items(for: lib).map(\.photo.name), ["c.png", "b.jpg", "a.jpg"])
        XCTAssertEqual(lib.batchTargets.map { lib.name(for: $0) }, ["b.jpg", "a.jpg"], "targets in sort order")

        lib.select(offset: 1)
        XCTAssertEqual(lib.selectedPhoto?.name, "a.jpg", "→ walks the sort order")
        lib.select(offset: -2)
        XCTAssertEqual(lib.selectedPhoto?.name, "c.png")
    }

    func testARatingOrAnEditMovesThePhotoUnderItsSort() throws {
        let lib = Library(rememberFolder: false)
        lib.open(try folder())
        let c = try XCTUnwrap(lib.photos.first { $0.name == "c.png" }).id
        lib.sort = PhotoSort(key: .rating, ascending: false)
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"], "all unrated: by name")
        lib.setRating(4, for: [c])
        XCTAssertEqual(names(lib), ["c.png", "a.jpg", "b.jpg"], "the rated photo moves up at once")

        lib.sort = PhotoSort(key: .edited, ascending: false)
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"])
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: c)
        XCTAssertEqual(names(lib), ["c.png", "a.jpg", "b.jpg"], "an edit moves it among the edited")
        lib.selection = c
        lib.undo()
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"], "and undo moves it back")
        XCTAssertEqual(lib.selection, c, "the anchor follows the photo, not the position")
    }

    func testTheSortIsRememberedPerSourceKindInTheInjectedDefaults() throws {
        let dir = try folder()
        let lib = Library(rememberFolder: true, defaults: defaults)
        lib.open(dir)
        XCTAssertEqual(lib.sort, .folderDefault)
        XCTAssertNil(defaults.string(forKey: "sort.folder"), "opening writes nothing")
        lib.sort = PhotoSort(key: .rating, ascending: false)
        XCTAssertEqual(defaults.string(forKey: "sort.folder"), "rating.descending")

        lib.open(try album())
        XCTAssertEqual(lib.sort, .photosDefault, "an album keeps its own kind's choice")
        lib.sort = PhotoSort(key: .name, ascending: false)
        XCTAssertEqual(defaults.string(forKey: "sort.photos"), "name.descending")
        XCTAssertEqual(defaults.string(forKey: "sort.folder"), "rating.descending", "the folder choice is untouched")

        let again = Library(rememberFolder: true, defaults: defaults)
        again.open(dir)
        XCTAssertEqual(again.sort, PhotoSort(key: .rating, ascending: false), "the folder's choice comes back")
        again.open(try album())
        XCTAssertEqual(again.sort, PhotoSort(key: .name, ascending: false))
        XCTAssertEqual(names(again), ["IMG_0010.HEIC", "IMG_0002.HEIC", "IMG_0001.HEIC"], "and the order with it")

        let isolated = Library(rememberFolder: false, defaults: defaults)
        isolated.open(dir)
        XCTAssertEqual(isolated.sort, .folderDefault, "rememberFolder: false reads nothing")
        isolated.sort = PhotoSort(key: .edited, ascending: true)
        XCTAssertEqual(defaults.string(forKey: "sort.folder"), "rating.descending", "and writes nothing")
    }

    // MARK: Commands

    func testTheSortCommandsCheckTheChoiceAndSetIt() throws {
        let lib = Library(rememberFolder: false)
        let context = CommandContext(library: lib)
        let items = AppCommand.items(in: .sort)
        XCTAssertEqual(items.map(\.title), ["Capture Date", "Name", "Rating", "Edited", "Ascending", "Descending"])
        XCTAssertTrue(items.allSatisfy { $0.key == nil }, "the sort has no keys")
        XCTAssertFalse(items.contains { $0.isEnabled(context) }, "nothing to sort before a source is open")

        lib.open(try folder())
        XCTAssertTrue(items.allSatisfy { $0.isEnabled(context) })
        XCTAssertEqual(items.filter { $0.isOn?(context) == true }.map(\.title), ["Name", "Ascending"])
        AppCommand.command(.sortCaptureDate).perform(context)
        AppCommand.command(.sortDescending).perform(context)
        XCTAssertEqual(lib.sort, PhotoSort(key: .captureDate, ascending: false))
        XCTAssertEqual(items.filter { $0.isOn?(context) == true }.map(\.title), ["Capture Date", "Descending"])
        XCTAssertEqual(names(lib), ["a.jpg", "b.jpg", "c.png"])
    }
}
