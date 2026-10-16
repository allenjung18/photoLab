import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoLab

/// Color grading: the ten `grade` kinds, rendered as one cube
/// (`ColorCubes.gradeCube`) right after the HSL cube. Direction tests read a
/// gray ramp back: a range's tint colors its own end and leaves the far end
/// alone, the tint keeps the gray's luma, balance moves the crossover, each
/// luminance slider lifts its own range, and a grade that tints nothing is
/// the identity.
final class ColorGradingTests: XCTestCase {
    let renderer = Renderer.shared

    // MARK: Images

    /// A gray ramp, sRGB 0 on the left to 1 on the right (x / (width − 1)).
    private lazy var ramp: CIImage = {
        let width = 256, height = 8
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            let v = CGFloat(x) / CGFloat(width - 1)
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return CIImage(cgImage: ctx.makeImage()!)
    }()

    private func solidGray(_ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    private func render(_ recipe: Recipe, _ source: CIImage? = nil) -> CGImage {
        let out = renderer.render(source ?? ramp, recipe: recipe)
        XCTAssertNotNil(out)
        return out!.image
    }

    private func recipe(_ values: [(AdjustmentKind, Double)]) -> Recipe {
        var r = Recipe.neutral
        for (k, v) in values { r.set(k, to: v) }
        return r
    }

    /// Mean RGB (0…255) over the columns x0…x1 (fractions of the width).
    private func mean(_ cg: CGImage, _ x0: Double, _ x1: Double) -> (r: Double, g: Double, b: Double) {
        let data = cg.dataProvider!.data!, p = CFDataGetBytePtr(data)!
        let xa = Int(Double(cg.width) * x0), xb = max(xa + 1, Int(Double(cg.width) * x1))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in 0..<cg.height {
            for x in xa..<xb {
                let i = y * cg.bytesPerRow + x * 4
                r += Double(p[i]); g += Double(p[i + 1]); b += Double(p[i + 2]); n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    /// How blue a patch reads: blue over the mean of red and green, levels.
    private func blueness(_ p: (r: Double, g: Double, b: Double)) -> Double { p.b - (p.r + p.g) / 2 }
    private func luma(_ p: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b }
    /// Largest channel difference between two patch means.
    private func diff(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    private let dark = (0.03, 0.12), middle = (0.45, 0.55), light = (0.88, 0.97)

    // MARK: Model

    /// The grade kinds sit together right after HSL and before clarity, in
    /// shadow, midtone, highlight order with balance last; the section sits
    /// between HSL and Detail. Masks and lens corrections add to the same
    /// chain, so the position is pinned here.
    func testGradeKindsAreContiguousAfterHSLAndBeforeClarity() {
        let all = AdjustmentKind.allCases
        let grade = AdjustmentKind.members(of: .grade)
        XCTAssertEqual(grade, [.gradeShadowHue, .gradeShadowSat, .gradeShadowLum,
                               .gradeMidtoneHue, .gradeMidtoneSat, .gradeMidtoneLum,
                               .gradeHighlightHue, .gradeHighlightSat, .gradeHighlightLum, .gradeBalance])
        let first = all.firstIndex(of: grade[0])!
        XCTAssertEqual(Array(all[first..<first + grade.count]), grade, "contiguous")
        XCTAssertEqual(all[first - 1], .lumMagenta, "right after the HSL kinds")
        XCTAssertEqual(all[first + grade.count], .clarity, "right before clarity")
        XCTAssertEqual(all.firstIndex { $0.group == .grade }, first)
        XCTAssertEqual(AdjustmentKind.Section.grading.kinds, grade)
        XCTAssertEqual(AdjustmentKind.Section.grading.title, "Color Grading")
        let sections = AdjustmentKind.Section.allCases
        XCTAssertEqual(sections.firstIndex(of: .grading), sections.firstIndex(of: .hsl)! + 1)
        XCTAssertEqual(sections.firstIndex(of: .detail), sections.firstIndex(of: .grading)! + 1)
        for range in AdjustmentKind.GradeRange.allCases {
            for channel in AdjustmentKind.HSLChannel.allCases {
                let kind = AdjustmentKind.grade(channel, range)
                XCTAssertEqual(kind.grade?.0, channel); XCTAssertEqual(kind.grade?.1, range)
            }
        }
        XCTAssertNil(AdjustmentKind.gradeBalance.grade)
        XCTAssertEqual(AdjustmentKind.gradeShadowHue.label, "Shadow hue")
        XCTAssertEqual(AdjustmentKind.gradeHighlightSat.label, "Highlight saturation")
        XCTAssertEqual(AdjustmentKind.gradeBalance.label, "Balance")
        XCTAssertEqual(AdjustmentKind.gradeMidtoneHue.range, 0...360)
        XCTAssertEqual(AdjustmentKind.gradeMidtoneHue.format(240), "240°")
        XCTAssertEqual(AdjustmentKind.gradeMidtoneSat.range, 0...100)
        XCTAssertEqual(AdjustmentKind.gradeMidtoneLum.range, -100...100)
        XCTAssertEqual(AdjustmentKind.gradeBalance.range, -100...100)
        for kind in grade { XCTAssertEqual(kind.neutral, 0) }
    }

    /// The chain runs HSL, then the grade, then the masks (local
    /// adjustments), then Detail: a recipe with a grade and a mask renders
    /// as the grade applied first and the mask's own recipe over it, not the
    /// other way round.
    func testTheGradeRendersBeforeTheMaskStage() throws {
        let src = solidGray(0.2)
        var r = recipe([(.gradeShadowLum, 100), (.gradeShadowHue, 240), (.gradeShadowSat, 60)])
        let mask = LocalMask(shape: .linear(start: MaskPoint(x: 0.5, y: -0.5), end: MaskPoint(x: 0.5, y: -1)),
                             adjustments: [Adjustment(kind: .exposure, value: 1)])
        r.masks = [mask]
        var gradeOnly = r
        gradeOnly.masks = []
        func cg(_ image: CIImage) throws -> CGImage {
            try XCTUnwrap(renderer.context.createCGImage(image, from: src.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        }
        let got = try cg(renderer.apply(r, to: src))
        let gradeThenMask = try cg(renderer.apply(mask.recipe, to: renderer.apply(gradeOnly, to: src)))
        let maskThenGrade = try cg(renderer.apply(gradeOnly, to: renderer.apply(mask.recipe, to: src)))
        XCTAssertLessThanOrEqual(maxDiff(got, gradeThenMask), 1, "the grade, then the mask")
        XCTAssertGreaterThan(maxDiff(got, maskThenGrade), 4, "not the mask first")
        XCTAssertFalse(LocalMask.kinds.contains { $0.group == .grade }, "a mask never carries a grade kind")
    }

    /// Presets and the look sync carry the grade; geometry is still only
    /// rotate and the crop edges.
    func testPresetsAndTheLookSyncCarryTheGrade() {
        XCTAssertEqual(AdjustmentKind.geometryKinds, [.rotate, .cropLeft, .cropTop, .cropRight, .cropBottom])
        let graded = recipe([(.gradeShadowHue, 240), (.gradeShadowSat, 50), (.gradeBalance, 20)])
        let preset = Preset(name: "Teal", from: graded)
        XCTAssertEqual(preset.apply(to: .neutral).value(of: .gradeShadowHue), 240)
        XCTAssertEqual(preset.apply(to: .neutral).value(of: .gradeBalance), 20)
        for kind in AdjustmentKind.members(of: .grade) {
            XCTAssertTrue(SyncMask.look.contains(kind)); XCTAssertTrue(SyncMask.grade.contains(kind))
        }
        XCTAssertEqual(Recipe.neutral.syncing(.look, from: graded).value(of: .gradeShadowSat), 50)
    }

    /// The range weights: a partition of unity, shadow full at black and
    /// highlight full at white, the crossover at luma 0.5 that balance moves
    /// (below 0.25 at +50, mirrored at −50).
    func testRangeWeightsSumToOneAndBalanceMovesTheCrossover() {
        for b in [-1.0, -0.5, 0, 0.3, 1] {
            for i in 0...20 {
                let w = ColorCubes.gradeWeights(luma: Double(i) / 20, balance: b)
                XCTAssertEqual(w.shadow + w.midtone + w.highlight, 1, accuracy: 1e-12)
            }
        }
        let black = ColorCubes.gradeWeights(luma: 0, balance: 0), white = ColorCubes.gradeWeights(luma: 1, balance: 0)
        XCTAssertEqual(black.shadow, 1); XCTAssertEqual(white.highlight, 1)
        let mid = ColorCubes.gradeWeights(luma: 0.5, balance: 0)
        XCTAssertEqual(mid.shadow, mid.highlight, accuracy: 1e-12)
        XCTAssertGreaterThan(mid.midtone, mid.shadow)
        let quarter = ColorCubes.gradeWeights(luma: 0.25, balance: 0)
        XCTAssertGreaterThan(quarter.shadow, quarter.highlight)
        let pushed = ColorCubes.gradeWeights(luma: 0.25, balance: 0.5)
        XCTAssertGreaterThan(pushed.highlight, pushed.shadow, "+50 puts a 25% gray on the highlight side")
        let mirrored = ColorCubes.gradeWeights(luma: 0.75, balance: -0.5)
        XCTAssertEqual(mirrored.shadow, pushed.highlight, accuracy: 1e-12)
        XCTAssertEqual(mirrored.highlight, pushed.shadow, accuracy: 1e-12)
    }

    // MARK: Tint direction

    /// Shadow hue 240 at saturation 50 makes the dark end of a gray ramp
    /// bluer, keeps its luma, and leaves the light end within 2 levels.
    func testShadowTintBluesTheDarkEndOnly() {
        let base = render(.neutral)
        let out = render(recipe([(.gradeShadowHue, 240), (.gradeShadowSat, 50)]))
        XCTAssertGreaterThan(blueness(mean(out, dark.0, dark.1)) - blueness(mean(base, dark.0, dark.1)), 8)
        XCTAssertLessThanOrEqual(diff(mean(out, light.0, light.1), mean(base, light.0, light.1)), 2)
        XCTAssertEqual(luma(mean(out, dark.0, dark.1)), luma(mean(base, dark.0, dark.1)), accuracy: 2,
                       "the tint keeps the gray's tone")
    }

    func testHighlightTintBluesTheLightEndOnly() {
        let base = render(.neutral)
        let out = render(recipe([(.gradeHighlightHue, 240), (.gradeHighlightSat, 50)]))
        XCTAssertGreaterThan(blueness(mean(out, light.0, light.1)) - blueness(mean(base, light.0, light.1)), 8)
        XCTAssertLessThanOrEqual(diff(mean(out, dark.0, dark.1), mean(base, dark.0, dark.1)), 2)
        XCTAssertEqual(luma(mean(out, light.0, light.1)), luma(mean(base, light.0, light.1)), accuracy: 2)
    }

    func testMidtoneTintBluesTheMiddleMoreThanEitherEnd() {
        let base = render(.neutral)
        let out = render(recipe([(.gradeMidtoneHue, 240), (.gradeMidtoneSat, 50)]))
        func shift(_ r: (Double, Double)) -> Double { blueness(mean(out, r.0, r.1)) - blueness(mean(base, r.0, r.1)) }
        XCTAssertGreaterThan(shift(middle), 8)
        XCTAssertGreaterThan(shift(middle), 2 * shift(dark))
        XCTAssertGreaterThan(shift(middle), 2 * shift(light))
        XCTAssertEqual(luma(mean(out, middle.0, middle.1)), luma(mean(base, middle.0, middle.1)), accuracy: 2)
    }

    /// The tint lands at its hue: red, green and blue shadows read back at
    /// 0, 120 and 240 degrees.
    func testTintLandsAtItsHue() {
        for hue in [0.0, 120, 240] {
            let p = mean(render(recipe([(.gradeShadowHue, hue), (.gradeShadowSat, 80)])), dark.0, dark.1)
            var a = atan2(3.0.squareRoot() * (p.g - p.b), 2 * p.r - p.g - p.b) * 180 / .pi
            if a < 0 { a += 360 }
            var d = abs(a - hue); if d > 180 { d = 360 - d }
            XCTAssertLessThan(d, 15, "hue \(hue) read back at \(a)")
        }
    }

    /// Balance +50 moves the crossover down: with blue shadows and yellow
    /// highlights, a 25% gray reads blue at balance 0 and yellow at +50.
    func testBalanceMovesTheCrossoverSoAQuarterGrayTakesTheHighlightTint() {
        let gray = solidGray(0.25)
        let split: [(AdjustmentKind, Double)] = [(.gradeShadowHue, 240), (.gradeShadowSat, 50),
                                                  (.gradeHighlightHue, 60), (.gradeHighlightSat, 50)]
        let at0 = meanRGB(render(recipe(split), gray))
        let at50 = meanRGB(render(recipe(split + [(.gradeBalance, 50)]), gray))
        XCTAssertGreaterThan(blueness(at0), 3, "balance 0: the shadow tint")
        XCTAssertLessThan(blueness(at50), -3, "balance +50: the highlight tint")
        let atMinus50 = meanRGB(render(recipe(split + [(.gradeBalance, -50)]), gray))
        XCTAssertGreaterThan(blueness(atMinus50), blueness(at0), "balance −50: deeper into the shadow tint")
    }

    // MARK: Luminance

    func testEachLuminanceSliderMovesItsOwnRange() {
        let base = render(.neutral)
        func lumaShift(_ out: CGImage, _ r: (Double, Double)) -> Double {
            luma(mean(out, r.0, r.1)) - luma(mean(base, r.0, r.1))
        }
        let shadows = render(recipe([(.gradeShadowLum, 100)]))
        XCTAssertGreaterThan(lumaShift(shadows, dark), 10, "shadow luminance lifts the dark end")
        XCTAssertLessThanOrEqual(abs(lumaShift(shadows, light)), 2, "and leaves the light end")
        let highlights = render(recipe([(.gradeHighlightLum, -100)]))
        XCTAssertLessThan(lumaShift(highlights, light), -10, "highlight luminance cuts the light end")
        XCTAssertLessThanOrEqual(abs(lumaShift(highlights, dark)), 2, "and leaves the dark end")
        let midtones = render(recipe([(.gradeMidtoneLum, 100)]))
        XCTAssertGreaterThan(lumaShift(midtones, middle), 10)
        XCTAssertGreaterThan(lumaShift(midtones, middle), 2 * lumaShift(midtones, dark))
        XCTAssertGreaterThan(lumaShift(midtones, middle), 2 * lumaShift(midtones, light))
        let gray = mean(midtones, middle.0, middle.1)
        XCTAssertLessThanOrEqual(max(abs(gray.r - gray.g), abs(gray.g - gray.b)), 1, "a lift keeps gray gray")
    }

    // MARK: Identity

    /// Every grade kind at neutral is the identity, and so is a grade that
    /// tints nothing: a hue with saturation 0, or balance alone, renders
    /// bit-identical to the neutral recipe; the cube those values would build
    /// is the identity cube too.
    func testAGradeThatTintsNothingIsTheIdentity() {
        let base = render(.neutral)
        var allNeutral = Recipe.neutral
        for kind in AdjustmentKind.members(of: .grade) { allNeutral.set(kind, to: kind.neutral) }
        XCTAssertEqual(maxDiff(render(allNeutral), base), 0)
        for kind: AdjustmentKind in [.gradeShadowHue, .gradeMidtoneHue, .gradeHighlightHue, .gradeBalance] {
            XCTAssertEqual(maxDiff(render(recipe([(kind, 70)])), base), 0, "\(kind) alone changes nothing")
        }
        XCTAssertEqual(maxDiff(render(recipe([(.gradeShadowHue, 240), (.gradeMidtoneHue, 120),
                                              (.gradeHighlightHue, 30), (.gradeBalance, -60)])), base), 0)
        // A disabled saturation is not applied.
        var off = recipe([(.gradeShadowHue, 240), (.gradeShadowSat, 80)])
        off.setEnabled(.gradeShadowSat, false)
        XCTAssertEqual(maxDiff(render(off), base), 0)

        let identity = ColorCubes.gradeCube(hue: [0, 0, 0], sat: [0, 0, 0], lum: [0, 0, 0], balance: 0)
        let hueOnly = ColorCubes.gradeCube(hue: [240, 120, 60], sat: [0, 0, 0], lum: [0, 0, 0], balance: 0.7)
        let n = ColorCubes.dimension
        hueOnly.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            identity.withUnsafeBytes { idRaw in
                let q = idRaw.bindMemory(to: Float.self)
                var worst: Float = 0
                for i in 0..<(n * n * n * 4) { worst = max(worst, abs(p[i] - q[i])) }
                XCTAssertLessThan(worst, 1e-6)
            }
            // And the identity cube is the identity: entry i holds its own coordinate.
            let i = 5 + 7 * n + 11 * n * n
            XCTAssertEqual(p[i * 4], Float(5) / Float(n - 1), accuracy: 1e-6)
            XCTAssertEqual(p[i * 4 + 1], Float(7) / Float(n - 1), accuracy: 1e-6)
            XCTAssertEqual(p[i * 4 + 2], Float(11) / Float(n - 1), accuracy: 1e-6)
        }
    }

    /// The grade cube stays inside the shared scratch pool without growing it.
    func testGradeCubeFitsTheSharedPool() {
        _ = ColorCubes.gradeCube(hue: [240, 120, 60], sat: [1, 1, 1], lum: [1, -1, 1], balance: 0.5)
        let ws = ColorCubes.Workspace.shared
        XCTAssertGreaterThan(ws.used, 0)
        XCTAssertLessThanOrEqual(ws.used, ws.capacity - 32, "a grade cube takes \(ws.used) of \(ws.capacity) buffers; keep 32 spare")
    }
}
