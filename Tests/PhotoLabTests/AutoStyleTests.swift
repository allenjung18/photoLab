import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The learning half of Auto in my style (`StyleProfile`, `StyleSample`,
/// `StyleStore`, `Library.learnStyle`): medians per brightness bucket with
/// the all-photo fallback, a library run over synthetic photos in a temp
/// folder, skips counted, and the one JSON file in a temp directory (never
/// the user's Application Support).
@MainActor
final class AutoStyleTests: XCTestCase {
    private var folder: URL!
    private var support: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("photolab-style-\(UUID().uuidString)", isDirectory: true)
        support = base.appendingPathComponent("photolab-style-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: Fixtures

    private func sample(_ name: String, _ bucket: StyleBucket, exposure: Double, temperature: Double = 0) -> StyleSample {
        StyleSample(photo: .file(URL(fileURLWithPath: "/tmp/\(name).png")), bucket: bucket,
                    auto: [.exposure: 0.25, .contrast: 4, .temperature: -3],
                    own: [.exposure: 0.25 + exposure, .contrast: 4, .temperature: -3 + temperature])
    }

    private func frame(low: Double, high: Double) -> CGImage {
        let w = 128, h = 32
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(y * w + x) + 0.5) / Double(w * h)
                let v = UInt8(min(255, max(0, ((low + (high - low) * u) * 255).rounded())))
                let i = y * ctx.bytesPerRow + x * 4
                p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    /// `count` grey ramps p00…, each its own range, dark to bright.
    private func makePhotos(_ count: Int) throws {
        for i in 0..<count {
            let url = folder.appendingPathComponent(String(format: "p%02d.png", i))
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            let low = 0.02 + 0.08 * Double(i), high = min(1, 0.25 + 0.1 * Double(i))
            CGImageDestinationAddImage(dest, frame(low: low, high: high), nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }

    private func library() -> Library {
        let lib = Library(rememberFolder: false, style: StyleStore(directory: support))
        lib.open(folder)
        return lib
    }

    // MARK: learn()

    func testLearnGivesTheMedianPerBucketAndTheAllPhotoMedianForAThinBucket() {
        // Dark: three samples, one far out; its median ignores the outlier.
        // Mid: one sample, too few, so the all-photo median of four.
        let samples = [
            sample("d1", .dark, exposure: 0.2, temperature: 10),
            sample("d2", .dark, exposure: 0.3, temperature: 12),
            sample("d3", .dark, exposure: 5.0, temperature: 80),
            sample("m1", .mid, exposure: 1.0, temperature: 20),
        ]
        let profile = StyleProfile.learn(from: samples)
        XCTAssertEqual(profile.version, StyleProfile.currentVersion)
        XCTAssertEqual(profile.sampleCount, 4)

        let dark = profile.correction(for: .dark)
        XCTAssertEqual(dark[.exposure]!, 0.3, accuracy: 1e-9, "dark: median of 0.2, 0.3, 5.0")
        XCTAssertEqual(dark[.temperature]!, 12, accuracy: 1e-9)
        XCTAssertEqual(dark[.contrast]!, 0, accuracy: 1e-9, "a kind the user left at Auto corrects nothing")

        let mid = profile.correction(for: .mid)
        XCTAssertEqual(mid[.exposure]!, 0.65, accuracy: 1e-9, "mid has one sample: median of all four")
        XCTAssertEqual(mid[.temperature]!, 16, accuracy: 1e-9)
        XCTAssertEqual(profile.correction(for: .bright), mid, "an empty bucket falls back the same way")
        XCTAssertEqual(Set(profile.correction(for: .dark).keys), Set(AutoTone.kinds), "every Auto kind, white balance included")
        XCTAssertEqual(StyleProfile.learn(from: samples), profile, "pure")
    }

    func testBucketsFollowTheLumaMedianAndAddingResamplesAPhotoOnce() {
        XCTAssertEqual(StyleBucket.of(lumaMedian: 0.1), .dark)
        XCTAssertEqual(StyleBucket.of(lumaMedian: 0.5), .mid)
        XCTAssertEqual(StyleBucket.of(lumaMedian: 0.9), .bright)

        let old = [sample("a", .dark, exposure: 1), sample("b", .dark, exposure: 2)]
        let new = [sample("b", .dark, exposure: 3), sample("c", .mid, exposure: 4)]
        let merged = StyleProfile.merging(new, into: old)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first { $0.photo == new[0].photo }?.delta(.exposure), 3, "the newer sample of b wins")
    }

    func testSkipNamesUnrefinedAndNeutralPhotos() {
        let id = PhotoID.file(URL(fileURLWithPath: "/tmp/x.png"))
        let auto: [AdjustmentKind: Double] = [.exposure: 0.4, .whites: 6]
        XCTAssertEqual(StyleSample(photo: id, bucket: .mid, auto: auto, own: auto).skip, .unrefined)
        XCTAssertEqual(StyleSample(photo: id, bucket: .mid, auto: auto, own: [:]).skip, .neutral)
        XCTAssertNil(StyleSample(photo: id, bucket: .mid, auto: auto, own: [.exposure: 0.9, .whites: 6]).skip)
    }

    // MARK: Library.learnStyle

    func testLearnStyleOverSixPhotosEditedOverAutoFindsTheEditAndSkipsTheRest() async throws {
        try makePhotos(8)
        let lib = library()
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, 8)
        // p00…p05: Auto, then +0.5 EV and +10 temperature over it.
        // p06: Auto left as it is (unrefined). p07: never edited (neutral).
        for id in ids.prefix(7) { await lib.autoTone([id]) }
        for id in ids.prefix(6) {
            var r = lib.recipe(for: id)
            r.set(.exposure, to: r.value(of: .exposure) + 0.5)
            r.set(.temperature, to: r.value(of: .temperature) + 10)
            lib.setRecipe(r, for: id)
        }
        XCTAssertTrue(lib.isEdited(ids[6]))
        XCTAssertFalse(lib.isEdited(ids[7]))

        let learned = await lib.learnStyle(from: ids, replace: true)
        XCTAssertEqual(learned, 6)
        XCTAssertEqual(lib.autoNote, "Learned from 6 photos (2 skipped)")
        XCTAssertFalse(lib.autoNoteWarns)
        let profile = try XCTUnwrap(lib.styleProfile)
        XCTAssertEqual(profile.sampleCount, 6)
        XCTAssertGreaterThan(Set(profile.samples.map(\.bucket)).count, 1, "the photos span buckets")
        for bucket in StyleBucket.allCases {
            let c = profile.correction(for: bucket)
            XCTAssertEqual(c[.exposure]!, 0.5, accuracy: 1e-6, "\(bucket) exposure")
            XCTAssertEqual(c[.temperature]!, 10, accuracy: 1e-6, "\(bucket) temperature")
            for kind in AutoTone.kinds where kind != .exposure && kind != .temperature {
                XCTAssertEqual(c[kind]!, 0, accuracy: 1e-6, "\(bucket) \(kind)")
            }
        }
        XCTAssertEqual(try StyleStore(directory: support).load(), profile, "saved to style.json")
        XCTAssertEqual(lib.autoLastRun.total, 8, "the Auto job read all eight")

        // Add to current samples: a photo learned again is not counted twice.
        let added = await lib.learnStyle(from: Array(ids.prefix(2)), replace: false)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(lib.styleProfile?.sampleCount, 6)
        // Replace with the two only.
        await lib.learnStyle(from: Array(ids.prefix(2)), replace: true)
        XCTAssertEqual(lib.styleProfile?.sampleCount, 2)
    }

    func testARunWithNothingToLearnOrACancelKeepsTheSavedStyle() async throws {
        try makePhotos(2)
        let lib = library()
        let ids = lib.photos.map(\.id)
        let saved = StyleProfile.learn(from: [sample("a", .mid, exposure: 1)])
        try StyleStore(directory: support).save(saved)
        lib.loadStyle()
        XCTAssertEqual(lib.styleProfile, saved)

        let learned = await lib.learnStyle(from: ids, replace: true)
        XCTAssertEqual(learned, 0)
        XCTAssertEqual(lib.autoNote, "Learned from 0 photos (2 skipped)")
        XCTAssertEqual(lib.styleProfile, saved)
        XCTAssertEqual(try StyleStore(directory: support).load(), saved)

        // A cancel mid-run (Esc, the bar's Cancel) learns nothing.
        lib.styleMeasure = { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
            return (StyleBucket.mid, [AdjustmentKind.exposure: -3])
        }
        let canceller = Task { @MainActor in
            while lib.autoProgress.done < 1 { try? await Task.sleep(nanoseconds: 2_000_000) }
            lib.cancelAuto()
        }
        lib.setRecipe({ var r = Recipe.neutral; r.set(.exposure, to: 1); return r }(), for: ids[0])
        let cancelled = await lib.learnStyle(from: ids, replace: true)
        await canceller.value
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(lib.autoNote, "Learn Style cancelled: nothing changed")
        XCTAssertEqual(lib.styleProfile, saved)
        XCTAssertEqual(try StyleStore(directory: support).load(), saved)
    }

    func testForgetStyleRemovesTheFile() async throws {
        let store = StyleStore(directory: support)
        try store.save(StyleProfile.learn(from: [sample("a", .mid, exposure: 1)]))
        let lib = Library(rememberFolder: false, style: store)
        XCTAssertEqual(lib.styleProfile?.sampleCount, 1)
        XCTAssertTrue(lib.canForgetStyle)
        lib.forgetStyle()
        XCTAssertNil(lib.styleProfile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertFalse(lib.canForgetStyle)
    }

    func testLearnStyleIsOfferedOnTheTargetsAndAsksReplaceOrAdd() {
        let lib = Library(rememberFolder: false, style: StyleStore(directory: support))
        let command = AppCommand.command(.learnStyle)
        XCTAssertNil(command.key, "no key")
        XCTAssertEqual(command.title, "Learn Style from Selected Photos…")
        let id = PhotoID.file(URL(fileURLWithPath: "/tmp/x.png"))
        lib.requestLearnStyle([id])
        XCTAssertEqual(lib.learnStyleRequest?.ids, [id])
        XCTAssertEqual(lib.learnStyleRequest?.currentSamples, 0)
    }

    // MARK: StyleStore

    func testTheStoreRoundTripsInItsOwnFile() throws {
        let store = StyleStore(directory: support)
        XCTAssertNil(try store.load())
        let profile = StyleProfile.learn(from: [sample("a", .dark, exposure: 1), sample("b", .bright, exposure: 2, temperature: 5)])
        try store.save(profile)
        XCTAssertEqual(store.file.lastPathComponent, "style.json")
        XCTAssertEqual(try store.load(), profile)
        XCTAssertEqual(StyleStore.defaultDirectory.lastPathComponent, "PhotoLab")
        XCTAssertTrue(StyleStore.defaultDirectory.path.hasSuffix("Application Support/PhotoLab"))
    }

    func testADamagedFileIsMovedAsideNotOverwritten() throws {
        let store = StyleStore(directory: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let junk = Data("not json".utf8)
        try junk.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        let lib = Library(rememberFolder: false, style: store)
        XCTAssertNil(lib.styleProfile)
        XCTAssertNotNil(lib.styleError)
        XCTAssertTrue(lib.canForgetStyle, "an unreadable file can still be forgotten")

        let profile = StyleProfile.learn(from: [sample("a", .mid, exposure: 1)])
        try store.save(profile, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try store.load(), profile)
        let backups = try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(backups[0])), junk, "the original bytes kept")
    }

    func testAVersionTwoFileIsRefusedAndKept() throws {
        let store = StyleStore(directory: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var newer = StyleProfile.learn(from: [sample("a", .mid, exposure: 1)])
        newer.version = 2
        let data = try JSONEncoder().encode(newer)
        try data.write(to: store.file)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? StyleError, .unsupportedVersion(2)) }
        try store.save(StyleProfile.learn(from: []))
        let backups = try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(backups.count, 1, "the newer file is moved aside, never overwritten")
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(backups[0])), data)
    }
}
