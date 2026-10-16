import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Auto over a selection (`Library.autoTone(_:mask:)`, `autoProgress`,
/// `cancelAuto()`, `autoNote`, `autoConcurrency`, `autoMeasure`): twelve
/// synthetic photos in a temp folder, each read with bounded concurrency
/// and keyed by `Photo.ID`; one undo step; progress counted; a cancel
/// applies nothing; a photo that cannot be read is skipped and counted.
@MainActor
final class AutoBatchTests: XCTestCase {
    private var folder: URL!
    private var reference: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("photolab-autobatch-\(UUID().uuidString)", isDirectory: true)
        reference = base.appendingPathComponent("photolab-autobatch-ref-\(UUID().uuidString)", isDirectory: true)
        for dir in [folder!, reference!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: reference)
    }

    // MARK: Fixtures

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

    /// Twelve photos p00…p11, each with its own range, so Auto gives each
    /// its own values; the same twelve in both folders.
    private func makePhotos(count: Int = 12) throws {
        for i in 0..<count {
            for dir in [folder!, reference!] {
                let url = dir.appendingPathComponent(String(format: "p%02d.png", i))
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, frame(low: 0.02 + 0.02 * Double(i), high: 0.3 + 0.06 * Double(i)), nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
        }
    }

    private func openLibrary(_ dir: URL) -> Library {
        let lib = Library(rememberFolder: false)
        lib.open(dir)
        return lib
    }

    private func sidecars() -> [String] {
        let dir = folder.appendingPathComponent(".photolab", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    /// Calls in flight, the most at once, and the total, across threads.
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, peakValue = 0, totalValue = 0
        func enter() { lock.lock(); now += 1; totalValue += 1; peakValue = max(peakValue, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return peakValue }
        var total: Int { lock.lock(); defer { lock.unlock() }; return totalValue }
    }

    /// The library's own measurer, slowed by `delay(name)` seconds and counted.
    private func slowed(_ lib: Library, _ gauge: Gauge, delay: @escaping @Sendable (String) -> TimeInterval) {
        let real = lib.autoMeasure
        lib.autoMeasure = { url, recipe, whiteBalanceOnly in
            gauge.enter()
            defer { gauge.leave() }
            Thread.sleep(forTimeInterval: delay(url.lastPathComponent))
            return real(url, recipe, whiteBalanceOnly)
        }
    }

    // MARK: Tests

    func testTwelvePhotosEachGetTheirOwnValuesInOneUndoStepAndProgressReachesTwelve() async throws {
        try makePhotos()
        // Single-photo Auto in the twin folder is the reference.
        let ref = openLibrary(reference)
        var expected: [String: Recipe] = [:]
        for photo in ref.photos {
            await ref.autoTone([photo.id])
            expected[photo.name] = ref.recipe(for: photo.id)
        }
        XCTAssertEqual(expected.count, 12)
        XCTAssertGreaterThan(Set(expected.values.map { $0.value(of: .exposure) }).count, 6, "the photos differ")

        let lib = openLibrary(folder)
        let ids = lib.photos.map(\.id)
        // The first photo takes longest, so results arrive out of order.
        slowed(lib, Gauge()) { $0 == "p00.png" ? 0.15 : ($0 == "p01.png" ? 0.08 : 0.01) }
        lib.selectAll()
        let changed = await lib.autoTone(ids)
                XCTAssertEqual(changed, 12)
        XCTAssertEqual(lib.autoLastRun.done, 12, "progress reached 12 of 12")
        XCTAssertEqual(lib.autoLastRun.total, 12)
        XCTAssertEqual(lib.autoProgress.done, 0, "progress resets")
        XCTAssertEqual(lib.autoProgress.total, 0)
        XCTAssertNil(lib.autoNote)
        for photo in lib.photos {
            XCTAssertEqual(lib.recipe(for: photo.id), expected[photo.name], "\(photo.name) equals single-photo Auto")
        }
        XCTAssertEqual(sidecars().count, 12)

        lib.undo()
        for id in ids { XCTAssertFalse(lib.isEdited(id), "one undo step takes all twelve back: \(id)") }
    }

    func testACancelAfterTheFirstResultsAppliesNothingAndLeavesNoSidecar() async throws {
        try makePhotos()
        let lib = openLibrary(folder)
        let ids = lib.photos.map(\.id)
        let gauge = Gauge()
        slowed(lib, gauge) { _ in 0.05 }
        let canceller = Task { @MainActor in
            while lib.autoProgress.done < 1 { try? await Task.sleep(nanoseconds: 2_000_000) }
            lib.cancelAuto()
        }
        let changed = await lib.autoTone(ids)
        await canceller.value
        XCTAssertEqual(changed, 0)
        for id in ids { XCTAssertFalse(lib.isEdited(id), "cancel applied nothing: \(id)") }
        XCTAssertEqual(sidecars(), [], "every sidecar stays absent")
        XCTAssertLessThan(gauge.total, 12, "no new photo is started after the cancel")
        XCTAssertEqual(lib.autoNote, "Auto cancelled: nothing changed (one batch, all or nothing)")
        XCTAssertFalse(lib.autoToning)
        XCTAssertEqual(lib.autoProgress.done, 0)
        XCTAssertFalse(lib.canUndo, "no undo step was made")
    }

    func testAMissingOriginalIsSkippedAndCounted() async throws {
        try makePhotos()
        let lib = openLibrary(folder)
        let ids = lib.photos.map(\.id)
        for name in ["p03.png", "p07.png"] {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let changed = await lib.autoTone(ids)
        XCTAssertEqual(changed, 10)
        XCTAssertEqual(lib.autoNote, "Auto: 2 photos skipped")
        XCTAssertEqual(sidecars().count, 10)
        lib.dismissAutoNote()
        XCTAssertNil(lib.autoNote)
    }

    func testConcurrencyNeverExceedsTheCap() async throws {
        try makePhotos()
        let lib = openLibrary(folder)
        let gauge = Gauge()
        slowed(lib, gauge) { _ in 0.04 }
        await lib.autoTone(lib.photos.map(\.id))
        XCTAssertEqual(gauge.total, 12)
        XCTAssertLessThanOrEqual(gauge.peak, Library.autoConcurrency)
        XCTAssertLessThanOrEqual(Library.autoConcurrency, 4)
        XCTAssertEqual(Library.autoConcurrency, min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        if Library.autoConcurrency > 1 { XCTAssertGreaterThan(gauge.peak, 1, "they do run together") }
    }

    func testEscapeStopsARunningAutoAndTheCommandIsDisabledWhileItRuns() async throws {
        try makePhotos(count: 6)
        let lib = openLibrary(folder)
        slowed(lib, Gauge()) { _ in 0.05 }
        let command = AppCommand.command(.autoTone)
        let ids = lib.photos.map(\.id)
        let context = CommandContext(library: lib, targetIDs: ids, subjectID: ids.first)
        XCTAssertTrue(command.isEnabled(context))
        let esc = Task { @MainActor in
            while !lib.autoToning { try? await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertFalse(command.isEnabled(context), "disabled while running")
            AppCommand.command(.back).perform(CommandContext(library: lib))
        }
        let changed = await lib.autoTone(ids)
        await esc.value
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(sidecars(), [])
        XCTAssertTrue(command.isEnabled(context))
    }
}
