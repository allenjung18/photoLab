import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The loupe panel's Info section (`PhotoInfo`, `PhotoInfoStore`): every
/// field of a tagged fixture formatted, a photo with no EXIF showing only
/// what it has (no blank rows), the units, one header read per photo off
/// the main thread whose capture date the sort then reuses, a Photos asset
/// showing the listing's name and date, the edited state live, and View ›
/// Info (⌘I) remembered.
@MainActor
final class InfoTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "photolab-info-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    /// A 32×16 JPEG tagged orientation 6 (displayed 16×32), with a camera,
    /// a lens, an exposure, a capture date and a position in Seattle (west
    /// longitude).
    private static let tagged: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T-1",
                                         kCGImagePropertyTIFFOrientation: 6],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:15 12:34:56",
                                         kCGImagePropertyExifLensModel: "50mm F1.8",
                                         kCGImagePropertyExifFocalLength: 50.0,
                                         kCGImagePropertyExifFNumber: 2.8,
                                         kCGImagePropertyExifExposureTime: 0.004,
                                         kCGImagePropertyExifISOSpeedRatings: [400]],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6062, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 122.3321, kCGImagePropertyGPSLongitudeRef: "W"],
    ]

    @discardableResult
    private func write(_ name: String, in dir: URL, width: Int = 32, height: Int = 16,
                       properties: [CFString: Any] = [:], type: UTType = .jpeg) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: width, height: height), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func value(_ rows: [PhotoInfo.Row], _ label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    private static func capture(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)!
    }

    // MARK: Reading and formatting

    func testEveryFieldOfATaggedPhotoIsReadAndFormatted() throws {
        let url = try write("tagged.jpg", in: base.appendingPathComponent("shoot"), properties: Self.tagged)
        let info = PhotoInfo.read(url)
        let rows = info.rows(edited: false)
        XCTAssertEqual(rows.map(\.label), PhotoInfo.labels, "every field present, in order")
        XCTAssertEqual(value(rows, "Camera"), "TestCam T-1")
        XCTAssertEqual(value(rows, "Lens"), "50mm F1.8")
        XCTAssertEqual(value(rows, "Focal Length"), "50 mm")
        XCTAssertEqual(value(rows, "Aperture"), "f/2.8")
        XCTAssertEqual(value(rows, "Shutter"), "1/250 s")
        XCTAssertEqual(value(rows, "ISO"), "ISO 400")
        XCTAssertEqual(value(rows, "Dimensions"), "16 × 32", "as displayed: orientation 6 turns it upright")
        XCTAssertEqual(value(rows, "File"), "tagged.jpg")
        let bytes = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(value(rows, "Size"), PhotoInfo.size(Int64(bytes)))
        XCTAssertEqual(value(rows, "Folder"),
                       (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(info.captureDate, Self.capture("2026:10:15 12:34:56"), "EXIF DateTimeOriginal, local time")
        XCTAssertEqual(value(rows, "Captured"), PhotoInfo.date(Self.capture("2026:10:15 12:34:56")))
        XCTAssertEqual(value(rows, "GPS"), "47.60620° N, 122.33210° W", "the W reference makes it west")
        XCTAssertEqual(info.longitude ?? 0, -122.3321, accuracy: 1e-6)
        XCTAssertEqual(value(rows, "Edited"), "No")
    }

    func testAPhotoWithNoExifShowsOnlyWhatItHasAndNoBlankRow() throws {
        let url = try write("plain.png", in: base, width: 20, height: 10, type: .png)
        let rows = PhotoInfo.read(url).rows(edited: true)
        XCTAssertEqual(rows.map(\.label), ["Dimensions", "File", "Size", "Folder", "Captured", "Edited"],
                       "no camera, lens, exposure or GPS rows")
        XCTAssertFalse(rows.contains { $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(value(rows, "Dimensions"), "20 × 10")
        XCTAssertEqual(value(rows, "Edited"), "Yes")

        // Empty or zero values in a header are missing too.
        var odd = PhotoInfo()
        odd.make = "  "
        odd.model = "\0"
        odd.lens = ""
        odd.fNumber = 0
        odd.exposureTime = 0
        odd.iso = 0
        odd.focalLength = 0
        odd.pixelWidth = 0
        odd.pixelHeight = 10
        XCTAssertEqual(odd.rows(edited: false).map(\.label), ["Edited"])
    }

    func testTheUnits() {
        XCTAssertEqual(PhotoInfo.camera(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5",
                       "a model that repeats the make is shown once")
        XCTAssertEqual(PhotoInfo.camera(make: "FUJIFILM ", model: "X-T5"), "FUJIFILM X-T5")
        XCTAssertEqual(PhotoInfo.camera(make: nil, model: "X-T5"), "X-T5")
        XCTAssertEqual(PhotoInfo.camera(make: "Leica", model: nil), "Leica")
        XCTAssertNil(PhotoInfo.camera(make: nil, model: nil))
        XCTAssertEqual(PhotoInfo.focalLength(23.5), "23.5 mm")
        XCTAssertEqual(PhotoInfo.focalLength(35.04), "35 mm")
        XCTAssertEqual(PhotoInfo.aperture(8), "f/8")
        XCTAssertEqual(PhotoInfo.aperture(1.4), "f/1.4")
        XCTAssertEqual(PhotoInfo.shutter(1.0 / 8000), "1/8000 s")
        XCTAssertEqual(PhotoInfo.shutter(0.5), "1/2 s")
        XCTAssertEqual(PhotoInfo.shutter(1), "1 s")
        XCTAssertEqual(PhotoInfo.shutter(2.5), "2.5 s")
        XCTAssertEqual(PhotoInfo.size(1), "1 byte")
        XCTAssertEqual(PhotoInfo.size(512), "512 bytes")
        XCTAssertEqual(PhotoInfo.size(48_230), "48.2 KB")
        XCTAssertEqual(PhotoInfo.size(12_345_678), "12.3 MB")
        XCTAssertEqual(PhotoInfo.size(1_250_000_000), "1.25 GB")
        XCTAssertEqual(PhotoInfo.coordinates(latitude: -33.8568, longitude: 151.2153), "33.85680° S, 151.21530° E")
    }

    // MARK: The store

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var onMain = false
        func add(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            names.append(url.lastPathComponent)
            if Thread.isMainThread { onMain = true }
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        var anyOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    func testAHeaderIsReadOncePerPhotoOffTheMainThreadAndTheSortReusesItsDate() async throws {
        let dir = base.appendingPathComponent("shoot")
        try write("a.jpg", in: dir, properties: Self.tagged)
        try write("b.png", in: dir, type: .png)
        var dateReads: [String] = []
        let dates = CaptureDates(reader: { dateReads.append($0.lastPathComponent); return CaptureDates.read($0) })
        let lib = Library(rememberFolder: false, captureDates: dates)
        lib.open(dir)
        let reads = Reads()
        let store = PhotoInfoStore(captureDates: dates, reader: { reads.add($0); return PhotoInfo.read($0) })
        let a = try XCTUnwrap(lib.photos.first { $0.name == "a.jpg" })

        XCTAssertNil(store.cached(a.id))
        async let first = store.info(for: a, file: a.fileURL)
        async let second = store.info(for: a, file: a.fileURL)
        let (one, two) = await (first, second)
        XCTAssertEqual(one, two)
        _ = await store.info(for: a, file: a.fileURL)
        XCTAssertEqual(reads.all, ["a.jpg"], "one read for three asks, two of them at once")
        XCTAssertFalse(reads.anyOnMain, "the header is read off the main thread")
        XCTAssertEqual(store.cached(a.id)?.make, "TestCam")
        XCTAssertEqual(one.captureDate, Self.capture("2026:10:15 12:34:56"))

        XCTAssertEqual(dates.date(for: a), Self.capture("2026:10:15 12:34:56"))
        XCTAssertTrue(dateReads.isEmpty, "the sort takes the date the Info read found, never reads it again")
    }

    func testWhatTheSortAlreadyKnowsWinsSoTheTwoAgree() async throws {
        let dir = base.appendingPathComponent("shoot")
        try write("a.jpg", in: dir, properties: Self.tagged)
        let known = Date(timeIntervalSince1970: 1_000_000)
        let dates = CaptureDates(reader: { _ in known })
        let lib = Library(rememberFolder: false, captureDates: dates)
        lib.open(dir)
        let a = try XCTUnwrap(lib.photos.first)
        XCTAssertEqual(dates.date(for: a), known)
        let info = await PhotoInfoStore(captureDates: dates).info(for: a, file: a.fileURL)
        XCTAssertEqual(info.captureDate, known)
    }

    func testAPhotosAssetShowsTheListingsNameAndDateAndNoFolder() async throws {
        // The original PhotoKit wrote out, in a cache directory under its
        // own file name.
        let original = try write("ABCD-1234.jpg", in: base.appendingPathComponent("Caches"), properties: Self.tagged)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = Photo(id: .asset("ABCD/L0/001"), name: "IMG_0042.JPG", captureDate: created)
        let store = PhotoInfoStore(captureDates: CaptureDates(reader: { _ in XCTFail("no date read for an asset"); return nil }))

        let before = await store.info(for: asset, file: nil)
        XCTAssertEqual(before.rows(edited: false).map(\.label), ["File", "Captured", "Edited"],
                       "before the original arrives: what the listing gave")
        XCTAssertNil(store.cached(asset.id), "nothing kept without a read")

        let rows = await store.info(for: asset, file: original).rows(edited: false)
        XCTAssertEqual(value(rows, "File"), "IMG_0042.JPG", "the asset's name, not the cache file's")
        XCTAssertNil(value(rows, "Folder"), "the cache copy is not where the user keeps it")
        XCTAssertEqual(value(rows, "Captured"), PhotoInfo.date(created), "the asset's creationDate")
        XCTAssertEqual(value(rows, "Camera"), "TestCam T-1", "the rest from the original")
        XCTAssertEqual(value(rows, "GPS"), "47.60620° N, 122.33210° W")
    }

    // MARK: The library

    func testTheEditedStateIsTheLibrarysAndTheInfoCommandIsRemembered() throws {
        let dir = base.appendingPathComponent("shoot")
        try write("a.jpg", in: dir, properties: Self.tagged)
        let lib = Library(rememberFolder: true, defaults: defaults)
        lib.open(dir)
        let a = try XCTUnwrap(lib.photos.first)
        XCTAssertFalse(lib.isEdited(a.id))
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: a.id)
        XCTAssertEqual(value(PhotoInfoStore.listing(a).rows(edited: lib.isEdited(a.id)), "Edited"), "Yes")

        let command = AppCommand.command(.info)
        XCTAssertEqual(command.key, "i")
        XCTAssertEqual(command.modifiers, .command)
        XCTAssertEqual(command.placement, .view)
        XCTAssertFalse(lib.showInfo, "hidden by default")
        lib.loupe = false
        let context = CommandContext(library: lib)
        command.perform(context)
        XCTAssertTrue(lib.loupe, "from the grid ⌘I opens the loupe")
        XCTAssertTrue(lib.showInfo)
        XCTAssertTrue(command.isOn?(context) ?? false)
        XCTAssertTrue(Library(rememberFolder: true, defaults: defaults).showInfo, "remembered")
        command.perform(context)
        XCTAssertFalse(lib.showInfo, "in the loupe it toggles")
        XCTAssertTrue(lib.loupe)
        XCTAssertFalse(Library(rememberFolder: true, defaults: defaults).showInfo)
        XCTAssertFalse(Library(rememberFolder: false, defaults: defaults).showInfo)
    }
}
