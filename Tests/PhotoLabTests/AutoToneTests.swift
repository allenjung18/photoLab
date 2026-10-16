import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Auto (`AutoTone`, `Library.autoTone`): the six Basic values from the
/// histogram of the photo's recipe with those six at neutral. A dark frame
/// is brightened, a clipped bright one pulled down at the top, a
/// well-exposed one barely moved; running it again sets the same values;
/// and through the library it is one undo step (a batch for many photos)
/// and one sidecar per photo. Every photo here is synthetic and every folder
/// a temp directory.
@MainActor
final class AutoToneTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-autotone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// A 256×64 sRGB frame whose gray level at column i, row j is
    /// `level(u)` for u spread evenly over 0…1 (the bytes written as given).
    private func frame(_ level: (Double) -> Double) -> CGImage {
        let w = 256, h = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(y * w + x) + 0.5) / Double(w * h)
                let v = UInt8(min(255, max(0, (level(u) * 255).rounded())))
                let i = y * ctx.bytesPerRow + x * 4
                p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    private func image(_ level: @escaping (Double) -> Double) -> CIImage { CIImage(cgImage: frame(level)) }

    /// Dark: everything between 2% and 25%.
    private let dark: (Double) -> Double = { 0.02 + 0.23 * $0 }
    /// Bright and clipped: a third of the frame at 255, the rest 60…100%.
    private let clipped: (Double) -> Double = { $0 > 0.66 ? 1 : 0.6 + 0.4 * $0 / 0.66 }
    /// Well exposed: centred on the median target, a spread near the
    /// target's, the ends just inside the white and black windows.
    private let wellExposed: (Double) -> Double = { u in
        let t = 2 * u - 1
        return 0.47 + 0.45 * (t < 0 ? -1 : 1) * pow(abs(t), 1.585)
    }

    private func values(_ level: @escaping (Double) -> Double, recipe: Recipe = .neutral) throws -> [AdjustmentKind: Double] {
        try XCTUnwrap(AutoTone.values(for: image(level), recipe: recipe))
    }

    /// The luma median (0…1) of `recipe` rendered over the frame.
    private func median(_ level: @escaping (Double) -> Double, _ recipe: Recipe) throws -> Double {
        let r = try XCTUnwrap(Renderer.shared.render(image(level), recipe: recipe, maxPixelSize: AutoTone.analysisPixelSize))
        return AutoTone.percentile(try XCTUnwrap(Histogram.compute(r.image)).luminance, 0.5)
    }

    // MARK: The function

    func testADarkFrameIsBrightenedTowardTheMidTarget() throws {
        let v = try values(dark)
        XCTAssertGreaterThan(v[.exposure]!, 0.5, "\(v)")
        let before = try median(dark, .neutral)
        let after = try median(dark, AutoTone.applying(v, to: .neutral))
        XCTAssertLessThan(abs(after - AutoTone.midTarget), abs(before - AutoTone.midTarget) / 2,
                          "median \(before) -> \(after), \(v)")
    }

    func testAClippedBrightFrameLowersWhitesAndHighlights() throws {
        let v = try values(clipped)
        XCTAssertLessThan(v[.whites]!, 0, "\(v)")
        XCTAssertLessThan(v[.highlights]!, 0, "\(v)")
        XCTAssertLessThanOrEqual(v[.exposure]!, 0, "\(v)")
        // The clipping triangle goes out: no channel left at 254 or above.
        let r = try XCTUnwrap(Renderer.shared.render(image(clipped), recipe: AutoTone.applying(v, to: .neutral)))
        XCTAssertFalse(try XCTUnwrap(Histogram.compute(r.image)).highlightsClipped, "\(v)")
    }

    func testAWellExposedFrameChangesLittle() throws {
        let v = try values(wellExposed)
        XCTAssertLessThanOrEqual(abs(v[.exposure]!), 0.15, "\(v)")
        for kind in [AdjustmentKind.contrast, .highlights, .shadows, .whites, .blacks] {
            XCTAssertLessThanOrEqual(abs(v[kind]!), 10, "\(kind): \(v)")
        }
    }

    func testAutoAgainSetsTheSameValues() throws {
        for level in [dark, clipped, wellExposed] {
            // Another edit (warmth, a crop) rides along and is measured as is.
            var start = Recipe.neutral
            start.set(.temperature, to: 30)
            start.set(.cropLeft, to: 10)
            let first = try values(level, recipe: start)
            let once = AutoTone.applying(first, to: start)
            let second = try values(level, recipe: once)
            XCTAssertEqual(first, second)
            XCTAssertEqual(AutoTone.applying(second, to: once), once)
            XCTAssertEqual(once.value(of: .temperature), 30)
            XCTAssertEqual(once.value(of: .cropLeft), 10)
        }
    }

    func testTheBaseNeutralisesOnlyTheSixAndAppliedValuesAreEnabled() {
        var r = Recipe.neutral
        r.set(.exposure, to: 1.2)
        r.setEnabled(.contrast, false)
        r.set(.contrast, to: 40)
        r.set(.vibrance, to: 20)
        let base = AutoTone.base(r)
        for kind in AutoTone.kinds { XCTAssertEqual(base[kind], Adjustment(kind: kind, value: kind.neutral)) }
        XCTAssertEqual(base.value(of: .vibrance), 20)
        let applied = AutoTone.applying([.contrast: 5], to: r)
        XCTAssertTrue(applied.isEnabled(.contrast))
        XCTAssertEqual(applied.value(of: .contrast), 5)
        XCTAssertEqual(applied.value(of: .exposure), 0)
        XCTAssertEqual(Set(AutoTone.kinds), Set(AdjustmentKind.Section.basic.kinds))
    }

    // MARK: Through the library

    /// A gray PNG in the temp folder at `level` (0…1), large enough to read.
    @discardableResult
    private func makePhoto(_ name: String, _ level: @escaping (Double) -> Double) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, frame(level), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private var sidecarDir: URL { folder.appendingPathComponent(".photolab", isDirectory: true) }

    func testAutoOnOnePhotoIsOneUndoStepAndOneSidecar() async throws {
        try makePhoto("a.png", dark)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        var start = Recipe.neutral
        start.set(.vibrance, to: 15)
        lib.setRecipe(start, for: id)

        let changed = await lib.autoTone([id])
        XCTAssertEqual(changed, 1)
        let auto = lib.recipe(for: id)
        XCTAssertGreaterThan(auto.value(of: .exposure), 0.5)
        XCTAssertEqual(auto.value(of: .vibrance), 15)
        // The sidecar holds the Auto recipe.
        let stored = try XCTUnwrap(SidecarStore(folder: folder).load(for: id))
        XCTAssertEqual(stored.normalized, auto.normalized)

        // Auto again: nothing changes, so no second step.
        let again = await lib.autoTone([id])
        XCTAssertEqual(again, 0)
        XCTAssertEqual(lib.recipe(for: id), auto)

        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).normalized, start.normalized)
        lib.redo()
        XCTAssertEqual(lib.recipe(for: id), auto)
        XCTAssertFalse(lib.autoToning)
    }

    func testAutoOnASelectionIsOneBatchUndoStep() async throws {
        try makePhoto("a.png", dark)
        try makePhoto("b.png", clipped)
        try makePhoto("c.png", wellExposed)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let ids = lib.batchTargets
        XCTAssertEqual(ids.count, 3)

        let command = AppCommand.command(.autoTone)
        XCTAssertTrue(command.isEnabled(CommandContext(library: lib)))
        let changed = await lib.autoTone(ids)
        XCTAssertGreaterThanOrEqual(changed, 2)
        let byName = Dictionary(uniqueKeysWithValues: lib.photos.map { ($0.name, $0.id) })
        XCTAssertGreaterThan(lib.recipe(for: byName["a.png"]!).value(of: .exposure), 0)
        XCTAssertLessThan(lib.recipe(for: byName["b.png"]!).value(of: .whites), 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: sidecarDir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, changed)

        // One ⌘Z on the anchor takes the whole batch back.
        lib.undo()
        for id in ids { XCTAssertFalse(lib.isEdited(id), "\(id)") }
    }

    func testTheCommandIsInThePhotoMenuOnCommandU() {
        let command = AppCommand.command(.autoTone)
        XCTAssertEqual(command.placement, .photo)
        XCTAssertEqual(command.key, "u")
        XCTAssertEqual(command.modifiers, .command)
        let lib = Library(rememberFolder: false)
        XCTAssertFalse(command.isEnabled(CommandContext(library: lib)), "no photo, nothing to tone")
    }
}
