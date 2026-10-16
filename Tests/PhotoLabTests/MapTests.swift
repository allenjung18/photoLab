import XCTest
import MapKit
@testable import PhotoLab

/// The map (View › Map): pins bucket the photos by a cell size taken from
/// the visible span; the fitted region holds every pin; a photo without a
/// position is left off and counted; the location pass reads each folder
/// photo's header once, through the Info section's store, and stops when
/// cancelled; a Photos asset's position comes with the listing, never a
/// read; a pin click selects its photos with the first as the anchor. No
/// test builds the `Map` view (MapKit's tiles come over the network).
@MainActor
final class MapTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    static let seattleA = GeoPoint(latitude: 47.6062, longitude: -122.3321)
    static let seattleB = GeoPoint(latitude: 47.6205, longitude: -122.3493)
    static let portland = GeoPoint(latitude: 45.5152, longitude: -122.6784)

    private func file(_ name: String) -> Photo { Photo(url: base.appendingPathComponent(name)) }

    // MARK: Pins

    func testPinsGroupByTheCellTheVisibleSpanGives() {
        let a = file("a.jpg"), b = file("b.jpg"), c = file("c.jpg")
        let located = [LocatedPhoto(id: a.id, point: Self.seattleA),
                       LocatedPhoto(id: c.id, point: Self.portland),
                       LocatedPhoto(id: b.id, point: Self.seattleB)]

        // A 12° span: one-degree cells, the two Seattle photos share one.
        let wide = MapPins.cellDegrees(latitudeDelta: 12, longitudeDelta: 6)
        XCTAssertEqual(wide, 1, accuracy: 1e-12)
        let merged = MapPins.group(located, cellDegrees: wide)
        XCTAssertEqual(merged.map(\.photos), [[a.id, b.id], [c.id]], "pins in the order of their first photo")
        XCTAssertEqual(merged.map(\.count), [2, 1])
        XCTAssertEqual(merged[0].first, a.id)
        XCTAssertEqual(merged[0].coordinate.latitude, (Self.seattleA.latitude + Self.seattleB.latitude) / 2,
                       accuracy: 1e-9, "a pin sits at its photos' mean")

        // A 0.012° span (about a kilometre): every photo its own pin.
        let close = MapPins.cellDegrees(latitudeDelta: 0.006, longitudeDelta: 0.012)
        let split = MapPins.group(located, cellDegrees: close)
        XCTAssertEqual(split.map(\.photos), [[a.id], [c.id], [b.id]])
        XCTAssertEqual(Set(split.map(\.id)).count, 3, "one id per cell")
        XCTAssertTrue(MapPins.group([], cellDegrees: wide).isEmpty)
    }

    func testTheRegionFramesEveryPointWithPadding() throws {
        let points = [Self.seattleA, Self.portland, Self.seattleB]
        let region = try XCTUnwrap(MapPins.region(fitting: points))
        XCTAssertEqual(region.center.latitude, (Self.seattleB.latitude + Self.portland.latitude) / 2, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, (Self.seattleA.longitude + Self.portland.longitude) / 2, accuracy: 1e-9,
                       "the extent's middle, not the points' mean")
        XCTAssertEqual(region.span.latitudeDelta,
                       (Self.seattleB.latitude - Self.portland.latitude) * MapPins.padding, accuracy: 1e-9)
        for p in points {
            XCTAssertLessThan(abs(p.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThan(abs(p.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
        XCTAssertNil(MapPins.region(fitting: []))
    }

    func testOnePhotoFramesAboutAKilometre() throws {
        let region = try XCTUnwrap(MapPins.region(fitting: [Self.seattleA]))
        XCTAssertEqual(region.center.latitude, Self.seattleA.latitude, accuracy: 1e-12)
        XCTAssertEqual(region.center.longitude, Self.seattleA.longitude, accuracy: 1e-12)
        XCTAssertEqual(region.span.latitudeDelta * MapPins.metersPerDegree, 1_000, accuracy: 1)
        let eastWest = region.span.longitudeDelta * MapPins.metersPerDegree * cos(Self.seattleA.latitude * .pi / 180)
        XCTAssertEqual(eastWest, 1_000, accuracy: 1, "a kilometre east to west too, at that latitude")
    }

    // MARK: The location pass

    /// A header reader that knows positions by file name, counts its reads,
    /// and can hold the read of one file until released.
    private final class FakeReader: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        let positions: [String: GeoPoint]
        var hold: (name: String, entered: DispatchSemaphore, release: DispatchSemaphore)?

        init(_ positions: [String: GeoPoint]) { self.positions = positions }

        var reads: [String] { lock.lock(); defer { lock.unlock() }; return names }

        func read(_ url: URL) -> PhotoInfo {
            let name = url.lastPathComponent
            lock.lock(); names.append(name); lock.unlock()
            if let hold, hold.name == name {
                hold.entered.signal()
                boundedWait(hold.release, "the test to release \(name)")
            }
            var info = PhotoInfo()
            info.latitude = positions[name]?.latitude
            info.longitude = positions[name]?.longitude
            return info
        }
    }

    private func store(_ reader: FakeReader) -> PhotoInfoStore {
        PhotoInfoStore(captureDates: CaptureDates(reader: { _ in nil }), reader: { reader.read($0) })
    }

    func testAPhotoWithoutAPositionIsLeftOffAndCounted() async {
        let reader = FakeReader(["a.jpg": Self.seattleA])
        let a = file("a.jpg"), b = file("b.jpg")
        let listed = Photo(id: .asset("C/L0/001"), name: nil, location: Self.portland)
        let unlisted = Photo(id: .asset("D/L0/001"), name: nil)
        let photos = [a, b, listed, unlisted]
        let locations = PhotoLocations()
        locations.start(photos, store: store(reader))
        XCTAssertEqual(locations.reading?.total, 2, "the two folder photos are read; the assets are not")
        await locations.waitForPass()

        XCTAssertNil(locations.reading)
        XCTAssertEqual(reader.reads, ["a.jpg", "b.jpg"], "an asset's position is the listing's: no read")
        let located = locations.located(in: photos)
        XCTAssertEqual(located.map(\.id), [a.id, listed.id])
        XCTAssertEqual(located.map(\.point), [Self.seattleA, Self.portland])
        XCTAssertEqual(PhotoLocations.summary(located: located.count, of: photos.count),
                       "2 of 4 photos have a location")
        XCTAssertEqual(PhotoLocations.summary(located: 0, of: 1), "0 of 1 photo has a location")
    }

    func testThePassReadsEachFileOnceAndReusesTheInfoCache() async {
        let reader = FakeReader(["a.jpg": Self.seattleA, "b.jpg": Self.seattleB])
        let infos = store(reader)
        let a = file("a.jpg"), b = file("b.jpg"), c = file("c.jpg")
        // The Info section already read b.
        _ = await infos.info(for: b, file: b.fileURL)
        XCTAssertEqual(reader.reads, ["b.jpg"])

        let locations = PhotoLocations()
        locations.start([a, b, c], store: infos)
        XCTAssertEqual(locations.reading?.total, 2, "b's cached info is used at once")
        XCTAssertEqual(locations.located(in: [a, b, c]).map(\.id), [b.id])
        await locations.waitForPass()
        XCTAssertEqual(reader.reads, ["b.jpg", "a.jpg", "c.jpg"])

        // Leaving the map and coming back reads nothing again.
        locations.cancel()
        locations.start([a, b, c], store: infos)
        XCTAssertNil(locations.reading, "every header is cached: no pass")
        await locations.waitForPass()
        XCTAssertEqual(reader.reads, ["b.jpg", "a.jpg", "c.jpg"])
        XCTAssertEqual(locations.located(in: [a, b, c]).map(\.id), [a.id, b.id])
    }

    func testThePassStopsWhenCancelled() async throws {
        let reader = FakeReader([:])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        reader.hold = ("p2.jpg", entered, release)
        let photos = (1...6).map { file("p\($0).jpg") }
        let locations = PhotoLocations()
        locations.start(photos, store: store(reader))
        // Park the test off the main actor until the second read is in flight.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { boundedWait(entered, "the second read"); c.resume() }
        }
        XCTAssertEqual(locations.reading?.done, 1)
        locations.cancel()
        XCTAssertNil(locations.reading, "a cancelled pass shows no progress")
        release.signal()
        await locations.waitForPass()
        XCTAssertEqual(reader.reads, ["p1.jpg", "p2.jpg"], "nothing is read after the file in flight")
    }

    // MARK: The library

    private func openAlbum(_ assets: [PhotosAsset]) throws -> Library {
        let client = PhotosTests.FakePhotoKit(status: .authorized)
        let album = PhotosAlbum(id: "TRIP/L0/040", title: "Trip", count: assets.count, isRecents: false)
        client.albumList = [album]
        client.assetsByAlbum = [album.id: assets]
        let access = PhotosAccess(client: client, sidecarDirectory: base.appendingPathComponent("sidecars"),
                                  originalsDirectory: base.appendingPathComponent("originals"))
        let lib = Library(rememberFolder: false)
        lib.open(album: album, access: access)
        XCTAssertNil(lib.openError)
        return lib
    }

    func testAPinClickSelectsItsPhotosWithTheFirstAsTheAnchor() async throws {
        let lib = try openAlbum([
            PhotosAsset(id: "A/L0/001", originalFilename: "A.JPG", creationDate: Date(timeIntervalSince1970: 1),
                        location: Self.seattleA),
            PhotosAsset(id: "B/L0/001", originalFilename: "B.JPG", creationDate: Date(timeIntervalSince1970: 2)),
            PhotosAsset(id: "C/L0/001", originalFilename: "C.JPG", creationDate: Date(timeIntervalSince1970: 3),
                        location: Self.seattleB),
        ])
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(lib.photos.map(\.location), [Self.seattleA, nil, Self.seattleB], "the listing carries it")

        lib.selection = ids[1]
        lib.loupe = true
        lib.showMap = true
        XCTAssertFalse(lib.loupe, "the map takes the loupe's place")
        XCTAssertNil(lib.locations.reading, "assets need no read")
        let pins = MapPins.group(lib.locations.located(in: lib.visiblePhotos), cellDegrees: 1)
        XCTAssertEqual(pins.map(\.photos), [[ids[0], ids[2]]])

        lib.clickPin(pins[0])
        XCTAssertEqual(lib.selection, ids[0], "the first photo is the anchor")
        XCTAssertEqual(lib.selectedIDs, [ids[0], ids[2]])
        XCTAssertEqual(lib.batchTargets, [ids[0], ids[2]])
        XCTAssertTrue(lib.showMap, "a click stays on the map")

        // A photo the filter hides is never selected from a pin.
        lib.setFlag(.pick, for: [ids[2]])
        lib.filter = .picks
        lib.clickPin(pins[0])
        XCTAssertEqual(lib.selection, ids[2])
        XCTAssertEqual(lib.selectedIDs, [ids[2]])
        lib.filter = .all

        lib.openPin(pins[0])
        XCTAssertTrue(lib.loupe, "a double-click opens the loupe")
        XCTAssertFalse(lib.showMap)
        XCTAssertEqual(lib.selection, ids[0])
    }

    func testTheMapKeyTogglesAndAnOpenReturnsToTheGrid() throws {
        let lib = try openAlbum([PhotosAsset(id: "A/L0/001", originalFilename: "A.JPG", location: Self.portland)])
        let ctx = CommandContext(library: lib)
        let map = AppCommand.command(.map)
        XCTAssertEqual(map.key, "m")
        XCTAssertEqual(map.modifiers, [.command, .option])
        XCTAssertTrue(map.isEnabled(ctx))
        map.perform(ctx)
        XCTAssertTrue(lib.showMap)
        XCTAssertEqual(map.isOn?(ctx), true)
        XCTAssertEqual(AppCommand.command(.grid).isOn?(ctx), false)
        AppCommand.command(.grid).perform(ctx)
        XCTAssertFalse(lib.showMap)
        XCTAssertEqual(AppCommand.command(.grid).isOn?(ctx), true)
        map.perform(ctx)
        map.perform(ctx)
        XCTAssertFalse(lib.showMap, "the key again leaves the map")

        lib.showMap = true
        XCTAssertEqual(lib.locations.located(in: lib.photos).count, 1)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        lib.open(base.appendingPathComponent("empty"))
        XCTAssertFalse(lib.showMap, "an open returns to the grid")
        XCTAssertTrue(lib.locations.points.isEmpty, "the old source's positions are gone")
        XCTAssertFalse(AppCommand.command(.map).isEnabled(CommandContext(library: lib)), "no photos, no map")
    }
}
