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

    func testAPhotoLeftAtAutoWithAnUnreadableWhiteBalanceIsSkipped() async throws {
        // All black: Auto reads no white balance and keeps the photo's own.
        let url = folder.appendingPathComponent("black.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, frame(low: 0, high: 0), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = library()
        let id = try XCTUnwrap(lib.photos.first?.id)
        var r = Recipe.neutral
        r.set(.temperature, to: 20)
        lib.setRecipe(r, for: id)
        await lib.autoTone([id])
        XCTAssertEqual(lib.recipe(for: id).value(of: .temperature), 20, "Auto kept the white balance")
        let learned = await lib.learnStyle(from: [id], replace: true)
        XCTAssertEqual(learned, 0)
        XCTAssertEqual(lib.autoNote, "Learned from 0 photos (1 skipped)")
    }

    func testALibraryMadeWithoutAStoreNeverReadsOne() {
        XCTAssertNil(Library(rememberFolder: true, defaults: UserDefaults(suiteName: "photolab-style-\(UUID().uuidString)")!).styleStore)
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
        // The first photo answers at once and the rest late, so the cancel
        // lands between results whatever the concurrency.
        let first = lib.photos.first?.fileURL
        lib.styleMeasure = { url, _ in
            if url != first { Thread.sleep(forTimeInterval: 0.4) }
            return (StyleBucket.mid, [AdjustmentKind.exposure: -3])
        }
        let canceller = Task { @MainActor in
            // Ends too if the run finished first (progress resets), never spins forever.
            var started = false
            while true {
                if lib.autoToning { started = true }
                if lib.autoProgress.done >= 1 || (started && !lib.autoToning) { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
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

    // MARK: Auto in my style (the applying half)

    /// A library with `profile` saved in its style store and loaded.
    private func library(profile: StyleProfile) throws -> Library {
        try StyleStore(directory: support).save(profile)
        let lib = library()
        lib.loadStyle()
        XCTAssertNotNil(lib.styleProfile)
        return lib
    }

    private func profile(exposure: Double, temperature: Double,
                         buckets: [StyleBucket: Double] = [:]) -> StyleProfile {
        StyleProfile(version: StyleProfile.currentVersion, samples: [],
                     overall: [AdjustmentKind.exposure.rawValue: exposure, AdjustmentKind.temperature.rawValue: temperature],
                     buckets: Dictionary(uniqueKeysWithValues: buckets.map {
                         ($0.key.rawValue, [AdjustmentKind.exposure.rawValue: $0.value])
                     }))
    }

    func testValuesAreAutosPlusTheCorrectionClampedAtTheRangeEndsAndRoundedAsAutoRounds() {
        let p = profile(exposure: 0.5, temperature: 10)
        let auto: [AdjustmentKind: Double] = [.exposure: 0.25, .contrast: 4, .temperature: -3.25, .tint: 1.5, .shadows: 20]
        let v = AutoStyle.values(auto: auto, bucket: .mid, profile: p)
        XCTAssertEqual(v[.exposure]!, 0.75, accuracy: 1e-12, "exposure 0.25 + 0.5, no clamp needed")
        XCTAssertEqual(v[.temperature]!, 6.75, accuracy: 1e-12, "temperature -3.25 + 10")
        XCTAssertEqual(v[.contrast]!, 4, "a kind with no correction keeps Auto's value")
        XCTAssertEqual(v[.tint]!, 1.5)
        XCTAssertNil(v[.whites], "a kind Auto did not give is not invented")

        let high: [AdjustmentKind: Double] = [.exposure: 4.8, .temperature: 95, .contrast: -3]
        let clamped = AutoStyle.values(auto: high, bucket: .mid, profile: p)
        XCTAssertEqual(clamped[.exposure]!, 5, "exposure stops at the range end, not 5.3")
        XCTAssertEqual(clamped[.temperature]!, 100, "temperature stops at +100, not 105")
        let low = AutoStyle.values(auto: [.exposure: -4.9, .temperature: -95], bucket: .mid,
                                   profile: profile(exposure: -0.5, temperature: -10))
        XCTAssertEqual(low[.exposure]!, -5)
        XCTAssertEqual(low[.temperature]!, -100)

        XCTAssertEqual(AutoStyle.rounded(0.1234, .exposure), 0.10, accuracy: 1e-12, "exposure to 0.05")
        XCTAssertEqual(AutoStyle.rounded(12.6, .shadows), 13, "the rest whole")
        XCTAssertEqual(AutoStyle.rounded(1.2349, .tint), 1.23, accuracy: 1e-12, "tint to 0.01")
        XCTAssertEqual(AutoStyle.rounded(-0.2, .contrast).sign, .plus, "no -0 in a sidecar")
    }

    func testEachBucketGetsItsOwnCorrectionAndTheThinOnesTheOverallOne() {
        let p = profile(exposure: 0.1, temperature: 0, buckets: [.dark: 0.8, .bright: -0.6])
        let auto: [AdjustmentKind: Double] = [.exposure: 0.25]
        XCTAssertEqual(AutoStyle.values(auto: auto, bucket: .dark, profile: p)[.exposure]!, 1.05, accuracy: 1e-12)
        XCTAssertEqual(AutoStyle.values(auto: auto, bucket: .bright, profile: p)[.exposure]!, -0.35, accuracy: 1e-12)
        XCTAssertEqual(AutoStyle.values(auto: auto, bucket: .mid, profile: p)[.exposure]!, 0.35, accuracy: 1e-12,
                       "mid has no bucket of its own: the all-photo correction")
    }

    func testADarkAndABrightPhotoGetTheirOwnBucketsCorrection() async throws {
        try makePhotos(8)
        var lib = library()
        let ids = lib.photos.map(\.id)
        // Auto alone, for the expected values.
        await lib.autoTone(ids)
        let autoRecipes = Dictionary(uniqueKeysWithValues: ids.map { ($0, lib.recipe(for: $0)) })
        for id in ids { lib.resetRecipe(for: id) }

        let corrections: [StyleBucket: Double] = [.dark: 0.8, .mid: 0.3, .bright: -0.6]
        lib = try library(profile: profile(exposure: 0, temperature: 10, buckets: corrections))
        let measure = lib.styleMeasure
        var seen = Set<StyleBucket>()
        let changed = await lib.autoMyStyle(ids)
        XCTAssertEqual(changed, 8)
        for id in ids {
            let url = try XCTUnwrap(lib.photos.first { $0.id == id }?.fileURL)
            let bucket = try XCTUnwrap(measure(url, .neutral)).bucket
            seen.insert(bucket)
            let auto = try XCTUnwrap(autoRecipes[id])
            let mine = lib.recipe(for: id)
            XCTAssertEqual(mine.value(of: .exposure),
                           AutoStyle.rounded(auto.value(of: .exposure) + corrections[bucket]!, .exposure),
                           accuracy: 1e-9, "\(url.lastPathComponent) (\(bucket)) exposure")
            XCTAssertEqual(mine.value(of: .contrast), auto.value(of: .contrast), "no contrast correction")
            let autoWB = auto.value(of: .temperature)
            XCTAssertEqual(mine.value(of: .temperature), autoWB == 0 ? 0 : AutoStyle.rounded(autoWB + 10, .temperature),
                           accuracy: 1e-9, "temperature: +10 only where Auto read a white balance")
        }
        XCTAssertGreaterThan(seen.count, 1, "the photos span more than one bucket")
    }

    func testASecondRunSetsTheSameValuesAndChangesNothing() async throws {
        try makePhotos(4)
        let lib = try library(profile: profile(exposure: 0.5, temperature: 10))
        let ids = lib.photos.map(\.id)
        let first = await lib.autoMyStyle(ids)
        XCTAssertEqual(first, 4)
        let after = ids.map { lib.recipe(for: $0) }
        let second = await lib.autoMyStyle(ids)
        XCTAssertEqual(second, 0, "measured on the same base, so the same values")
        XCTAssertEqual(ids.map { lib.recipe(for: $0) }, after)
    }

    func testAGridSelectionOfFourIsOneUndoStep() async throws {
        try makePhotos(4)
        let lib = try library(profile: profile(exposure: 0.5, temperature: 10))
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, 4)
        let changed = await lib.autoMyStyle(ids)
        XCTAssertEqual(changed, 4)
        XCTAssertEqual(lib.autoLabel, "Auto in my style")
        for id in ids { XCTAssertFalse(lib.recipe(for: id).isNeutral) }
        lib.selection = ids[0]
        lib.undo()
        for id in ids { XCTAssertTrue(lib.recipe(for: id).isNeutral, "one Cmd-Z takes all four back") }
        XCTAssertFalse(lib.canUndo)
    }

    func testCancelAppliesNothingAndWithoutAProfileNothingRuns() async throws {
        try makePhotos(3)
        let none = library()
        let ids = none.photos.map(\.id)
        let zero = await none.autoMyStyle(ids)
        XCTAssertEqual(zero, 0, "no learned style: nothing applied")
        for id in ids { XCTAssertTrue(none.recipe(for: id).isNeutral) }

        let lib = try library(profile: profile(exposure: 0.5, temperature: 10))
        lib.autoStyleMeasure = { _, _, _ in nil }
        let skipped = await lib.autoMyStyle(ids)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(lib.autoNote, "Auto in my style: 3 photos skipped")
    }

    func testAutoInMyStyleIsDisabledUntilAStyleIsLearnedAndHasOptCmdU() throws {
        let command = AppCommand.command(.autoMyStyle)
        XCTAssertEqual(command.title, "Auto in My Style")
        XCTAssertEqual(command.key, "u")
        XCTAssertEqual(command.modifiers, [.command, .option])
        XCTAssertEqual(command.placement, .photo)
        let id = PhotoID.file(URL(fileURLWithPath: "/tmp/x.png"))
        let without = library()
        let ctx = CommandContext(library: without, targetIDs: [id], subjectID: id)
        XCTAssertFalse(command.isEnabled(ctx), "no profile")
        XCTAssertEqual(command.disabledHint?(ctx), "Learn a style first (Photo > Learn Style from Selected Photos...)")
        let with = try library(profile: profile(exposure: 0.5, temperature: 10))
        let ctx2 = CommandContext(library: with, targetIDs: [id], subjectID: id)
        XCTAssertTrue(command.isEnabled(ctx2))
        XCTAssertNil(command.disabledHint?(ctx2))
        XCTAssertFalse(command.isEnabled(CommandContext(library: with)), "no targets")
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
