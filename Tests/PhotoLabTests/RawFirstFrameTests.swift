import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// The loupe's first frame (`PreviewModel.load`): a photo with a large
/// embedded preview shows it at once, the recipe applied over it, and the
/// decoded master replaces it in one swap; a master that lands first leaves
/// the preview unused; a photo change cancels the old photo's decodes. The
/// model's two decodes are injected (`PreviewModel.Decoders`) so a test can
/// hold the master back. The rule that picks the preview is
/// `ImageLoading.firstFrame`, tested on real JPEG fixtures; a real RAW is
/// timed when `PHOTOLAB_BENCH_RAW` names one (printed, not gated).
@MainActor
final class RawFirstFrameTests: XCTestCase {
    private var folder: URL!
    private var gates: [Gate] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-firstframe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // A failed test must not leave a decode blocked on the pool.
        gates.forEach { $0.open() }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A decode held until `open()`; records that it started and whether
    /// its task was cancelled by the time it was let go.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _started = false
        private var _cancelled: Bool?
        private var opened = false

        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        /// Nil until the held decode returns.
        var cancelledWhenReleased: Bool? { lock.lock(); defer { lock.unlock() }; return _cancelled }

        func open() {
            lock.lock()
            let first = !opened
            opened = true
            lock.unlock()
            if first { semaphore.signal() }
        }

        /// Called inside the decode: blocks until `open()`.
        func pass() {
            lock.lock(); _started = true; lock.unlock()
            boundedWait(semaphore, "open()")
            lock.lock(); _cancelled = Task.isCancelled; lock.unlock()
        }
    }

    private func gate() -> Gate {
        let g = Gate()
        gates.append(g)
        return g
    }

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private nonisolated static func ci(_ width: Int, _ height: Int) -> CIImage {
        CIImage(cgImage: syntheticImage(width: width, height: height))
    }

    private var brighter: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 1)
        return r
    }

    // MARK: The model

    /// The preview (80×60 here) is the first frame, with the recipe applied
    /// over it, while the master (160×120) is held back; letting the master
    /// go swaps it in with one more frame and no more.
    func testFirstFrameArrivesBeforeTheMasterAndSwapsOnce() async throws {
        let photo = url("a.arw")
        let master = gate()
        let preview = PreviewModel(decoders: .init(
            firstFrame: { _ in Self.ci(80, 60) },
            master: { _, _ in master.pass(); return Self.ci(160, 120) }))
        let recipe = brighter

        preview.load(photo)
        preview.request(url: photo, recipe: recipe, maxPixelSize: 1000)
        await waitUntil { preview.image != nil }

        let first = try XCTUnwrap(preview.image, "a frame arrives while the master is held")
        XCTAssertTrue(master.started, "the master decode is running beside it")
        XCTAssertNil(master.cancelledWhenReleased, "and has not returned")
        XCTAssertTrue(preview.imageIsFirstFrame)
        XCTAssertEqual(preview.imageURL, photo)
        XCTAssertEqual(preview.frameGeneration, 1)
        XCTAssertEqual(first.width, 80, "rendered over the embedded preview")
        XCTAssertEqual(preview.imageRecipe, recipe, "the edit is applied to the preview")
        XCTAssertGreaterThan(meanRGB(first).g, meanRGB(syntheticImage(width: 80, height: 60)).g + 0.05,
                             "exposure +1 brightens the preview's frame")
        XCTAssertEqual(preview.masterSize, .zero, "the master's size waits for the master")

        master.open()
        await waitUntil { !preview.imageIsFirstFrame }
        let swapped = try XCTUnwrap(preview.image)
        XCTAssertFalse(preview.imageIsFirstFrame, "the master's frame replaced the preview's")
        XCTAssertEqual(swapped.width, 160)
        XCTAssertEqual(preview.imageRecipe, recipe)
        XCTAssertEqual(preview.masterSize, CGSize(width: 160, height: 120))

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.frameGeneration, 2, "one frame over the preview, one over the master: one swap")
    }

    /// A slider move while the preview shows renders over the preview; after
    /// the swap the newest recipe, not the first, is what the master shows.
    func testAnEditDuringTheFirstFrameIsWhatTheMasterRenders() async throws {
        let photo = url("a.arw")
        let master = gate()
        let preview = PreviewModel(decoders: .init(
            firstFrame: { _ in Self.ci(80, 60) },
            master: { _, _ in master.pass(); return Self.ci(160, 120) }))

        preview.load(photo)
        preview.request(url: photo, recipe: .neutral, maxPixelSize: 1000)
        await waitUntil { preview.image != nil }
        preview.request(url: photo, recipe: brighter, maxPixelSize: 1000)
        await waitUntil { preview.imageRecipe == brighter }
        XCTAssertTrue(preview.imageIsFirstFrame)
        XCTAssertEqual(preview.imageRecipe, brighter)

        master.open()
        await waitUntil { !preview.imageIsFirstFrame }
        XCTAssertEqual(preview.image?.width, 160)
        XCTAssertEqual(preview.imageRecipe, brighter, "the master renders the newest recipe")
    }

    /// A master that lands before the preview: the preview is never shown.
    func testAMasterThatLandsFirstLeavesThePreviewUnused() async throws {
        let photo = url("a.jpg")
        let first = gate()
        let preview = PreviewModel(decoders: .init(
            firstFrame: { _ in first.pass(); return Self.ci(80, 60) },
            master: { _, _ in Self.ci(160, 120) }))

        preview.load(photo)
        preview.request(url: photo, recipe: .neutral, maxPixelSize: 1000)
        await waitUntil { preview.image != nil }
        XCTAssertEqual(preview.image?.width, 160)
        XCTAssertFalse(preview.imageIsFirstFrame)

        first.open()
        await waitUntil { first.cancelledWhenReleased != nil }
        XCTAssertEqual(first.cancelledWhenReleased, true, "the master's landing cancelled the preview decode")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(preview.image?.width, 160, "a late preview does not replace the master's frame")
        XCTAssertFalse(preview.imageIsFirstFrame)
        XCTAssertEqual(preview.frameGeneration, 1)

        // The next edit still renders over the master, not the late preview.
        preview.request(url: photo, recipe: brighter, maxPixelSize: 1000)
        await waitUntil { preview.frameGeneration == 2 }
        XCTAssertEqual(preview.image?.width, 160)
        XCTAssertFalse(preview.imageIsFirstFrame)
    }

    /// Changing photo while the first photo's master and preview are both
    /// still decoding: both decodes see the cancellation, neither result is
    /// shown, and the new photo's frame stays.
    func testAPhotoChangeMidDecodeCancelsTheStaleDecode() async throws {
        let a = url("a.arw"), b = url("b.arw")
        let aMaster = gate(), aFirst = gate()
        let preview = PreviewModel(decoders: .init(
            firstFrame: { u in
                guard u == a else { return nil }
                aFirst.pass()
                return Self.ci(80, 60)
            },
            master: { u, _ in
                guard u == a else { return Self.ci(40, 30) }
                aMaster.pass()
                return Self.ci(160, 120)
            }))

        preview.load(a)
        preview.request(url: a, recipe: .neutral, maxPixelSize: 1000)
        await waitUntil { aMaster.started && aFirst.started }
        XCTAssertTrue(aMaster.started && aFirst.started, "both of a's decodes are running")

        preview.load(b)
        preview.request(url: b, recipe: .neutral, maxPixelSize: 1000)
        await waitUntil { preview.imageURL == b }
        XCTAssertEqual(preview.image?.width, 40)

        aFirst.open()
        aMaster.open()
        await waitUntil { aMaster.cancelledWhenReleased != nil && aFirst.cancelledWhenReleased != nil }
        XCTAssertEqual(aMaster.cancelledWhenReleased, true, "the stale master decode was cancelled")
        XCTAssertEqual(aFirst.cancelledWhenReleased, true, "the stale preview decode was cancelled")

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(preview.imageURL, b, "neither stale result is shown")
        XCTAssertEqual(preview.image?.width, 40)
        XCTAssertFalse(preview.imageIsFirstFrame)
        XCTAssertEqual(preview.masterSize, CGSize(width: 40, height: 30))
    }

    /// A master that cannot be decoded does not leave the preview's frame up.
    func testAFailedMasterTakesThePreviewFrameDown() async throws {
        let photo = url("a.arw")
        let master = gate()
        let preview = PreviewModel(decoders: .init(
            firstFrame: { _ in Self.ci(80, 60) },
            master: { _, _ in master.pass(); return nil }))

        preview.load(photo)
        preview.request(url: photo, recipe: .neutral, maxPixelSize: 1000)
        await waitUntil { preview.image != nil }
        XCTAssertTrue(preview.imageIsFirstFrame)

        master.open()
        await preview.awaitLoad()
        XCTAssertEqual(preview.failed, photo)
        XCTAssertNil(preview.image, "the canvas labels the photo instead")
        XCTAssertFalse(preview.imageIsFirstFrame)
    }

    // MARK: The rule

    private func writeJPEG(_ name: String, width: Int, height: Int, embedThumbnail: Bool) throws -> URL {
        let u = url(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil))
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if embedThumbnail { props[kCGImageDestinationEmbedThumbnail] = true }
        CGImageDestinationAddImage(dest, syntheticImage(width: width, height: height), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return u
    }

    /// The embedded preview as stored, between the two bounds; a file with
    /// none gives nil, never a decode of the image.
    func testFirstFrameIsTheEmbeddedPreviewWithinItsBoundsAndNeverADecode() throws {
        let embedded = try writeJPEG("embedded.jpg", width: 2400, height: 1600, embedThumbnail: true)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(embedded as CFURL, nil))
        // ImageIO embeds a 160 px thumbnail.
        let preview = try XCTUnwrap(ImageLoading.firstFrame(from: source, minPixelSize: 100, masterPixelSize: 3200))
        XCTAssertEqual(max(preview.width, preview.height), 160, "the embedded preview, not the 2400 px image")
        XCTAssertNil(ImageLoading.firstFrame(from: source, minPixelSize: 161, masterPixelSize: 3200),
                     "smaller than the floor: not worth showing first")
        XCTAssertNil(ImageLoading.firstFrame(from: source, minPixelSize: 100, masterPixelSize: 160),
                     "as large as the master: the master is the preview itself")
        XCTAssertNil(ImageLoading.firstFrame(from: source, minPixelSize: PreviewModel.firstFrameMinPixelSize,
                                             masterPixelSize: PreviewModel.masterPixelSize),
                     "the app's floor refuses a 160 px thumbnail")

        let plain = try writeJPEG("plain.jpg", width: 2400, height: 1600, embedThumbnail: false)
        let plainSource = try XCTUnwrap(CGImageSourceCreateWithURL(plain as CFURL, nil))
        XCTAssertNil(ImageLoading.firstFrame(from: plainSource, minPixelSize: 1, masterPixelSize: 3200),
                     "no embedded preview: nil, the image is not decoded")
        XCTAssertNil(Renderer.firstFrame(plain, minPixelSize: 1, masterPixelSize: 3200))
        XCTAssertNotNil(Renderer.firstFrame(embedded, minPixelSize: 100, masterPixelSize: 3200))
    }

    // MARK: A real RAW

    /// `PHOTOLAB_BENCH_RAW=<file.ARW>`: the live model on a real RAW. The
    /// first frame is the embedded preview and arrives before the master;
    /// both times are printed (BENCH-FIRST-FRAME), not gated.
    func testRealRAWShowsItsEmbeddedPreviewBeforeTheMaster() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOLAB_BENCH_RAW"] else {
            throw XCTSkip("set PHOTOLAB_BENCH_RAW=<file.ARW> to time a real RAW's first frame")
        }
        let raw = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "PHOTOLAB_BENCH_RAW exists")
        // The one-time RAW codec load (~100 ms per process) on a header read,
        // so the numbers are per file.
        if let s = CGImageSourceCreateWithURL(raw as CFURL, nil) { _ = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) }

        let preview = PreviewModel()
        let t0 = Date()
        preview.load(raw)
        preview.request(url: raw, recipe: .neutral, maxPixelSize: 2000)
        await waitUntil(20) { preview.image != nil }
        let firstMs = Date().timeIntervalSince(t0) * 1000
        let first = try XCTUnwrap(preview.image, "a first frame")
        XCTAssertTrue(preview.imageIsFirstFrame, "the first frame is the embedded preview")
        await waitUntil(20) { !preview.imageIsFirstFrame && preview.image != nil }
        let masterMs = Date().timeIntervalSince(t0) * 1000
        XCTAssertFalse(preview.imageIsFirstFrame, "the master swapped in")
        let shown = try XCTUnwrap(preview.image)
        print(String(format: "BENCH-FIRST-FRAME %@: first frame %.0f ms (%d×%d, embedded preview); master frame %.0f ms (%d×%d of %.0f×%.0f); load %.2f",
                     raw.lastPathComponent, firstMs, first.width, first.height, masterMs, shown.width, shown.height,
                     preview.masterSize.width, preview.masterSize.height, loadAverage()))
    }
}
