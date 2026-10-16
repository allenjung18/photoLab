import XCTest
import AppKit
@testable import PhotoLab

/// A large Photos Recents opens without blocking (C-09): the listing is
/// identifiers and capture dates only, so 5,000 assets open inside a frame
/// budget with no name read; a name is asked only for a cell that is on
/// screen (`Library.resolveName`), off the main thread; a cell scrolled
/// away before its read lands writes nothing; a sort by name names every
/// photo first and sorts once; an export names its output from the asset's
/// own name though no cell asked for it.
@MainActor
final class PhotosLazyTests: XCTestCase {
    private var base: URL!
    private var sidecarDir: URL!
    private var originalsDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-lazy-\(UUID().uuidString)", isDirectory: true)
        sidecarDir = base.appendingPathComponent("sidecars", isDirectory: true)
        originalsDir = base.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// PhotoKit as the live client lists: no name in the listing, a name
    /// read per asset that costs `nameCost` and is counted, optionally held
    /// on a gate (the cancellation test).
    final class LazyPhotoKit: PhotoKitClient, @unchecked Sendable {
        private let lock = NSLock()
        let album: PhotosAlbum
        let listing: [PhotosAsset]
        let names: [String: String]
        var nameCost: TimeInterval = 0.000_05
        var nameGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        private(set) var named: [String] = []
        private(set) var sawCancel = 0
        private(set) var namedOnMain = 0

        init(count: Int, title: String = "Recents") {
            album = PhotosAlbum(id: "RECENTS/L0/040", title: title, count: count, isRecents: true)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            var listing: [PhotosAsset] = []
            var names: [String: String] = [:]
            for i in 0..<count {
                // Identifier order is a scramble of capture order (13 is
                // prime to every count here), so an order by id shows.
                let id = String(format: "%08X-0000/L0/001", (i * 13) % count)
                listing.append(PhotosAsset(id: id, originalFilename: nil, creationDate: start.addingTimeInterval(Double(i) * 60)))
                // Names run against capture order: the newest is IMG_00000.
                names[id] = String(format: "IMG_%05d.HEIC", count - 1 - i)
            }
            self.listing = listing
            self.names = names
        }

        var nameCalls: Int { lock.lock(); defer { lock.unlock() }; return named.count }

        func authorizationStatus() -> PhotosAuthorization { .authorized }
        func requestAuthorization() async -> PhotosAuthorization { .authorized }
        func albums() -> [PhotosAlbum] { [album] }
        func assets(in album: PhotosAlbum) -> [PhotosAsset] { listing }
        func originalFilename(of assetID: String) -> String? {
            lock.lock()
            named.append(assetID)
            if Thread.isMainThread { namedOnMain += 1 }
            lock.unlock()
            if let gate = nameGate {
                gate.entered.signal()
                gate.release.wait()
                if Task.isCancelled { lock.lock(); sawCancel += 1; lock.unlock() }
            }
            if nameCost > 0 { Thread.sleep(forTimeInterval: nameCost) }
            return names[assetID]
        }
        func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage? { nil }
        func writeOriginal(of assetID: String, to url: URL) async throws {
            try Data("original of \(assetID)".utf8).write(to: url)
        }
        func hasAdjustments(_ assetID: String) -> Bool { false }
        func adjustment(of assetID: String) async throws -> PhotosAdjustment? { nil }
        func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                      render: @escaping @Sendable (URL) throws -> Void) async throws {
            throw PhotosError.cannotEdit(assetID)
        }
    }

    private func access(_ client: LazyPhotoKit) -> PhotosAccess {
        PhotosAccess(client: client, sidecarDirectory: sidecarDir, originalsDirectory: originalsDir)
    }

    private func library() -> Library { Library(rememberFolder: false) }

    nonisolated private static func waitFor(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 5)
    }

    /// One sidecar on disk, as a Recents with a few edits has.
    private func writeSidecar(for assetID: String, exposure: Double) throws {
        var recipe = Recipe.neutral
        recipe[.exposure].value = exposure
        try SidecarStore(directory: sidecarDir, naming: .flat).save(recipe, for: .asset(assetID), name: "x")
    }

    // MARK: Opening

    func testFiveThousandAssetsOpenInsideAFrameBudgetWithNoNameRead() throws {
        let client = LazyPhotoKit(count: 5000)
        try writeSidecar(for: client.listing[17].id, exposure: 0.5)
        let access = access(client)

        // Up to three opens, the best counts (see `assertFrameBudget`).
        var best = Double.infinity
        var lib = library()
        for _ in 0..<3 {
            lib = library()
            let start = DispatchTime.now().uptimeNanoseconds
            lib.open(album: client.album, access: access)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if best < Self.openBudget { break }
        }

        XCTAssertNil(lib.openError)
        XCTAssertEqual(lib.photos.count, 5000, "the grid has every cell at once, from the listing")
        XCTAssertEqual(client.nameCalls, 0, "opening reads no name: names are asked per visible cell")
        XCTAssertTrue(lib.photos.allSatisfy { !$0.isNamed }, "every photo opens unnamed")
        XCTAssertEqual(lib.photos.map(\.id), client.listing.map { .asset($0.id) },
                       "capture order (the album default) needs no name")
        XCTAssertEqual(lib.recipe(for: .asset(client.listing[17].id))[.exposure].value, 0.5,
                       "the one sidecar among 5,000 is found by one directory listing")
        XCTAssertEqual(lib.photos[0].caption, "", "an unnamed cell shows no caption, never the identifier")
        try assertFrameBudget(best, bound: Self.openBudget, load: loadAverage(),
                              "opening 5,000 Photos assets must not hold the main thread")
    }

    /// Opening a 5,000-asset album on the main thread, debug build: three
    /// frames (the listing, 5,000 rows, one sidecar directory listing, the
    /// capture-date sort). Measured 16.6–16.8 ms at a 1-minute load of 7.4
    /// on 2026-10-15; the eager name read alone is 5,000 × 50 µs = 250 ms
    /// here, so the mutant that reads names at open misses by five times.
    static let openBudget: Double = 50

    // MARK: Per visible cell

    func testOnlyVisibleCellsAskForTheirNamesAndTheReadIsOffTheMainThread() async throws {
        let client = LazyPhotoKit(count: 5000)
        let lib = library()
        lib.open(album: client.album, access: access(client))

        // The first screen of cells (24) asks, as their `.task`s do.
        let visible = Array(lib.photos.prefix(24).map(\.id))
        await withTaskGroup(of: Void.self) { group in
            for id in visible { group.addTask { await lib.resolveName(id) } }
        }

        XCTAssertEqual(Set(client.named), Set(visible.compactMap { if case .asset(let a) = $0 { return a } else { return nil } }),
                       "names are read for the visible indices only")
        XCTAssertEqual(client.nameCalls, 24, "once each")
        XCTAssertEqual(client.namedOnMain, 0, "every read runs off the main thread")
        XCTAssertEqual(lib.photos.prefix(24).map(\.name), (0..<24).map { String(format: "IMG_%05d.HEIC", 4999 - $0) })
        XCTAssertTrue(lib.photos.dropFirst(24).allSatisfy { !$0.isNamed }, "a cell never shown stays unnamed")
        XCTAssertEqual(lib.photos.map(\.id), client.listing.map { .asset($0.id) }, "a name landing moves nothing")

        // A named photo, or one not in the album, asks nothing.
        await lib.resolveName(visible[0])
        await lib.resolveName(.asset("NOT/L0/001"))
        XCTAssertEqual(client.nameCalls, 24)
    }

    func testACellScrolledAwayBeforeItsNameLandsWritesNothing() async throws {
        let client = LazyPhotoKit(count: 50)
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        client.nameGate = gate
        let lib = library()
        lib.open(album: client.album, access: access(client))
        let id = lib.photos[3].id

        let cell = Task { await lib.resolveName(id) }
        // The read has started (waited for off the main actor, which the
        // cell's task needs to get going).
        let started = await Task.detached { Self.waitFor(gate.entered) }.value
        XCTAssertEqual(started, .success, "the client was asked")
        cell.cancel()               // the cell left the screen
        gate.release.signal()
        await cell.value

        XCTAssertEqual(client.nameCalls, 1)
        XCTAssertEqual(client.sawCancel, 1, "the cell's cancellation reaches the read")
        XCTAssertFalse(lib.photos[3].isNamed, "a cancelled cell does not write its name")
        XCTAssertEqual(lib.name(for: id), id.defaultName)

        // Scrolled back: the cell asks again and this time it lands.
        client.nameGate = nil
        await lib.resolveName(id)
        XCTAssertEqual(lib.photos[3].name, "IMG_00046.HEIC")
    }

    func testAReadForAnEarlierSourceIsDropped() async throws {
        let client = LazyPhotoKit(count: 10)
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        client.nameGate = gate
        let lib = library()
        lib.open(album: client.album, access: access(client))
        let id = lib.photos[0].id

        let cell = Task { await lib.resolveName(id) }
        let started = await Task.detached { Self.waitFor(gate.entered) }.value
        XCTAssertEqual(started, .success)
        client.nameGate = nil
        lib.open(album: client.album, access: access(client))   // reopened meanwhile
        gate.release.signal()
        await cell.value

        XCTAssertFalse(lib.photos[0].isNamed, "the old open's read is not written into the new one")
    }

    // MARK: The sort and the export

    func testSortByNameNamesEveryPhotoFirstThenSortsOnce() async throws {
        let client = LazyPhotoKit(count: 40)
        let lib = library()
        lib.open(album: client.album, access: access(client))
        let captureOrder = lib.photos.map(\.id)

        lib.sort = PhotoSort(key: .name, ascending: true)
        XCTAssertEqual(lib.photos.map(\.id), captureOrder,
                       "until the names are in, the album keeps its order (never an order by identifier)")
        let pass = try XCTUnwrap(lib.namingAll, "the sort starts the naming pass")
        await pass.value

        XCTAssertEqual(client.nameCalls, 40, "every photo named, once")
        XCTAssertEqual(client.namedOnMain, 0)
        XCTAssertTrue(lib.photos.allSatisfy(\.isNamed))
        XCTAssertEqual(lib.photos.map(\.name), (0..<40).map { String(format: "IMG_%05d.HEIC", $0) },
                       "then sorted by name (here the reverse of capture order)")
        XCTAssertNil(lib.namingAll)

        lib.sort = PhotoSort(key: .name, ascending: false)
        XCTAssertNil(lib.namingAll, "all named: a re-sort reads nothing")
        XCTAssertEqual(lib.photos.first?.name, "IMG_00039.HEIC")
        XCTAssertEqual(client.nameCalls, 40)
    }

    func testUnnamedPhotosSortAfterNamedOnesByIdInEitherDirection() {
        let rows = [
            Photo(id: .asset("C/L0/001"), name: nil),
            Photo(id: .asset("Z/L0/001"), name: "b.heic"),
            Photo(id: .asset("A/L0/001"), name: nil),
            Photo(id: .asset("Y/L0/001"), name: "a.heic"),
        ]
        func order(_ ascending: Bool) -> [String] {
            PhotoSort(key: .name, ascending: ascending)
                .sorted(rows, captureDate: { _ in nil }, rating: { _ in 0 }, edited: { _ in false })
                .map { $0.isNamed ? $0.name : $0.id.defaultName }
        }
        XCTAssertEqual(order(true), ["a.heic", "b.heic", "A/L0/001", "C/L0/001"])
        XCTAssertEqual(order(false), ["b.heic", "a.heic", "A/L0/001", "C/L0/001"])
    }

    func testAnExportNamesItsOutputFromTheAssetsOwnNameThoughNoCellAsked() async throws {
        let client = LazyPhotoKit(count: 30)
        let lib = library()
        lib.open(album: client.album, access: access(client))
        let id = lib.photos[29].id
        XCTAssertFalse(lib.photos[29].isNamed)

        let items = try await lib.exportItems(for: [id])

        XCTAssertEqual(items.first?.name, "IMG_00000.HEIC")
        XCTAssertEqual(items.first?.source.pathExtension, "HEIC", "the cached original takes the name's extension")
        XCTAssertEqual(lib.photos[29].name, "IMG_00000.HEIC")
        XCTAssertEqual(PhotoInfoStore.listing(lib.photos[29]).fileName, "IMG_00000.HEIC")
        XCTAssertNil(PhotoInfoStore.listing(lib.photos[0]).fileName, "an unnamed photo has no File row yet")
    }
}
