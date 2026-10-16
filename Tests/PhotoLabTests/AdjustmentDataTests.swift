import XCTest
import AppKit
import Photos
import UniformTypeIdentifiers
@testable import PhotoLab

/// Level 2 of the Photos integration: an edit written into Photos as
/// PhotoLab's adjustment data plus a rendered full-size JPEG, and read back
/// for a photo whose sidecar is gone. Everything runs against
/// `FakeEditingPhotoKit`, which keeps each asset's adjustment data in
/// memory and the JPEG each save rendered; the one real test writes only
/// to an asset it imports into "PhotoLab Tests" and skips unless this
/// process is already authorized AND `PHOTOLAB_PHOTOS_WRITE=1`.
@MainActor
final class AdjustmentDataTests: XCTestCase {
    private var base: URL!
    private var sidecarDir: URL!
    private var originalsDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-adjustment-\(UUID().uuidString)", isDirectory: true)
        sidecarDir = base.appendingPathComponent("sidecars", isDirectory: true)
        originalsDir = base.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: The fake

    /// An authorized library of one album whose originals are 64×48 mid-gray
    /// PNGs. `edits` is what Photos holds per asset (one edit each: a save
    /// replaces it); a save's `render` is run into a file of the fake's and
    /// the bytes kept in `rendered`. Reads can be held on `readHold`.
    final class FakeEditingPhotoKit: PhotoKitClient, @unchecked Sendable {
        private let lock = NSLock()
        let assetList: [PhotosAsset]
        let renderDir: URL
        private var _edits: [String: PhotosAdjustment] = [:]
        private(set) var rendered: [String: Data] = [:]
        private(set) var adjustmentCalls = 0, saveCalls = 0
        var readHold: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        var failSave = false

        init(assets: [PhotosAsset], renderDir: URL) {
            assetList = assets
            self.renderDir = renderDir
        }

        var edits: [String: PhotosAdjustment] {
            get { lock.lock(); defer { lock.unlock() }; return _edits }
            set { lock.lock(); _edits = newValue; lock.unlock() }
        }

        func authorizationStatus() -> PhotosAuthorization { .authorized }
        func requestAuthorization() async -> PhotosAuthorization { .authorized }
        func albums() -> [PhotosAlbum] { [AdjustmentDataTests.album] }
        func assets(in album: PhotosAlbum) -> [PhotosAsset] { assetList }
        func originalFilename(of assetID: String) -> String? { assetList.first { $0.id == assetID }?.originalFilename }
        func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage? { nil }
        func writeOriginal(of assetID: String, to url: URL) async throws {
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, AdjustmentDataTests.gray(0.4, width: 64, height: 48), nil)
            guard CGImageDestinationFinalize(dest) else { throw PhotosError.noOriginal(assetID) }
        }
        func hasAdjustments(_ assetID: String) -> Bool { edits[assetID] != nil }
        func adjustment(of assetID: String) async throws -> PhotosAdjustment? {
            locked { adjustmentCalls += 1 }
            if let hold = readHold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    Thread.detachNewThread { hold.entered.signal(); hold.release.wait(); c.resume() }
                }
            }
            return edits[assetID]
        }
        func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                      render: @escaping @Sendable (URL) throws -> Void) async throws {
            if failSave { throw PhotosError.cannotEdit(assetID) }
            try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
            let url = renderDir.appendingPathComponent(UUID().uuidString + ".jpg")
            try render(url)
            let bytes = try Data(contentsOf: url)
            locked {
                saveCalls += 1
                _edits[assetID] = adjustment
                rendered[assetID] = bytes
            }
        }

        private func locked(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
    }

    nonisolated static let album = PhotosAlbum(id: "ALBUM/L0/040", title: "Shoot", count: 2, isRecents: false)
    static let assets = [
        PhotosAsset(id: "A/L0/001", originalFilename: "IMG_0001.HEIC"),
        PhotosAsset(id: "B/L0/001", originalFilename: "IMG_0002.JPG"),
    ]
    private let a = PhotoID.asset("A/L0/001")

    nonisolated static func gray(_ level: CGFloat, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func fake() -> FakeEditingPhotoKit {
        FakeEditingPhotoKit(assets: Self.assets, renderDir: base.appendingPathComponent("rendered", isDirectory: true))
    }

    private func open(_ client: FakeEditingPhotoKit) -> Library {
        let lib = Library(rememberFolder: false)
        lib.open(album: Self.album,
                 access: PhotosAccess(client: client, sidecarDirectory: sidecarDir, originalsDirectory: originalsDir))
        XCTAssertNil(lib.openError)
        return lib
    }

    private func exposure(_ ev: Double) -> Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: ev)
        r.setEnabled(.exposure, true)
        return r
    }

    private var store: SidecarStore { SidecarStore(directory: sidecarDir, naming: .flat) }

    /// Mean gray and size of an image file, decoded into RGBA8.
    private func meanGray(_ data: Data) throws -> (mean: Double, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let m = meanRGB(try XCTUnwrap(ctx.makeImage()))
        return ((m.r + m.g + m.b) / 3, cg.width, cg.height)
    }

    private func containerType(_ data: Data) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }

    // MARK: Save to Photos

    func testSaveWritesOurDataAndAFullSizeJPEGRenderedFromTheOriginal() async throws {
        let client = fake()
        let lib = open(client)
        lib.selection = a
        XCTAssertFalse(lib.canSaveToPhotos, "an unedited photo has nothing to save")
        lib.setRecipe(exposure(1), for: a)
        XCTAssertTrue(lib.canSaveToPhotos)

        await lib.saveToPhotos()

        XCTAssertEqual(lib.photosSave, .saved(a))
        let saved = try XCTUnwrap(client.edits["A/L0/001"])
        XCTAssertEqual(saved.formatIdentifier, "local.photolab.recipe")
        XCTAssertEqual(saved.formatVersion, "1")
        XCTAssertEqual(try saved.recipe(), exposure(1), "the data decodes to the recipe saved")
        let doc = try SidecarStore.decode(saved.data)
        XCTAssertNil(doc.flag, "recipe only: no marks in the data")
        XCTAssertNil(doc.rating)
        XCTAssertEqual(doc.original, "IMG_0001.HEIC")

        let jpeg = try XCTUnwrap(client.rendered["A/L0/001"])
        XCTAssertEqual(try containerType(jpeg), UTType.jpeg.identifier)
        let original = try Data(contentsOf: try await lib.originalFile(for: a))
        let before = try meanGray(original), after = try meanGray(jpeg)
        XCTAssertEqual(after.width, 64, "full size: the original's pixels")
        XCTAssertEqual(after.height, 48)
        XCTAssertGreaterThan(after.mean, before.mean + 20, "exposure +1 is in the rendered content")
        XCTAssertEqual(try store.load(for: a), exposure(1), "the sidecar stays the primary record")
        XCTAssertNil(client.edits["B/L0/001"])
    }

    func testASecondSaveReplacesTheData() async throws {
        let client = fake()
        let lib = open(client)
        lib.selection = a
        lib.setRecipe(exposure(1), for: a)
        await lib.saveToPhotos()
        let first = try meanGray(try XCTUnwrap(client.rendered["A/L0/001"])).mean
        lib.setRecipe(exposure(-1), for: a)
        await lib.saveToPhotos()

        XCTAssertEqual(client.saveCalls, 2)
        XCTAssertEqual(client.edits.count, 1, "one edit per asset")
        XCTAssertEqual(try client.edits["A/L0/001"]?.recipe(), exposure(-1))
        XCTAssertLessThan(try meanGray(try XCTUnwrap(client.rendered["A/L0/001"])).mean, first - 20)
    }

    func testSaveToPhotosIsOnlyForAnEditedPhotoOfAPhotosAlbum() async throws {
        // A folder photo, edited: never offered.
        let folder = base.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, Self.gray(0.5, width: 8, height: 8), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selection = .file(file)
        lib.setRecipe(exposure(1), for: .file(file))
        XCTAssertFalse(lib.canSaveToPhotos)
        await lib.saveToPhotos()
        XCTAssertEqual(lib.photosSave, .idle)

        // A Photos photo: nothing selected, then a save Photos refuses.
        let client = fake()
        client.failSave = true
        let photos = open(client)
        XCTAssertFalse(photos.canSaveToPhotos, "no selection")
        photos.selection = a
        photos.setRecipe(exposure(1), for: a)
        await photos.saveToPhotos()
        guard case .failed(a, let reason) = photos.photosSave else {
            return XCTFail("expected a failure, got \(photos.photosSave)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(photos.canSaveToPhotos, "a failed save can be tried again")
        XCTAssertTrue(client.edits.isEmpty)
        XCTAssertEqual(try store.load(for: a), exposure(1), "the edit itself is kept")
    }

    func testCanHandleIsOurIdentifierAtAVersionThisBuildReads() {
        XCTAssertTrue(PhotosAdjustment.canHandle(identifier: "local.photolab.recipe", version: "1"))
        XCTAssertTrue(PhotosAdjustment.canHandle(identifier: "local.photolab.recipe", version: "2"), "masks (format 2)")
        XCTAssertFalse(PhotosAdjustment.canHandle(identifier: "local.photolab.recipe",
                                                  version: String(Sidecar.currentVersion + 1)))
        XCTAssertFalse(PhotosAdjustment.canHandle(identifier: "local.photolab.recipe", version: "1.0"))
        XCTAssertFalse(PhotosAdjustment.canHandle(identifier: "com.example.other", version: "1"))
    }

    // MARK: Reopen

    func testReopenWithNoSidecarRestoresTheRecipeWritesTheSidecarAndRecordsNoStep() async throws {
        let client = fake()
        client.edits["A/L0/001"] = try PhotosAdjustment(recipe: exposure(0.5), name: "IMG_0001.HEIC")
        let lib = open(client)
        XCTAssertFalse(lib.isEdited(a), "open reads sidecars only")
        lib.selection = a

        await lib.recoverRecipe(for: a)

        XCTAssertEqual(lib.recipe(for: a), exposure(0.5))
        XCTAssertEqual(try store.load(for: a), exposure(0.5), "the sidecar now holds it")
        XCTAssertFalse(lib.canUndo, "a load, not an edit")
        XCTAssertTrue(lib.unreadableSidecars.isEmpty)
        XCTAssertNil(lib.sidecarError)

        // From now on the sidecar is the record: no further read of Photos.
        await lib.recoverRecipe(for: a)
        XCTAssertEqual(client.adjustmentCalls, 1)
        lib.open(album: Self.album,
                 access: PhotosAccess(client: client, sidecarDirectory: sidecarDir, originalsDirectory: originalsDir))
        XCTAssertEqual(lib.recipe(for: a), exposure(0.5), "the next open reads the sidecar")
    }

    func testASidecarOrAnUneditedAssetAsksPhotosNothing() async throws {
        let client = fake()
        client.edits["A/L0/001"] = try PhotosAdjustment(recipe: exposure(0.5), name: "IMG_0001.HEIC")
        try store.save(exposure(-0.3), for: a)
        let lib = open(client)
        await lib.recoverRecipe(for: a)
        let b = PhotoID.asset("B/L0/001")
        await lib.recoverRecipe(for: b)

        XCTAssertEqual(client.adjustmentCalls, 0, "a sidecar wins; an asset with no edit is not asked")
        XCTAssertEqual(lib.recipe(for: a), exposure(-0.3))
        XCTAssertFalse(lib.isEdited(b))
    }

    func testAnotherAppsEditGivesNeutral() async throws {
        let client = fake()
        client.edits["A/L0/001"] = PhotosAdjustment(formatIdentifier: "com.example.editor", formatVersion: "1",
                                                    data: Data("{\"version\":1}".utf8))
        let lib = open(client)
        lib.selection = a
        await lib.recoverRecipe(for: a)

        XCTAssertEqual(client.adjustmentCalls, 1)
        XCTAssertEqual(lib.recipe(for: a), .neutral)
        XCTAssertFalse(store.exists(for: a), "nothing written")
        XCTAssertTrue(lib.unreadableSidecars.isEmpty)
        XCTAssertNil(lib.sidecarError)
    }

    func testANewerVersionIsRefusedAndListedUnreadable() async throws {
        let client = fake()
        var doc = Sidecar(original: "IMG_0001.HEIC", updated: Date(), recipe: exposure(0.5))
        let newer = Sidecar.currentVersion + 1
        doc.version = newer
        client.edits["A/L0/001"] = PhotosAdjustment(formatIdentifier: "local.photolab.recipe", formatVersion: String(newer),
                                                    data: try SidecarStore.encode(doc))
        let lib = open(client)
        lib.selection = a
        await lib.recoverRecipe(for: a)

        XCTAssertEqual(lib.recipe(for: a), .neutral)
        XCTAssertEqual(lib.unreadableSidecars, [a])
        XCTAssertNotNil(lib.sidecarError)
        XCTAssertFalse(store.exists(for: a))
        XCTAssertThrowsError(try client.edits["A/L0/001"]?.recipe()) { error in
            XCTAssertEqual(error as? SidecarError, .unsupportedVersion(newer))
        }
        // A version-1 label over newer JSON is refused the same way.
        let relabelled = PhotosAdjustment(formatIdentifier: "local.photolab.recipe", formatVersion: "1",
                                          data: try SidecarStore.encode(doc))
        XCTAssertThrowsError(try relabelled.recipe())
    }

    func testAnEditMadeWhileReadingWins() async throws {
        let client = fake()
        client.edits["A/L0/001"] = try PhotosAdjustment(recipe: exposure(0.5), name: "IMG_0001.HEIC")
        let hold = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        client.readHold = hold
        let lib = open(client)
        lib.selection = a

        let read = Task { await lib.recoverRecipe(for: a) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { hold.entered.wait(); c.resume() }
        }
        lib.setRecipe(exposure(-1), for: a)
        hold.release.signal()
        await read.value

        XCTAssertEqual(lib.recipe(for: a), exposure(-1), "the user's edit is kept")
        XCTAssertEqual(try store.load(for: a), exposure(-1))
        XCTAssertTrue(lib.canUndo)
    }

    // MARK: Real PhotoKit (opt-in)

    func testRealSaveOntoATestAssetReadsBack() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOLAB_PHOTOS_WRITE"] == "1" else {
            throw XCTSkip("set PHOTOLAB_PHOTOS_WRITE=1 (from an authorized bundle) to edit a real photo")
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw XCTSkip("Photos access is \(status.rawValue), not authorized, for this test host")
        }
        let file = base.appendingPathComponent("photolab-adjustment-test.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, Self.gray(0.4, width: 16, height: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let live = PhotoKitLive()
        let id = try await live.importImage(at: file, intoAlbum: "PhotoLab Tests")
        let recipe = exposure(1)
        try await live.saveEdit(try PhotosAdjustment(recipe: recipe, name: file.lastPathComponent), to: id) { url in
            try Exporter.write(file, recipe: recipe, to: url, options: PhotosSource.saveOptions)
        }
        XCTAssertTrue(live.hasAdjustments(id))
        let back = try await live.adjustment(of: id)
        XCTAssertEqual(back?.formatIdentifier, "local.photolab.recipe")
        XCTAssertEqual(try back?.recipe(), recipe)
    }
}
