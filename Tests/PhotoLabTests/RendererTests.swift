import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// Mean RGB of a CGImage (RGBA8), sampling every `stride`-th pixel.
private func meanRGB(_ cg: CGImage, stride: Int = 1) -> (r: Double, g: Double, b: Double) {
    guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0, 0) }
    let bpr = cg.bytesPerRow, w = cg.width, h = cg.height
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let i = y * bpr + x * 4
            r += Double(p[i]); g += Double(p[i + 1]); b += Double(p[i + 2]); n += 1
            x += stride
        }
        y += stride
    }
    return (r / n, g / n, b / n)
}

/// Largest per-channel difference between two same-sized RGBA8 images.
private func maxDiff(_ a: CGImage, _ b: CGImage) -> Int {
    guard let da = a.dataProvider?.data, let pa = CFDataGetBytePtr(da),
          let db = b.dataProvider?.data, let pb = CFDataGetBytePtr(db),
          a.width == b.width, a.height == b.height else { return Int.max }
    var worst = 0
    for y in 0..<a.height {
        for x in 0..<a.width {
            for c in 0..<3 {
                let d = abs(Int(pa[y * a.bytesPerRow + x * 4 + c]) - Int(pb[y * b.bytesPerRow + x * 4 + c]))
                if d > worst { worst = d }
            }
        }
    }
    return worst
}

/// A synthetic photo: a horizontal luminance ramp with colored bands, so
/// every test sees both neutral and saturated pixels.
private func syntheticImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
                  CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.8, 0.2), (0.2, 0.2, 0.8), (0.7, 0.6, 0.2)]
    let bandH = CGFloat(height) / 8
    for (i, c) in bands.enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(i) * bandH, width: CGFloat(width), height: bandH * 0.8))
    }
    return ctx.makeImage()!
}

final class RendererTests: XCTestCase {
    let renderer = Renderer.shared
    lazy var small = CIImage(cgImage: syntheticImage(width: 512, height: 384))

    func render(_ recipe: Recipe, _ source: CIImage? = nil, max: Int? = nil) -> CGImage {
        let out = renderer.render(source ?? small, recipe: recipe, maxPixelSize: max)
        XCTAssertNotNil(out)
        return out!.image
    }

    func recipe(_ kind: AdjustmentKind, _ value: Double, enabled: Bool = true) -> Recipe {
        var r = Recipe.neutral
        r.set(kind, to: value)
        r.setEnabled(kind, enabled)
        return r
    }

    // MARK: Recipe model

    func testNeutralRecipeHasEveryKindOnceInChainOrder() {
        XCTAssertEqual(Recipe.neutral.adjustments.map(\.kind), AdjustmentKind.allCases)
        XCTAssertTrue(Recipe.neutral.isNeutral)
        var r = Recipe.neutral
        r.set(.exposure, to: 1)
        XCTAssertFalse(r.isNeutral)
        r.setEnabled(.exposure, false)
        XCTAssertTrue(r.isNeutral, "a disabled entry counts as neutral")
        r.resetAll()
        XCTAssertEqual(r, .neutral)
    }

    func testRecipeRoundTripsThroughJSON() throws {
        var r = Recipe.neutral
        r.set(.temperature, to: 35)
        r.setEnabled(.vibrance, false)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertEqual(back, r)
    }

    // MARK: The chain

    func testNeutralRecipeIsIdentity() {
        let out = render(.neutral)
        XCTAssertLessThanOrEqual(maxDiff(out, syntheticImage(width: 512, height: 384)), 2)
    }

    func testDisabledAdjustmentChangesNothing() {
        let off = render(recipe(.exposure, 2, enabled: false))
        XCTAssertLessThanOrEqual(maxDiff(off, render(.neutral)), 0)
        let on = render(recipe(.exposure, 2))
        XCTAssertGreaterThan(maxDiff(on, render(.neutral)), 20, "the enabled control must differ")
    }

    func testExposureBrightensAndDarkens() {
        let base = meanRGB(render(.neutral))
        let up = meanRGB(render(recipe(.exposure, 1)))
        let down = meanRGB(render(recipe(.exposure, -1)))
        XCTAssertGreaterThan(up.g, base.g + 10)
        XCTAssertLessThan(down.g, base.g - 10)
    }

    func testTemperatureWarmsForPositiveValues() {
        let base = meanRGB(render(.neutral))
        let warm = meanRGB(render(recipe(.temperature, 100)))
        let cool = meanRGB(render(recipe(.temperature, -100)))
        XCTAssertGreaterThan(warm.r - warm.b, base.r - base.b + 5, "+temperature must be warmer (more red than blue)")
        XCTAssertLessThan(cool.r - cool.b, base.r - base.b - 5, "-temperature must be cooler")
    }

    func testTintIsMagentaForPositiveValues() {
        let base = meanRGB(render(.neutral))
        let magenta = meanRGB(render(recipe(.tint, 100)))
        let green = meanRGB(render(recipe(.tint, -100)))
        let baseG = base.g - (base.r + base.b) / 2
        XCTAssertLessThan(magenta.g - (magenta.r + magenta.b) / 2, baseG - 5, "+tint must lose green")
        XCTAssertGreaterThan(green.g - (green.r + green.b) / 2, baseG + 5, "-tint must gain green")
    }

    func testSaturationMinusHundredIsGray() {
        let gray = render(recipe(.saturation, -100))
        guard let data = gray.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return XCTFail() }
        var worst = 0
        for y in Swift.stride(from: 0, to: gray.height, by: 7) {
            for x in Swift.stride(from: 0, to: gray.width, by: 7) {
                let i = y * gray.bytesPerRow + x * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                worst = Swift.max(worst, abs(r - g), abs(g - b))
            }
        }
        XCTAssertLessThanOrEqual(worst, 3)
        let more = meanRGB(render(recipe(.saturation, 60)))
        let base = meanRGB(render(.neutral))
        XCTAssertNotEqual(more.r.rounded(), base.r.rounded())
    }

    func testContrastAndVibranceMoveTheImage() {
        let base = render(.neutral)
        XCTAssertGreaterThan(maxDiff(render(recipe(.contrast, 50)), base), 10)
        XCTAssertGreaterThan(maxDiff(render(recipe(.vibrance, 80)), base), 10)
    }

    func testPreviewScalesDownToFitAndNeverUp() {
        let fit = render(.neutral, max: 128)
        XCTAssertEqual(fit.width, 128)
        XCTAssertEqual(fit.height, 96)
        let same = render(.neutral, max: 4096)
        XCTAssertEqual(same.width, 512)
    }

    // MARK: Timing — the chunk-2 gate: a slider step on a 24 MP photo

    /// Renders the chain at loupe size for a sweep of exposure steps and
    /// prints the per-step ms. Source: `PHOTOLAB_BENCH_IMAGE` if set, else a
    /// synthetic 6000×4000 JPEG; either way the file goes through the loupe's
    /// own preview-master decode first, so the numbers are the app's.
    func testSliderStepRenderTimeOn24MP() throws {
        let env = ProcessInfo.processInfo.environment
        let url: URL
        if let path = env["PHOTOLAB_BENCH_IMAGE"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-bench-24mp.jpg")
            if !FileManager.default.fileExists(atPath: url.path) {
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, syntheticImage(width: 6000, height: 4000), nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
        }
        let label = url.lastPathComponent
        let tDecode0 = Date()
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize),
                                   "could not decode \(url.path)")
        let decodeMs = Date().timeIntervalSince(tDecode0) * 1000
        // The loupe on a 16" display: ~2600 px for the long side at 2x.
        let target = Int(env["PHOTOLAB_BENCH_TARGET"] ?? "2600") ?? 2600

        var times: [Double] = []
        var r = Recipe.neutral
        r.set(.contrast, to: 20); r.set(.temperature, to: 15); r.set(.vibrance, to: 25)
        for step in 0..<30 {
            r.set(.exposure, to: -1.5 + Double(step) * 0.1)
            let out = try XCTUnwrap(renderer.render(master, recipe: r, maxPixelSize: target))
            times.append(out.milliseconds)
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let full = renderer.render(master, recipe: r)
        print(String(format: "BENCH %@: master %.0f×%.0f (decode %.0f ms); preview %d px: first %.1f ms, median %.1f ms, min %.1f ms, max %.1f ms over %d steps; full-size render %.0f×%.0f %.1f ms",
                     label, master.extent.width, master.extent.height, decodeMs, target,
                     times[0], median, sorted[0], sorted[sorted.count - 1], times.count,
                     full?.image.width.d ?? 0, full?.image.height.d ?? 0, full?.milliseconds ?? -1))
        XCTAssertLessThan(median, 16, "a slider step must fit one 60 Hz frame")
    }
}

private extension Int { var d: Double { Double(self) } }
