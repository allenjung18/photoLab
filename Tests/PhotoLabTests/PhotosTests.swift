import XCTest
import AppKit
import Photos
import UniformTypeIdentifiers
@testable import PhotoLab

/// `PhotosSource` behind a fake `PhotoKitClient`: nothing is fetched before
/// access is allowed and the Allow button is the only prompt; Recents is
/// first and an album opens in the client's order with the originals'
/// names; a thumbnail request cancelled in flight reaches the client
/// through the shared decoder rule; an original is written once; the last
/// source is remembered by kind and never prompts at launch. The two real
/// tests skip unless this process is ALREADY authorized (`xctest` is not,
/// so they skip under `swift test`); no test ever requests authorization.
@MainActor
final class PhotosTests: XCTestCase {
    private var base: URL!
    private var sidecarDir: URL!
    private var originalsDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-photos-\(UUID().uuidString)", isDirectory: true)
        sidecarDir = base.appendingPathComponent("sidecars", isDirectory: true)
        originalsDir = base.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: The fake

    /// A complete in-memory PhotoKit: a status that `requestAuthorization`
    /// turns into `grant`, albums with their assets, a 4 px thumbnail, and
    /// an original that is the bytes "original of <id>". Every call is
    /// counted; the thumbnail can be held on a semaphore (cancellation) and
    /// the write can be held or made to fail.
    final class FakePhotoKit: PhotoKitClient, @unchecked Sendable {
        private let lock = NSLock()
        private var status: PhotosAuthorization
        var grant = PhotosAuthorization.authorized
        var albumList: [PhotosAlbum] = []
        var assetsByAlbum: [String: [PhotosAsset]] = [:]
        private(set) var requestCalls = 0, albumsCalls = 0, assetsCalls = 0, thumbnailCalls = 0, writeCalls = 0
        /// When set, `thumbnail` signals `entered`, waits on `release`, then
        /// counts `sawCancel` if its task was cancelled meanwhile.
        var thumbnailGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        private(set) var sawCancel = 0
        var writeHold: DispatchSemaphore?
        var failWrites = false

        init(status: PhotosAuthorization) {
            self.status = status
        }

        private func count(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }

        func authorizationStatus() -> PhotosAuthorization { lock.lock(); defer { lock.unlock() }; return status }
        func requestAuthorization() async -> PhotosAuthorization {
            count { requestCalls += 1; status = grant }
            return authorizationStatus()
        }
        func albums() -> [PhotosAlbum] {
            count { albumsCalls += 1 }
            return albumList
        }
        func assets(in album: PhotosAlbum) -> [PhotosAsset] {
            count { assetsCalls += 1 }
            return assetsByAlbum[album.id] ?? []
        }
        func originalFilename(of assetID: String) -> String? {
            assetsByAlbum.values.lazy.compactMap { $0.first { $0.id == assetID } }.first?.originalFilename
        }
        func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage? {
            count { thumbnailCalls += 1 }
            guard assetsByAlbum.values.contains(where: { $0.contains { $0.id == assetID } }) else { return nil }
            if let gate = thumbnailGate {
                gate.entered.signal()
                boundedWait(gate.release, "the test to release the thumbnail")
                if Task.isCancelled { count { sawCancel += 1 } }
            }
            return NSImage(size: NSSize(width: 4, height: 4))
        }
        func writeOriginal(of assetID: String, to url: URL) async throws {
            count { writeCalls += 1 }
            // A held write parks on a plain thread, never a cooperative one.
            if let hold = writeHold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    Thread.detachNewThread { boundedWait(hold, "the test to release the write"); c.resume() }
                }
            }
            if failWrites { throw PhotosError.noOriginal(assetID) }
            try Data("original of \(assetID)".utf8).write(to: url)
        }
        // No asset here carries an edit (adjustment data: AdjustmentDataTests).
        func hasAdjustments(_ assetID: String) -> Bool { false }
        func adjustment(of assetID: String) async throws -> PhotosAdjustment? { nil }
        func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                      render: @escaping @Sendable (URL) throws -> Void) async throws {
            throw PhotosError.cannotEdit(assetID)
        }
    }

    static let recents = PhotosAlbum(id: "RECENTS/L0/040", title: "Recents", count: 3, isRecents: true)
    static let trip = PhotosAlbum(id: "TRIP/L0/040", title: "Trip", count: 2, isRecents: false)
    static let shoot: [PhotosAsset] = [
        PhotosAsset(id: "C/L0/001", originalFilename: "DSC00003.ARW", creationDate: Date(timeIntervalSince1970: 1_000)),
        PhotosAsset(id: "A/L0/001", originalFilename: "IMG_0001.HEIC", creationDate: Date(timeIntervalSince1970: 2_000)),
        PhotosAsset(id: "B/L0/001", originalFilename: "IMG_0002.JPG", creationDate: Date(timeIntervalSince1970: 3_000)),
    ]

    private func fake(status: PhotosAuthorization) -> FakePhotoKit {
        let f = FakePhotoKit(status: status)
        f.albumList = [Self.recents, Self.trip]
        f.assetsByAlbum = [Self.recents.id: Self.shoot, Self.trip.id: [Self.shoot[1], Self.shoot[0]]]
        return f
    }

    private func writePNG(_ side: Int, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: side, height: side), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func access(_ client: FakePhotoKit) -> PhotosAccess {
        PhotosAccess(client: client, sidecarDirectory: sidecarDir, originalsDirectory: originalsDir)
    }

    // MARK: Authorization

    func testNothingIsFetchedBeforeAccessIsAllowedAndTheAllowClickIsTheOnlyPrompt() async throws {
        let client = fake(status: .notDetermined)
        let access = access(client)

        // The sheet's model: no albums, nothing asked of the library.
        let browser = PhotosBrowser(access: access)
        XCTAssertEqual(browser.status, .notDetermined)
        XCTAssertTrue(browser.albums.isEmpty)
        XCTAssertEqual(client.albumsCalls, 0, "albums are not listed before access")
        XCTAssertEqual(client.requestCalls, 0, "opening the sheet never prompts")

        // A source: refused by the library, no asset or thumbnail fetched.
        let source = access.source(for: Self.recents)
        XCTAssertThrowsError(try source.photos()) { error in
            XCTAssertEqual(error as? PhotosError, .notAuthorized(.notDetermined))
        }
        let lib = Library(rememberFolder: false)
        lib.open(album: Self.recents, access: access)
        XCTAssertEqual(lib.openError, PhotosError.notAuthorized(.notDetermined).errorDescription)
        XCTAssertNil(lib.source, "the album is not opened")
        XCTAssertNil(source.thumbnail(for: .asset("A/L0/001"), maxPixelSize: 480))
        XCTAssertEqual(client.assetsCalls, 0)
        XCTAssertEqual(client.thumbnailCalls, 0)

        // The user's click: one prompt, then the albums.
        await browser.requestAccess()
        XCTAssertEqual(client.requestCalls, 1)
        XCTAssertEqual(browser.status, .authorized)
        XCTAssertEqual(browser.albums, [Self.recents, Self.trip])
        XCTAssertEqual(client.albumsCalls, 1)
        lib.open(album: Self.recents, access: access)
        XCTAssertNil(lib.openError)
        XCTAssertEqual(lib.photos.count, 3)

        // Refused: no albums, and the status says which refusal.
        let denied = fake(status: .notDetermined)
        denied.grant = .denied
        let refused = PhotosBrowser(access: self.access(denied))
        await refused.requestAccess()
        XCTAssertEqual(refused.status, .denied)
        XCTAssertFalse(refused.status.canRead)
        XCTAssertTrue(refused.albums.isEmpty)
        XCTAssertEqual(denied.albumsCalls, 0)
        XCTAssertEqual(PhotosBrowser.settingsURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(PhotosAuthorization.limited.canRead, "a limited grant reads")
        XCTAssertEqual(PhotosAuthorization(.authorized), .authorized)
        XCTAssertEqual(PhotosAuthorization(.denied), .denied)
        XCTAssertEqual(PhotosAuthorization(.notDetermined), .notDetermined)
    }

    // MARK: Albums and order

    func testRecentsIsFirstAndAnAlbumOpensOldestCaptureFirstWithTheOriginalsNames() throws {
        let client = fake(status: .authorized)
        let access = access(client)
        let browser = PhotosBrowser(access: access)
        XCTAssertEqual(browser.albums.map(\.title), ["Recents", "Trip"])
        XCTAssertTrue(browser.albums[0].isRecents)

        let lib = Library(rememberFolder: false)
        lib.open(album: Self.trip, access: access)
        XCTAssertNil(lib.openError)
        XCTAssertEqual(lib.source?.title, "Trip")
        XCTAssertEqual(lib.photos.map(\.id), [.asset("C/L0/001"), .asset("A/L0/001")],
                       "oldest capture first (PhotoSort.photosDefault), whatever order the client listed")
        XCTAssertEqual(lib.photos.map(\.name), ["DSC00003.ARW", "IMG_0001.HEIC"], "names are the originals' file names")
        XCTAssertEqual(lib.photos.map(\.captureDate), [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 2_000)],
                       "the capture date is the asset's creationDate")
        XCTAssertNil(lib.folder)
        XCTAssertEqual(client.assetsCalls, 1)

        lib.open(album: Self.recents, access: access)
        XCTAssertEqual(lib.photos.map(\.id), [.asset("C/L0/001"), .asset("A/L0/001"), .asset("B/L0/001")])

        // Sidecars go flat under the injected directory, named by the asset.
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: .asset("A/L0/001"))
        let sidecar = sidecarDir.appendingPathComponent("A_L0_001.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "flat sidecar under \(sidecarDir.path)")
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("\"original\" : \"IMG_0001.HEIC\""))
        XCTAssertEqual(lib.source?.sidecars.url(for: .asset("A/L0/001")), sidecar)
    }

    func testTheLiveFetchOptionsAreImagesOnlyOldestCaptureFirst() {
        let options = PhotoKitLive.assetFetchOptions()
        XCTAssertEqual(options.sortDescriptors, [NSSortDescriptor(key: "creationDate", ascending: true)])
        XCTAssertEqual(options.predicate?.predicateFormat, "mediaType == \(PHAssetMediaType.image.rawValue)")
        XCTAssertEqual(PhotosAccess.defaultOriginalsDirectory.pathComponents.suffix(4), ["Library", "Caches", "PhotoLab", "originals"])
        XCTAssertEqual(PhotosAccess.defaultSidecarDirectory.pathComponents.suffix(4), ["Library", "Application Support", "PhotoLab", "photos-sidecars"])
    }

    // MARK: Thumbnails

    /// The shared cache's rule (no injected decoder): a `.file` id is an
    /// ImageIO downsample, an `.asset` id goes to the open source, and a
    /// request cancelled while the client is at work sees the cancellation
    /// inside the client and caches nothing; the control decodes and caches.
    func testAnAssetThumbnailGoesThroughTheOpenSourceAndCancellationReachesTheClient() async throws {
        let client = fake(status: .authorized)
        let access = access(client)
        let source = access.source(for: Self.recents)
        let lib = Library(rememberFolder: false)
        lib.open(album: Self.recents, access: access)
        XCTAssertNotNil(Thumbnails.shared.source as? PhotosSource, "open points the shared cache at the source")

        let thumbs = Thumbnails()
        thumbs.source = source
        let unknown = await thumbs.thumbnail(for: .asset("Z/L0/999"))
        XCTAssertNil(unknown, "no image for an id the client does not know")
        XCTAssertEqual(client.thumbnailCalls, 1)

        // 1. In flight, cancelled: the client sees it, nothing is cached.
        // (Detached: this test is on the main actor and blocks its thread
        // on `entered`, so an inheriting Task could never start.)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        client.thumbnailGate = (entered, release)
        let inFlight = Task.detached { await thumbs.thumbnail(for: .asset("A/L0/001")) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the client was asked")
        inFlight.cancel()
        release.signal()
        let late = await inFlight.value
        XCTAssertNil(late, "a cancelled request returns nothing")
        XCTAssertEqual(client.sawCancel, 1, "the cancellation reached the client's thumbnail call")
        XCTAssertNil(thumbs.cached(.asset("A/L0/001")), "and nothing is cached")

        // 2. Control: uncancelled, the same request decodes once and caches.
        release.signal()
        let image = await thumbs.thumbnail(for: .asset("A/L0/001"))
        XCTAssertNotNil(image)
        XCTAssertNotNil(thumbs.cached(.asset("A/L0/001")))
        XCTAssertEqual(client.thumbnailCalls, 3)

        // 3. A file id never asks the client.
        let png = base.appendingPathComponent("file.png")
        try writePNG(16, to: png)
        let fromFile = await thumbs.thumbnail(for: .file(png))
        XCTAssertNotNil(fromFile)
        XCTAssertEqual(client.thumbnailCalls, 3)
    }

    // MARK: Originals

    func testTheOriginalIsWrittenOnceOverTwoCallsAndNamedBySafeIdAndExtension() async throws {
        let client = fake(status: .authorized)
        let access = access(client)
        let source = access.source(for: Self.recents)
        _ = try source.photos()

        let first = try await source.originalFile(for: .asset("A/L0/001"))
        let second = try await source.originalFile(for: .asset("A/L0/001"))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, originalsDir.appendingPathComponent("A_L0_001.HEIC"), "<safe-id>.<ext> under the injected directory")
        XCTAssertEqual(client.writeCalls, 1, "two calls, one resource write")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original of A/L0/001")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path + ".part"), "the partial file is gone")

        // Two concurrent asks share one write.
        let hold = DispatchSemaphore(value: 0)
        client.writeHold = hold
        async let a = source.originalFile(for: .asset("C/L0/001"))
        async let b = source.originalFile(for: .asset("C/L0/001"))
        try await Task.sleep(nanoseconds: 100_000_000)
        hold.signal()
        let (ua, ub) = try await (a, b)
        XCTAssertEqual(ua, ub)
        XCTAssertEqual(ua.lastPathComponent, "C_L0_001.ARW")
        XCTAssertEqual(client.writeCalls, 2, "the second concurrent ask joined the first write")
        client.writeHold = nil

        // A fresh source finds the copy on disk without a write.
        let again = access.source(for: Self.recents)
        _ = try again.photos()
        let found = try await again.originalFile(for: .asset("A/L0/001"))
        XCTAssertEqual(found, first)
        XCTAssertEqual(client.writeCalls, 2)

        // A failed write leaves nothing behind and the next ask tries again.
        client.failWrites = true
        do {
            _ = try await source.originalFile(for: .asset("B/L0/001"))
            XCTFail("a failing write throws")
        } catch let error as PhotosError {
            XCTAssertEqual(error, .noOriginal("B/L0/001"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalsDir.appendingPathComponent("B_L0_001.JPG").path))
        client.failWrites = false
        _ = try await source.originalFile(for: .asset("B/L0/001"))
        XCTAssertEqual(client.writeCalls, 4)

        // An asset the album does not list has no file; a file id is not this source's.
        do {
            _ = try await source.originalFile(for: .asset("Z/L0/999"))
            XCTFail("unlisted")
        } catch let error as PhotoSourceError {
            XCTAssertEqual(error, .notInThisSource(.asset("Z/L0/999")))
        }
        do {
            _ = try await source.originalFile(for: .file(base))
            XCTFail("a file id")
        } catch let error as PhotoSourceError {
            XCTAssertEqual(error, .notInThisSource(.file(base)))
        }
    }

    // MARK: Remembering

    func testTheLastSourceIsRememberedByKindAndNeverPromptsAtLaunch() throws {
        let suite = "photolab-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = fake(status: .authorized)
        let access = access(client)

        let lib = Library(rememberFolder: true, defaults: defaults)
        lib.open(album: Self.trip, access: access)
        XCTAssertEqual(defaults.string(forKey: "lastSourceKind"), "photos")
        XCTAssertEqual(defaults.string(forKey: "lastPhotosAlbum"), Self.trip.id)

        let restored = Library(rememberFolder: true, defaults: defaults)
        restored.restoreLastSource(access: access)
        XCTAssertEqual(restored.source?.title, "Trip")
        XCTAssertEqual(restored.photos.count, 2)

        // Not yet allowed at launch: the Welcome view, and no prompt.
        let asked = fake(status: .notDetermined)
        let cold = Library(rememberFolder: true, defaults: defaults)
        cold.restoreLastSource(access: self.access(asked))
        XCTAssertNil(cold.source)
        XCTAssertEqual(asked.requestCalls, 0, "launch never prompts")
        XCTAssertEqual(asked.albumsCalls, 0)

        // The album gone: nothing opens.
        let empty = fake(status: .authorized)
        empty.albumList = [Self.recents]
        let gone = Library(rememberFolder: true, defaults: defaults)
        gone.restoreLastSource(access: self.access(empty))
        XCTAssertNil(gone.source)

        // A folder opened later is the last source again.
        let folder = base.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writePNG(8, to: folder.appendingPathComponent("a.png"))
        lib.open(folder)
        XCTAssertEqual(defaults.string(forKey: "lastSourceKind"), "folder")
        XCTAssertEqual(defaults.string(forKey: "lastFolder"), folder.path)
        let back = Library(rememberFolder: true, defaults: defaults)
        back.restoreLastSource(access: access)
        XCTAssertEqual(back.folder?.standardizedFileURL.resolvingSymlinksInPath(), folder.standardizedFileURL.resolvingSymlinksInPath())

        // `rememberFolder: false` writes nothing.
        let quiet = Library(rememberFolder: false, defaults: defaults)
        quiet.open(album: Self.recents, access: access)
        XCTAssertEqual(defaults.string(forKey: "lastSourceKind"), "folder")
    }

    // MARK: The real library (skip unless already authorized; never request)

    private func requireAuthorized() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw XCTSkip("Photos access is \(status.rawValue), not authorized, for this test host; run from an authorized bundle to exercise PhotoKit")
        }
    }

    func testRealLibraryListsRecentsFirst() throws {
        try requireAuthorized()
        let albums = PhotoKitLive().albums()
        XCTAssertGreaterThanOrEqual(albums.count, 1)
        XCTAssertTrue(albums[0].isRecents)
        XCTAssertFalse(albums[0].id.isEmpty)
        print("PHOTOS albums:", albums.map { "\($0.title) (\($0.count))" }.joined(separator: ", "))
    }

    func testRealOriginalIsCachedUnderTheOriginalsDirectory() async throws {
        try requireAuthorized()
        let live = PhotoKitLive()
        let access = PhotosAccess(client: live, sidecarDirectory: sidecarDir, originalsDirectory: originalsDir)
        guard let recents = live.albums().first(where: \.isRecents) else { throw XCTSkip("no Recents album") }
        let source = access.source(for: recents)
        let photos = try source.photos()
        guard let first = photos.first else { throw XCTSkip("the library has no image") }
        let file = try await source.originalFile(for: first.id)
        XCTAssertEqual(file.deletingLastPathComponent(), originalsDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.pathExtension, (first.name as NSString).pathExtension)
        XCTAssertNotNil(ImageLoading.downsampledCGImage(file, maxPixelSize: 64), "ImageIO reads the cached original")
        print("PHOTOS original:", first.name, "->", file.path)
    }
}
