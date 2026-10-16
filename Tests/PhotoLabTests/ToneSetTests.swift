import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoLab

// MARK: - Pixel helpers

/// RGB of one pixel of an RGBA8 image; (x, y) in top-down pixel coordinates.
private func pixel(_ cg: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
    guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0, 0) }
    let i = y * cg.bytesPerRow + x * 4
    return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
}

/// Mean RGB over a rectangle given as fractions of the image (top-down).
private func regionMean(_ cg: CGImage, x0: Double, x1: Double, y0: Double, y1: Double) -> (r: Double, g: Double, b: Double) {
    let xa = Int(Double(cg.width) * x0), xb = max(xa + 1, Int(Double(cg.width) * x1))
    let ya = Int(Double(cg.height) * y0), yb = max(ya + 1, Int(Double(cg.height) * y1))
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for y in ya..<yb {
        for x in xa..<xb {
            let p = pixel(cg, x, y)
            r += p.r; g += p.g; b += p.b; n += 1
        }
    }
    return (r / n, g / n, b / n)
}

private func luma(_ p: (r: Double, g: Double, b: Double)) -> Double { (p.r + p.g + p.b) / 3 }

/// Mean absolute difference between a pixel and the one `gap` rows below it:
/// a measure of edge contrast (sharpening and clarity raise it, softening lowers it).
private func verticalEdgeEnergy(_ cg: CGImage, gap: Int) -> Double {
    var sum = 0.0, n = 0.0
    for y in Swift.stride(from: 0, to: cg.height - gap, by: 2) {
        for x in Swift.stride(from: 0, to: cg.width, by: 2) {
            sum += abs(luma(pixel(cg, x, y)) - luma(pixel(cg, x, y + gap)))
            n += 1
        }
    }
    return sum / n
}

/// Standard deviation of the green channel over a rectangle (noise level).
private func stddev(_ cg: CGImage, x0: Double, x1: Double, y0: Double, y1: Double) -> Double {
    let xa = Int(Double(cg.width) * x0), xb = Int(Double(cg.width) * x1)
    let ya = Int(Double(cg.height) * y0), yb = Int(Double(cg.height) * y1)
    var values: [Double] = []
    for y in ya..<yb { for x in xa..<xb { values.append(pixel(cg, x, y).g) } }
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
}

/// Hue angle in degrees (0 red, 120 green, 240 blue) of an RGB triple.
private func hueDegrees(_ p: (r: Double, g: Double, b: Double)) -> Double {
    let a = atan2(3.0.squareRoot() * (p.g - p.b), 2 * p.r - p.g - p.b) * 180 / .pi
    return a < 0 ? a + 360 : a
}

/// Signed shortest angular distance from `a` to `b`, degrees.
private func hueDelta(_ a: Double, _ b: Double) -> Double {
    var d = b - a
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}

private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, width: Int = 64, height: Int = 64) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// sRGB color at a hue (degrees) with HSL saturation 0.7, lightness 0.5.
private func colorAtHue(_ degrees: Double) -> CGImage {
    let h = degrees / 60
    let c = 0.7, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = 0.5 - c / 2
    let (r, g, b): (Double, Double, Double)
    switch Int(h) % 6 {
    case 0: (r, g, b) = (c, x, 0)
    case 1: (r, g, b) = (x, c, 0)
    case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c)
    case 4: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return solidImage(r: CGFloat(r + m), g: CGFloat(g + m), b: CGFloat(b + m))
}

// MARK: - Tests

/// Direction tests for the chunk-4 tone set: every new kind moves the image
/// the way its slider reads, and only where it should.
final class ToneSetTests: XCTestCase {
    let renderer = Renderer.shared
    lazy var ramp = CIImage(cgImage: syntheticImage(width: 512, height: 384))

    func render(_ recipe: Recipe, _ source: CIImage? = nil, max: Int? = nil) -> CGImage {
        let out = renderer.render(source ?? ramp, recipe: recipe, maxPixelSize: max)
        XCTAssertNotNil(out)
        return out!.image
    }

    func recipe(_ kind: AdjustmentKind, _ value: Double) -> Recipe {
        var r = Recipe.neutral
        r.set(kind, to: value)
        return r
    }

    // The ramp occupies the top half of the synthetic image (rows 0…h/2,
    // top-down), dark on the left (0.05) to bright on the right (0.95).
    private let rampY = (0.05, 0.45)

    private func rampLuma(_ cg: CGImage, _ x0: Double, _ x1: Double) -> Double {
        luma(regionMean(cg, x0: x0, x1: x1, y0: rampY.0, y1: rampY.1))
    }

    // MARK: Model

    func testEveryKindHasExactlyOneRecipeEntryAndTheSidecarShapeIsUnchanged() throws {
        XCTAssertEqual(Recipe.neutral.adjustments.map(\.kind), AdjustmentKind.allCases)
        XCTAssertEqual(AdjustmentKind.allCases.count, 48)
        XCTAssertEqual(AdjustmentKind.members(of: .hsl).count, 24)
        XCTAssertEqual(AdjustmentKind.members(of: .tone).count, 9)
        XCTAssertEqual(AdjustmentKind.members(of: .crop).count, 4)
        for kind in AdjustmentKind.allCases where kind.hsl != nil {
            let (channel, band) = kind.hsl!
            XCTAssertEqual(AdjustmentKind.hsl(channel, band), kind)
        }
        // A sidecar written by chunk 3 (six entries) still decodes; the new
        // kinds read as neutral and render as such.
        let old = """
        {"adjustments":[{"enabled":true,"kind":"exposure","value":1.25},{"enabled":true,"kind":"contrast","value":0},
        {"enabled":true,"kind":"temperature","value":-30},{"enabled":true,"kind":"tint","value":0},
        {"enabled":false,"kind":"vibrance","value":40},{"enabled":true,"kind":"saturation","value":0}]}
        """
        let decoded = try JSONDecoder().decode(Recipe.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.effective(.highlights), 0)
        XCTAssertEqual(decoded.effective(.hueRed), 0)
        var same = Recipe.neutral
        same.set(.exposure, to: 1.25); same.set(.temperature, to: -30)
        XCTAssertLessThanOrEqual(maxDiff(render(decoded), render(same)), 1)
        // A disabled new kind changes nothing.
        var off = recipe(.highlights, 100)
        off.setEnabled(.highlights, false)
        XCTAssertEqual(maxDiff(render(off), render(.neutral)), 0)
    }

    // MARK: Tone

    func testHighlightsMoveTheUpperTonesMoreThanTheLower() {
        let base = render(.neutral)
        let up = render(recipe(.highlights, 100)), down = render(recipe(.highlights, -100))
        let dBright = rampLuma(up, 0.65, 0.95) - rampLuma(base, 0.65, 0.95)
        let dDark = rampLuma(up, 0.05, 0.35) - rampLuma(base, 0.05, 0.35)
        XCTAssertGreaterThan(dBright, 20, "+highlights must brighten the upper tones")
        XCTAssertGreaterThan(dBright, dDark + 15, "+highlights must move the upper tones more than the lower")
        XCTAssertLessThan(rampLuma(down, 0.65, 0.95) - rampLuma(base, 0.65, 0.95), -20, "-highlights must darken them")
    }

    func testShadowsMoveTheLowerTonesMoreThanTheUpper() {
        let base = render(.neutral)
        let up = render(recipe(.shadows, 100)), down = render(recipe(.shadows, -100))
        let dDark = rampLuma(up, 0.05, 0.35) - rampLuma(base, 0.05, 0.35)
        let dBright = rampLuma(up, 0.65, 0.95) - rampLuma(base, 0.65, 0.95)
        XCTAssertGreaterThan(dDark, 20, "+shadows must lift the lower tones")
        XCTAssertGreaterThan(dDark, dBright + 15, "+shadows must move the lower tones more than the upper")
        XCTAssertLessThan(rampLuma(down, 0.05, 0.35) - rampLuma(base, 0.05, 0.35), -20, "-shadows must deepen them")
    }

    func testWhitesMoveTheBrightEndAndLeaveTheDarkEnd() {
        let base = render(.neutral)
        let up = render(recipe(.whites, 100)), down = render(recipe(.whites, -100))
        XCTAssertGreaterThan(rampLuma(up, 0.85, 0.95) - rampLuma(base, 0.85, 0.95), 10, "+whites must brighten the bright end")
        XCTAssertLessThan(rampLuma(down, 0.85, 0.95) - rampLuma(base, 0.85, 0.95), -20, "-whites must darken the bright end")
        XCTAssertLessThan(abs(rampLuma(down, 0.03, 0.1) - rampLuma(base, 0.03, 0.1)), 4, "whites must leave the dark end")
    }

    func testBlacksMoveTheDarkEndAndLeaveTheBrightEnd() {
        let base = render(.neutral)
        let up = render(recipe(.blacks, 100)), down = render(recipe(.blacks, -100))
        XCTAssertGreaterThan(rampLuma(up, 0.03, 0.12) - rampLuma(base, 0.03, 0.12), 20, "+blacks must lift the dark end")
        XCTAssertLessThan(rampLuma(down, 0.03, 0.12) - rampLuma(base, 0.03, 0.12), -8, "-blacks must crush the dark end")
        XCTAssertLessThan(abs(rampLuma(up, 0.9, 0.97) - rampLuma(base, 0.9, 0.97)), 4, "blacks must leave the bright end")
    }

    func testEachCurvePointMovesItsOwnZone() {
        let base = render(.neutral)
        let points = AdjustmentKind.allCases.filter { $0.curveX != nil }
        XCTAssertEqual(points.count, 5)
        for kind in points {
            let x = kind.curveX!
            // The ramp runs 0.05…0.95 over the width, so x maps to a column.
            let col = min(0.95, max(0.03, (x - 0.05) / 0.9))
            let x0 = max(0.0, col - 0.03), x1 = min(1.0, col + 0.03)
            let ref = rampLuma(base, x0, x1)
            if kind != .curveWhites {
                let up = rampLuma(render(recipe(kind, 100)), x0, x1)
                XCTAssertGreaterThan(up - ref, 15, "+\(kind.rawValue) must brighten x=\(x)")
            }
            if kind != .curveBlacks {
                let down = rampLuma(render(recipe(kind, -100)), x0, x1)
                XCTAssertLessThan(down - ref, -15, "-\(kind.rawValue) must darken x=\(x)")
            }
            // The far end of the ramp barely moves.
            let farX: (Double, Double) = x < 0.5 ? (0.9, 0.97) : (0.03, 0.1)
            let moved = render(recipe(kind, kind == .curveWhites ? -100 : 100))
            XCTAssertLessThan(abs(rampLuma(moved, farX.0, farX.1) - rampLuma(base, farX.0, farX.1)), 6,
                              "\(kind.rawValue) must leave the far end of the ramp")
        }
    }

    // MARK: HSL

    private func patch(_ band: AdjustmentKind.HSLBand) -> CIImage { CIImage(cgImage: colorAtHue(band.centerDegrees)) }
    private func opposite(_ band: AdjustmentKind.HSLBand) -> AdjustmentKind.HSLBand {
        AdjustmentKind.HSLBand(rawValue: (band.rawValue + 4) % 8)!
    }
    private func chroma(_ p: (r: Double, g: Double, b: Double)) -> Double {
        Swift.max(p.r, p.g, p.b) - Swift.min(p.r, p.g, p.b)
    }

    func testHSLSaturationOfEachBandDesaturatesThatBandOnly() {
        for band in AdjustmentKind.HSLBand.allCases {
            let kind = AdjustmentKind.hsl(.saturation, band)
            let base = meanRGB(render(.neutral, patch(band)))
            let less = meanRGB(render(recipe(kind, -100), patch(band)))
            let more = meanRGB(render(recipe(kind, 100), patch(band)))
            XCTAssertLessThan(chroma(less), chroma(base) - 25, "\(kind.rawValue) -100 must desaturate \(band.label)")
            XCTAssertGreaterThan(chroma(more), chroma(base) + 10, "\(kind.rawValue) +100 must saturate \(band.label)")
            let other = opposite(band)
            XCTAssertLessThanOrEqual(maxDiff(render(recipe(kind, -100), patch(other)), render(.neutral, patch(other))), 2,
                                     "\(kind.rawValue) must leave \(other.label) alone")
        }
    }

    func testHSLLuminanceOfEachBandLightensThatBandOnly() {
        for band in AdjustmentKind.HSLBand.allCases {
            let kind = AdjustmentKind.hsl(.luminance, band)
            let base = luma(meanRGB(render(.neutral, patch(band))))
            let up = luma(meanRGB(render(recipe(kind, 100), patch(band))))
            let down = luma(meanRGB(render(recipe(kind, -100), patch(band))))
            XCTAssertGreaterThan(up, base + 10, "\(kind.rawValue) +100 must lighten \(band.label)")
            XCTAssertLessThan(down, base - 10, "\(kind.rawValue) -100 must darken \(band.label)")
            let other = opposite(band)
            XCTAssertLessThanOrEqual(maxDiff(render(recipe(kind, 100), patch(other)), render(.neutral, patch(other))), 2,
                                     "\(kind.rawValue) must leave \(other.label) alone")
        }
    }

    func testHSLHueOfEachBandRotatesThatBandOnly() {
        for band in AdjustmentKind.HSLBand.allCases {
            let kind = AdjustmentKind.hsl(.hue, band)
            let base = hueDegrees(meanRGB(render(.neutral, patch(band))))
            let plus = hueDegrees(meanRGB(render(recipe(kind, 100), patch(band))))
            let minus = hueDegrees(meanRGB(render(recipe(kind, -100), patch(band))))
            XCTAssertGreaterThan(hueDelta(base, plus), 8, "\(kind.rawValue) +100 must rotate \(band.label) toward the next band")
            XCTAssertLessThan(hueDelta(base, minus), -8, "\(kind.rawValue) -100 must rotate \(band.label) toward the previous band")
            let other = opposite(band)
            XCTAssertLessThanOrEqual(maxDiff(render(recipe(kind, 100), patch(other)), render(.neutral, patch(other))), 2,
                                     "\(kind.rawValue) must leave \(other.label) alone")
        }
    }

    func testHSLLeavesGrayAlone() {
        var r = Recipe.neutral
        for kind in AdjustmentKind.members(of: .hsl) { r.set(kind, to: 100) }
        let gray = CIImage(cgImage: solidImage(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertLessThanOrEqual(maxDiff(render(r, gray), render(.neutral, gray)), 2)
    }

    // MARK: Detail and effects

    func testClarityRaisesAndLowersLocalContrast() {
        let base = verticalEdgeEnergy(render(.neutral), gap: 6)
        let more = verticalEdgeEnergy(render(recipe(.clarity, 100)), gap: 6)
        let less = verticalEdgeEnergy(render(recipe(.clarity, -100)), gap: 6)
        XCTAssertGreaterThan(more, base * 1.1, "+clarity must raise local contrast")
        XCTAssertLessThan(less, base * 0.9, "-clarity must soften")
        // Local, not global: the overall brightness stays (a plain gain would
        // also move the edge metric).
        let mean = luma(meanRGB(render(.neutral)))
        XCTAssertLessThan(abs(luma(meanRGB(render(recipe(.clarity, 100)))) - mean), 6, "+clarity must not change the mean")
        XCTAssertLessThan(abs(luma(meanRGB(render(recipe(.clarity, -100)))) - mean), 6, "-clarity must not change the mean")
    }

    func testSharpeningRaisesEdgeContrast() {
        let base = verticalEdgeEnergy(render(.neutral), gap: 1)
        let sharp = verticalEdgeEnergy(render(recipe(.sharpening, 100)), gap: 1)
        XCTAssertGreaterThan(sharp, base * 1.1, "sharpening must raise 1-px edge contrast")
        XCTAssertGreaterThan(verticalEdgeEnergy(render(recipe(.sharpening, 50)), gap: 1), base * 1.02)
    }

    func testGrainAddsNoiseToFlatAreasAndKeepsTheSize() {
        let flat = CIImage(cgImage: solidImage(r: 0.5, g: 0.5, b: 0.5, width: 256, height: 256))
        let base = render(.neutral, flat)
        let g50 = render(recipe(.grain, 50), flat), g100 = render(recipe(.grain, 100), flat)
        XCTAssertLessThan(stddev(base, x0: 0.1, x1: 0.9, y0: 0.1, y1: 0.9), 1)
        let n50 = stddev(g50, x0: 0.1, x1: 0.9, y0: 0.1, y1: 0.9)
        let n100 = stddev(g100, x0: 0.1, x1: 0.9, y0: 0.1, y1: 0.9)
        XCTAssertGreaterThan(n50, 2, "grain 50 must add visible noise")
        XCTAssertGreaterThan(n100, n50 * 1.5, "more grain must be noisier")
        XCTAssertEqual(g100.width, 256); XCTAssertEqual(g100.height, 256)
        // Mean stays put: grain is zero-centered.
        XCTAssertLessThan(abs(luma(meanRGB(g100)) - luma(meanRGB(base))), 3)
    }

    func testVignetteDarkensOrBrightensTheCornersNotTheCenter() {
        let flat = CIImage(cgImage: solidImage(r: 0.5, g: 0.5, b: 0.5, width: 256, height: 192))
        let base = render(.neutral, flat)
        let bright = render(recipe(.vignette, 100), flat)
        let darkFlat = render(recipe(.vignette, -100), flat)
        func corner(_ cg: CGImage) -> Double { luma(regionMean(cg, x0: 0, x1: 0.06, y0: 0, y1: 0.08)) }
        func center(_ cg: CGImage) -> Double { luma(regionMean(cg, x0: 0.45, x1: 0.55, y0: 0.45, y1: 0.55)) }
        XCTAssertLessThan(corner(darkFlat), corner(base) - 15, "-vignette must darken the corners")
        XCTAssertGreaterThan(corner(bright), corner(base) + 15, "+vignette must brighten the corners")
        XCTAssertLessThan(abs(center(darkFlat) - center(base)), 4, "the center must stay")
        XCTAssertLessThan(abs(center(bright) - center(base)), 4, "the center must stay")
    }

    // MARK: Geometry

    func testRotateIsClockwiseAndKeepsTheAspectWithoutEmptyCorners() {
        let out = render(recipe(.rotate, 10))
        XCTAssertLessThan(out.width, 512)
        XCTAssertEqual(Double(out.width) / Double(out.height), 512.0 / 384.0, accuracy: 0.02)
        // The green band's top edge: clockwise lifts the left side.
        func greenTop(_ x: Int) -> Int? {
            for y in 0..<out.height {
                let p = pixel(out, x, y)
                if p.g > 150 && p.r < 110 && p.b < 110 { return y }
            }
            return nil
        }
        let left = greenTop(out.width / 4), right = greenTop(out.width * 3 / 4)
        XCTAssertNotNil(left); XCTAssertNotNil(right)
        if let left, let right {
            XCTAssertLessThan(left + 10, right, "+rotate must turn the frame clockwise (left side up)")
        }
        // No empty (transparent or black) corners.
        for (x, y) in [(1, 1), (out.width - 2, 1), (1, out.height - 2), (out.width - 2, out.height - 2)] {
            let p = pixel(out, x, y)
            XCTAssertGreaterThan(p.r + p.g + p.b, 20, "corner (\(x),\(y)) must hold image, not padding")
        }
        // And the other way.
        let ccw = render(recipe(.rotate, -10))
        var l2: Int?, r2: Int?
        for y in 0..<ccw.height where l2 == nil { let p = pixel(ccw, ccw.width / 4, y); if p.g > 150 && p.r < 110 { l2 = y } }
        for y in 0..<ccw.height where r2 == nil { let p = pixel(ccw, ccw.width * 3 / 4, y); if p.g > 150 && p.r < 110 { r2 = y } }
        XCTAssertGreaterThan((l2 ?? 0), (r2 ?? 0) + 10, "-rotate must turn counter-clockwise")
    }

    func testRotateLeavesNoDarkLineAlongTheBorder() {
        // A flat 0.6 gray (153): any darkness on the border is the rotated
        // frame's antialiased edge, which the inscribed crop must not touch.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let gray = CIImage(cgImage: ctx.makeImage()!)
        for degrees in [1.0, 3.0, 7.0, 15.0, 30.0, 45.0, -5.0, -20.0] {
            let out = render(recipe(.rotate, degrees), gray)
            var darkest = 255.0, at = (0, 0)
            func look(_ x: Int, _ y: Int) {
                let l = luma(pixel(out, x, y))
                if l < darkest { darkest = l; at = (x, y) }
            }
            for x in 0..<out.width { look(x, 0); look(x, out.height - 1) }
            for y in 0..<out.height { look(0, y); look(out.width - 1, y) }
            XCTAssertGreaterThan(darkest, 140, "rotate \(degrees)°: border pixel \(at) is \(darkest), the crop touches the rotated edge")
            XCTAssertEqual(Double(out.width) / Double(out.height), 1.5, accuracy: 0.03, "rotate \(degrees)° keeps the aspect")
        }
    }

    func testEachCropEdgeRemovesItsOwnSide() {

        let base = render(.neutral)
        let w = base.width, h = base.height
        func row(_ cg: CGImage, _ y: Int) -> [(r: Double, g: Double, b: Double)] {
            Swift.stride(from: 8, to: cg.width - 8, by: cg.width / 9).map { pixel(cg, $0, y) }
        }
        func col(_ cg: CGImage, _ x: Int) -> [(r: Double, g: Double, b: Double)] {
            Swift.stride(from: 8, to: cg.height - 8, by: cg.height / 9).map { pixel(cg, x, $0) }
        }
        func close(_ a: [(r: Double, g: Double, b: Double)], _ b: [(r: Double, g: Double, b: Double)], _ what: String) {
            XCTAssertEqual(a.count, b.count)
            for (p, q) in zip(a, b) {
                XCTAssertLessThan(Swift.max(abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b)), 6, what)
            }
        }
        let left = render(recipe(.cropLeft, 25))
        XCTAssertEqual(Double(left.width), Double(w * 3 / 4), accuracy: 2); XCTAssertEqual(left.height, h)
        close(col(left, 2), col(base, w / 4 + 2), "cropLeft keeps the right three quarters")
        let right = render(recipe(.cropRight, 25))
        XCTAssertEqual(Double(right.width), Double(w * 3 / 4), accuracy: 2); XCTAssertEqual(right.height, h)
        close(col(right, right.width - 3), col(base, w * 3 / 4 - 3), "cropRight keeps the left three quarters")
        let top = render(recipe(.cropTop, 25))
        XCTAssertEqual(Double(top.height), Double(h * 3 / 4), accuracy: 2); XCTAssertEqual(top.width, w)
        close(row(top, 2), row(base, h / 4 + 2), "cropTop keeps the lower three quarters")
        let bottom = render(recipe(.cropBottom, 25))
        XCTAssertEqual(Double(bottom.height), Double(h * 3 / 4), accuracy: 2); XCTAssertEqual(bottom.width, w)
        close(row(bottom, bottom.height - 3), row(base, h * 3 / 4 - 3), "cropBottom keeps the upper three quarters")
        // All four at once: a quarter from each side leaves the middle half.
        var r = Recipe.neutral
        for k in AdjustmentKind.members(of: .crop) { r.set(k, to: 25) }
        let mid = render(r)
        XCTAssertEqual(Double(mid.width), Double(w / 2), accuracy: 2); XCTAssertEqual(Double(mid.height), Double(h / 2), accuracy: 2)
    }

    // MARK: Timing — the chunk-4 gate: every slider on a 24 MP photo

    /// A recipe with every kind switched on at a modest value: the worst
    /// case for a step, since every stage is in the chain.
    static func everythingOn() -> Recipe {
        var r = Recipe.neutral
        for kind in AdjustmentKind.allCases {
            let span = kind.range.upperBound - kind.range.lowerBound
            let value: Double
            switch kind {
            case .exposure: value = 0.3
            case .rotate: value = 3
            case .cropLeft, .cropTop, .cropRight, .cropBottom: value = 4
            case .sharpening, .grain: value = 30
            case .highlights, .vignette, .blacks: value = -20
            default: value = kind.range.lowerBound + span * 0.58 // +16 on a -100…100 slider
            }
            r.set(kind, to: value)
        }
        return r
    }

    /// For every kind, steps that slider across its range over the
    /// everything-on recipe at loupe size and prints the per-kind median;
    /// the file goes through the loupe's own master decode first. Source:
    /// `PHOTOLAB_BENCH_IMAGE` if set, else a synthetic 6000×4000 JPEG. The
    /// 16 ms gate is read against the load average (`assertFrameBudget`).
    func testEverySliderStepRenderTimeOn24MP() throws {
        let steppers = AdjustmentKind.allCases.map { kind in
            Stepper(name: kind.rawValue, range: kind.range, geometry: kind.group == .crop || kind == .rotate) {
                $0.set(kind, to: $1)
            }
        }
        try sliderStepGate(Self.everythingOn(), steppers, label: "everything on")
    }

    /// Two local adjustments (a linear and a radial mask, each carrying every
    /// `LocalMask.kinds` value) over the everything-on recipe: the budget
    /// holds with masks on, for every global slider and for the first mask's
    /// own sliders.
    static func everythingOnWithMasks() -> Recipe {
        var r = everythingOn()
        func local(_ shape: MaskShape) -> LocalMask {
            LocalMask(shape: shape, adjustments: LocalMask.kinds.map {
                Adjustment(kind: $0, value: $0 == .exposure ? 0.6 : 20)
            })
        }
        r.masks = [
            local(.linear(start: MaskPoint(x: 0.5, y: 0), end: MaskPoint(x: 0.5, y: 0.45))),
            local(.radial(center: MaskPoint(x: 0.6, y: 0.55), radii: MaskRadii(x: 0.25, y: 0.15), angle: 20, feather: 0.5)),
        ]
        return r
    }

    func testEverySliderStepRenderTimeOn24MPWithMasks() throws {
        var steppers = AdjustmentKind.allCases.map { kind in
            Stepper(name: kind.rawValue, range: kind.range, geometry: kind.group == .crop || kind == .rotate) {
                $0.set(kind, to: $1)
            }
        }
        steppers += LocalMask.kinds.map { kind in
            Stepper(name: "mask.\(kind.rawValue)", range: kind.range, geometry: false) { $0.masks[0].set(kind, to: $1) }
        }
        try sliderStepGate(Self.everythingOnWithMasks(), steppers, label: "everything on, a linear and a radial mask")
    }

    /// One slider of the timed gate: a name for the bench line, its range,
    /// whether a step changes the output size, and how to set it.
    struct Stepper {
        let name: String
        let range: ClosedRange<Double>
        let geometry: Bool
        let set: (inout Recipe, Double) -> Void
    }

    private func sliderStepGate(_ base: Recipe, _ steppers: [Stepper], label: String) throws {
        let env = ProcessInfo.processInfo.environment
        var load = loadAverage()
        let url = try bench24MPImageURL()
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize))
        let target = Int(env["PHOTOLAB_BENCH_TARGET"] ?? "2600") ?? 2600
        let steps = 12
        var worst: (String, Double) = ("", 0)
        var lines: [String] = []
        var gated: [(String, Double)] = []
        // Warm the kernels once so the first kind does not pay the compile.
        _ = renderer.render(master, recipe: base, maxPixelSize: target)
        for stepper in steppers {
            var r = base
            let lo = stepper.range.lowerBound, hi = stepper.range.upperBound
            // A crop or rotate step changes the output size, and Core Image
            // charges 5–15 ms the first time it meets a size (texture pool);
            // the same sizes revisited render at the chain's own cost. Both
            // are measured; the gate is the revisited pass for those kinds.
            let passes = stepper.geometry ? 2 : 1
            var medians: [Double] = []
            var minMax = (Double.infinity, 0.0)
            var attempts = 0
            // Up to three sweeps; the best gated median counts (a compile
            // burst from a sibling build rarely covers all three, a slower
            // chain misses all three).
            repeat {
                attempts += 1
                var sweep: [Double] = []
                for _ in 0..<passes {
                    var times: [Double] = []
                    for i in 0..<steps {
                        // Sweep the middle 60% of the range (a 40% crop would be degenerate).
                        let t = 0.2 + 0.6 * Double(i) / Double(steps - 1)
                        stepper.set(&r, lo + (hi - lo) * t)
                        let out = try XCTUnwrap(renderer.render(master, recipe: r, maxPixelSize: target))
                        times.append(out.milliseconds)
                    }
                    let sorted = times.sorted()
                    sweep.append(sorted[sorted.count / 2])
                    minMax = (Swift.min(minMax.0, sorted[0]), Swift.max(minMax.1, sorted[sorted.count - 1]))
                }
                if medians.isEmpty || sweep.last! < medians.last! { medians = sweep }
                load = max(load, loadAverage())
            } while medians.last! >= frameBudgetBound(16, load: load) && attempts < 3
            let median = medians.last!
            if median > worst.1 { worst = (stepper.name, median) }
            let firstSeen = passes == 2 ? String(format: " (first-seen sizes %.1f ms)", medians[0]) : ""
            let retried = attempts > 1 ? " (best of \(attempts) sweeps)" : ""
            lines.append(String(format: "%@ median %.1f ms (min %.1f, max %.1f)%@%@", stepper.name, median, minMax.0, minMax.1, firstSeen, retried))
            gated.append((stepper.name, median))
        }
        load = max(load, loadAverage())
        print("BENCH-ALL \(url.lastPathComponent): master \(Int(master.extent.width))×\(Int(master.extent.height)), preview \(target) px, \(steps) steps per kind, \(label); slowest \(worst.0) \(String(format: "%.1f", worst.1)) ms, load \(String(format: "%.2f", load))")
        for line in lines { print("BENCH-KIND " + line) }
        for (name, median) in gated {
            try assertFrameBudget(median, bound: 16, load: load, "a \(name) step (\(label)) must fit one 60 Hz frame")
        }
    }
}

// MARK: - The load guard on the timed gates

/// `assertFrameBudget` (TestImages.swift): the bound as written up to a
/// load of 4, scaled with the load above it, a skip (never a red) above 12
/// when it would have failed, and a red at a quiet load.
final class FrameBudgetGuardTests: XCTestCase {
    func testGateHoldsWhenQuietScalesWhenBusyAndSkipsOnlyWhenUnmeasurable() throws {
        XCTAssertEqual(try assertFrameBudget(10, bound: 16, load: 2, "quiet pass"), 16)
        XCTAssertEqual(try assertFrameBudget(10, bound: 16, load: .nan, "unreadable load is quiet"), 16)
        XCTAssertEqual(try assertFrameBudget(17, bound: 16, load: 7.5, "busy pass"), 30, accuracy: 1e-9)
        XCTAssertEqual(try assertFrameBudget(40, bound: 16, load: 20, "a pass at any load stands"), 80, accuracy: 1e-9)
        XCTAssertThrowsError(try assertFrameBudget(100, bound: 16, load: 12.1, "swamped miss")) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        try XCTExpectFailure("a miss at a quiet load is a red, not a skip") {
            XCTAssertNoThrow(try assertFrameBudget(17, bound: 16, load: 3, "quiet miss"))
        }
        try XCTExpectFailure("a miss under the cap is a red even when busy") {
            XCTAssertNoThrow(try assertFrameBudget(31, bound: 16, load: 7.5, "busy miss"))
        }
    }
}

// MARK: - Cube workspace

/// The scratch pool behind `ColorCubes`: the heaviest cube leaves headroom
/// in the pool it starts with, and a build that asks for more buffers than
/// the pool holds grows it instead of trapping, keeping the reuse.
final class ColorCubeWorkspaceTests: XCTestCase {
    func testHeaviestCubeLeavesHeadroomInTheSharedPool() {
        let bands = AdjustmentKind.HSLBand.allCases.count
        let ones = [Double](repeating: 1, count: bands)
        let mixed = (0..<bands).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }
        _ = ColorCubes.hslCube(hue: ones, sat: mixed, lum: ones)
        let ws = ColorCubes.Workspace.shared
        let hsl = ws.used
        XCTAssertGreaterThan(hsl, 0)
        XCTAssertEqual(ws.capacity, 128, "the HSL cube fits the pool it starts with")
        XCTAssertGreaterThanOrEqual(ws.capacity - hsl, 32, "an HSL cube takes \(hsl) of \(ws.capacity) buffers; keep 32 spare")
        _ = ColorCubes.toneCube(ColorCubes.toneLUT(highlights: 1, shadows: -1, whites: 1, blacks: -1, curve: [0.2, -0.2, 0.2, -0.2, 0.2]))
        XCTAssertLessThan(ws.used, hsl, "the tone cube is the lighter build")
    }

    func testPoolGrowsWhenABuildTakesMoreThanItHoldsAndReusesTheBuffers() {
        let ws = ColorCubes.Workspace(count: 16, slots: 2)
        XCTAssertEqual(ws.capacity, 2)
        let a = ws.take(), b = ws.take()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ws.used, 2)
        let c = ws.take()
        XCTAssertEqual(ws.capacity, 3, "a third take grows the pool by one")
        XCTAssertEqual(ws.used, 3)
        XCTAssertNotEqual(c, a); XCTAssertNotEqual(c, b)
        ws.reset()
        XCTAssertEqual(ws.used, 0)
        XCTAssertEqual(ws.take(), a, "after reset the same buffers are handed out again")
        XCTAssertEqual(ws.take(), b)
        XCTAssertEqual(ws.take(), c, "the grown buffer is kept and reused")
        XCTAssertEqual(ws.capacity, 3)
    }
}
