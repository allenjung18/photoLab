import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Auto's white balance (`WhiteBalance.auto`, `AutoTone.values`,
/// `Library.autoTone(_:mask:)`, Photo › Auto White Balance): a grey-world
/// estimate over the near-neutral pixels, solved by the eyedropper's own
/// `WhiteBalance.neutralising`. Every photo is a synthetic frame in a temp
/// folder.
@MainActor
final class AutoWhiteBalanceTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-autowb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// A 128×64 frame: a grey ramp 0.25…0.75 times `gain` per channel, the
    /// last `whiteShare` of the pixels pure white (clipped), or all black.
    private func frame(gain: SIMD3<Double> = SIMD3(repeating: 1), whiteShare: Double = 0,
                       black: Bool = false) -> CGImage {
        let w = 128, h = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(y * w + x) + 0.5) / Double(w * h)
                var c = SIMD3(repeating: 0.25 + 0.5 * u) * gain
                if u > 1 - whiteShare { c = SIMD3(repeating: 1) }
                if black { c = SIMD3(repeating: 0) }
                let i = y * ctx.bytesPerRow + x * 4
                for k in 0..<3 { p[i + k] = UInt8(min(255, max(0, (c[k] * 255).rounded()))) }
                p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    private let warm = SIMD3(1.08, 1.0, 0.9)
    private let green = SIMD3(0.9, 1.1, 0.9)

    private func auto(_ cg: CGImage, recipe: Recipe = .neutral) -> (temperature: Double, tint: Double)? {
        WhiteBalance.auto(for: CIImage(cgImage: cg), recipe: recipe)
    }

    /// The frame rendered with only `t`/`tint` set, its mean in 0…1.
    private func renderedMean(_ cg: CGImage, _ t: Double, _ tint: Double) throws -> (r: Double, g: Double, b: Double) {
        var r = Recipe.neutral
        r.set(.temperature, to: t)
        r.set(.tint, to: tint)
        let out = try XCTUnwrap(Renderer.shared.render(CIImage(cgImage: cg), recipe: r, maxPixelSize: AutoTone.analysisPixelSize))
        let m = meanRGB(out.image)
        return (m.r / 255, m.g / 255, m.b / 255)
    }

    private func assertNearNeutral(_ m: (r: Double, g: Double, b: Double), _ note: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(abs(m.r - m.b), 0.02, "r-b \(m) \(note)", file: file, line: line)
        XCTAssertLessThan(abs(m.g - (m.r + m.b) / 2), 0.02, "g-(r+b)/2 \(m) \(note)", file: file, line: line)
    }

    // MARK: The estimate

    func testAWarmCastComesOutNearNeutralWithACoolingTemperature() throws {
        let cg = frame(gain: warm)
        let wb = try XCTUnwrap(auto(cg))
        XCTAssertLessThan(wb.temperature, -5, "a warm scene takes a cooler temperature: \(wb)")
        assertNearNeutral(try renderedMean(cg, wb.temperature, wb.tint), "warm \(wb)")
        // The untouched frame was not neutral, so the check can fail.
        let before = meanRGB(cg)
        XCTAssertGreaterThan(abs(before.r - before.b) / 255, 0.05)
    }

    func testAGreenCastComesOutNearNeutralWithAMagentaTint() throws {
        let cg = frame(gain: green)
        let wb = try XCTUnwrap(auto(cg))
        XCTAssertGreaterThan(wb.tint, 5, "a green scene takes a magenta tint: \(wb)")
        assertNearNeutral(try renderedMean(cg, wb.temperature, wb.tint), "green \(wb)")
    }

    func testANeutralSceneLeavesTemperatureAndTintNearZero() throws {
        let wb = try XCTUnwrap(auto(frame()))
        XCTAssertLessThanOrEqual(abs(wb.temperature), 1, "\(wb)")
        XCTAssertLessThanOrEqual(abs(wb.tint), 1, "\(wb)")
    }

    func testAClippedWhiteIsIgnored() throws {
        let plain = try XCTUnwrap(auto(frame(gain: warm)))
        let withWhite = try XCTUnwrap(auto(frame(gain: warm, whiteShare: 0.3)))
        XCTAssertEqual(withWhite.temperature, plain.temperature, accuracy: 3)
        XCTAssertEqual(withWhite.tint, plain.tint, accuracy: 3)
        XCTAssertLessThan(withWhite.temperature, -5, "\(withWhite)")
    }

    func testAnAllBlackFrameGivesNilAndAutoLeavesWhiteBalanceAlone() throws {
        let cg = frame(black: true)
        XCTAssertNil(auto(cg))
        var start = Recipe.neutral
        start.set(.temperature, to: 12)
        start.set(.tint, to: -7)
        let values = try XCTUnwrap(AutoTone.values(for: CIImage(cgImage: cg), recipe: start))
        XCTAssertNil(values[.temperature])
        XCTAssertNil(values[.tint])
        let applied = AutoTone.applying(values, to: start)
        XCTAssertEqual(applied.value(of: .temperature), 12)
        XCTAssertEqual(applied.value(of: .tint), -7)
    }

    func testAutoSetsWhiteBalanceFirstAndTheTonePastIt() throws {
        let cg = frame(gain: warm)
        let values = try XCTUnwrap(AutoTone.values(for: CIImage(cgImage: cg), recipe: .neutral))
        XCTAssertEqual(Set(values.keys), Set(AutoTone.kinds))
        XCTAssertEqual(AutoTone.kinds.count, 8)
        XCTAssertEqual(values[.temperature], auto(cg)?.temperature)
        // The base keeps the white balance and neutralises only the six.
        var r = Recipe.neutral
        r.set(.temperature, to: 30)
        r.set(.exposure, to: 1)
        let base = AutoTone.base(r)
        XCTAssertEqual(base.value(of: .temperature), 30)
        XCTAssertEqual(base.value(of: .exposure), 0)
    }

    func testAutoAgainSetsTheSameEightValues() throws {
        for gain in [warm, green, SIMD3(repeating: 1.0)] {
            let image = CIImage(cgImage: frame(gain: gain))
            var start = Recipe.neutral
            start.set(.vibrance, to: 10)
            start.set(.cropLeft, to: 10)
            let first = try XCTUnwrap(AutoTone.values(for: image, recipe: start))
            let once = AutoTone.applying(first, to: start)
            let second = try XCTUnwrap(AutoTone.values(for: image, recipe: once))
            XCTAssertEqual(first, second, "\(gain)")
            XCTAssertEqual(AutoTone.applying(second, to: once), once)
        }
    }

    // MARK: Through the library

    @discardableResult
    private func makePhoto(_ name: String, _ cg: CGImage) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testAutoOnThreePhotosSetsEightValuesAndOneUndoTakesThemAllBack() async throws {
        try makePhoto("a.png", frame(gain: warm))
        try makePhoto("b.png", frame(gain: green))
        try makePhoto("c.png", frame(gain: SIMD3(0.92, 1.0, 1.08)))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let ids = lib.batchTargets
        XCTAssertEqual(ids.count, 3)

        let changed = await lib.autoTone(ids)
        XCTAssertEqual(changed, 3)
        let byName = Dictionary(uniqueKeysWithValues: lib.photos.map { ($0.name, $0.id) })
        let a = lib.recipe(for: byName["a.png"]!)
        XCTAssertLessThan(a.value(of: .temperature), -5)
        XCTAssertGreaterThan(lib.recipe(for: byName["b.png"]!).value(of: .tint), 5)
        XCTAssertGreaterThan(lib.recipe(for: byName["c.png"]!).value(of: .temperature), 5)

        // A second Auto changes nothing (Library.sync skips every photo).
        let again = await lib.autoTone(ids)
        XCTAssertEqual(again, 0)

        // One ⌘Z takes all eight values on all three photos back.
        lib.undo()
        for id in ids { XCTAssertFalse(lib.isEdited(id), "\(id)") }
    }

    func testAutoWhiteBalanceChangesOnlyTemperatureAndTint() async throws {
        try makePhoto("a.png", frame(gain: warm))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        var start = Recipe.neutral
        start.set(.exposure, to: 0.4)
        start.set(.vibrance, to: 15)
        lib.setRecipe(start, for: id)

        let command = AppCommand.command(.autoWhiteBalance)
        XCTAssertEqual(command.placement, .photo)
        XCTAssertEqual(command.key, "u")
        XCTAssertEqual(command.modifiers, [.command, .shift])
        XCTAssertTrue(command.isEnabled(CommandContext(library: lib)))
        XCTAssertFalse(command.isEnabled(CommandContext(library: Library(rememberFolder: false))))

        let changed = await lib.autoTone([id], mask: AutoTone.whiteBalanceMask)
        XCTAssertEqual(changed, 1)
        let after = lib.recipe(for: id)
        XCTAssertLessThan(after.value(of: .temperature), -5)
        for kind in AdjustmentKind.allCases where kind != .temperature && kind != .tint {
            XCTAssertEqual(after[kind], start.normalized[kind], "\(kind)")
        }
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).normalized, start.normalized)
    }
}
