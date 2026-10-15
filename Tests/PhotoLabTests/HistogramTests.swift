import XCTest
import CoreGraphics
import CoreImage
@testable import PhotoLab

/// The histogram and the clipping warning: exact counts on synthetic
/// frames, the per-pixel rule shared by the triangles and the J overlay,
/// and the time budget on a preview-sized frame.
final class HistogramTests: XCTestCase {

    // MARK: Frames

    /// A frame filled with `fill`, with rectangles of other colors painted
    /// over it (CGContext coordinates, origin bottom-left; the histogram does
    /// not care which way is up).
    private func frame(width: Int, height: Int, fill: (UInt8, UInt8, UInt8),
                       blocks: [(CGRect, (UInt8, UInt8, UInt8))] = []) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ c: (UInt8, UInt8, UInt8)) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat(c.0) / 255, CGFloat(c.1) / 255, CGFloat(c.2) / 255, 1])!
        }
        ctx.setFillColor(color(fill))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (rect, c) in blocks {
            ctx.setFillColor(color(c))
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    /// The reference, pixel by pixel, in plain Swift.
    private struct Reference {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var blown = 0
        var crushed = 0
        var blownPixels = Set<Int>()
        var crushedPixels = Set<Int>()

        init(_ cg: CGImage) {
            let px = RGBA8Pixels(cg)!
            for y in 0..<px.height {
                for x in 0..<px.width {
                    let p = px.pixel(x, y)
                    red[Int(p.r)] += 1; green[Int(p.g)] += 1; blue[Int(p.b)] += 1
                    let hi = p.r >= 254 || p.g >= 254 || p.b >= 254
                    let lo = p.r <= 1 || p.g <= 1 || p.b <= 1
                    if hi { blown += 1; blownPixels.insert(y * px.width + x) }
                    if lo { crushed += 1; crushedPixels.insert(y * px.width + x) }
                }
            }
        }
    }

    // MARK: Clipping fractions

    /// A 25 % pure-white block on mid-gray: highlights 0.25, shadows 0.
    func testWhiteBlockReportsAQuarterOfHighlightsAndNoShadows() throws {
        let w = 400, h = 300
        let cg = frame(width: w, height: h, fill: (128, 128, 128),
                       blocks: [(CGRect(x: 0, y: 0, width: 200, height: 150), (255, 255, 255))])
        let hist = try XCTUnwrap(Histogram.compute(cg))
        XCTAssertEqual(hist.pixelCount, w * h)
        XCTAssertEqual(hist.highlightClipping, 0.25, accuracy: 0.01, "25 % of the pixels are blown")
        XCTAssertEqual(hist.shadowClipping, 0, "nothing is crushed")
        XCTAssertTrue(hist.highlightsClipped, "the highlight triangle lights")
        XCTAssertFalse(hist.shadowsClipped, "the shadow triangle stays dark")
        XCTAssertEqual(hist.red[255], 200 * 150, "the white block is bin 255 of every channel")
        XCTAssertEqual(hist.green[255], 200 * 150)
        XCTAssertEqual(hist.blue[255], 200 * 150)
        XCTAssertEqual(hist.luminance[255], 200 * 150)
        XCTAssertEqual(hist.red[128], w * h - 200 * 150, "the rest is bin 128")
        XCTAssertEqual(hist.luminance[128], w * h - 200 * 150, "gray's luma is gray")
    }

    /// The triangle threshold: 0.1 % of the pixels is dark, just above lights.
    func testWarningLightsAboveATenthOfAPercent() throws {
        let w = 1000, h = 100  // 100 000 px; 0.1 % is 100 px
        let under = frame(width: w, height: h, fill: (128, 128, 128),
                          blocks: [(CGRect(x: 0, y: 0, width: 100, height: 1), (0, 0, 0))])
        let over = frame(width: w, height: h, fill: (128, 128, 128),
                         blocks: [(CGRect(x: 0, y: 0, width: 101, height: 1), (0, 0, 0))])
        let a = try XCTUnwrap(Histogram.compute(under))
        let b = try XCTUnwrap(Histogram.compute(over))
        XCTAssertEqual(a.shadowClipping, 0.001, accuracy: 1e-9)
        XCTAssertFalse(a.shadowsClipped, "exactly 0.1 % does not light the triangle")
        XCTAssertEqual(b.shadowClipping, 0.00101, accuracy: 1e-9)
        XCTAssertTrue(b.shadowsClipped, "0.101 % lights it")
        XCTAssertFalse(a.highlightsClipped)
        XCTAssertFalse(b.highlightsClipped)
    }

    // MARK: Bins

    /// On the synthetic ramp-and-bands photo every channel's bins sum to the
    /// pixel count, the RGB bins match a plain-Swift count exactly, and the
    /// clipping fractions match the per-pixel "any channel" rule.
    func testBinsSumToThePixelCountAndMatchTheReference() throws {
        let cg = syntheticImage(width: 640, height: 480)
        let hist = try XCTUnwrap(Histogram.compute(cg))
        let n = 640 * 480
        XCTAssertEqual(hist.pixelCount, n)
        XCTAssertEqual(hist.red.reduce(0, +), n)
        XCTAssertEqual(hist.green.reduce(0, +), n)
        XCTAssertEqual(hist.blue.reduce(0, +), n)
        XCTAssertEqual(hist.luminance.reduce(0, +), n)
        XCTAssertEqual(hist.red.count, 256)
        XCTAssertEqual(hist.luminance.count, 256)

        let ref = Reference(cg)
        XCTAssertEqual(hist.red, ref.red, "red bins")
        XCTAssertEqual(hist.green, ref.green, "green bins")
        XCTAssertEqual(hist.blue, ref.blue, "blue bins")
        XCTAssertEqual(hist.highlightClipping, Double(ref.blown) / Double(n), accuracy: 1e-12)
        XCTAssertEqual(hist.shadowClipping, Double(ref.crushed) / Double(n), accuracy: 1e-12)

        // Luma is Rec. 709 on the 8-bit values: the mean of the bins is the
        // mean of the per-pixel formula to within a rounding step.
        let mean = hist.luminance.enumerated().reduce(0.0) { $0 + Double($1.offset) * Double($1.element) } / Double(n)
        let (r, g, b) = meanRGB(cg)
        XCTAssertEqual(mean, 0.2126 * r + 0.7152 * g + 0.0722 * b, accuracy: 1.0)
    }

    /// A mixed frame with one channel at the edge on each side: a saturated
    /// red is both blown (R) and crushed (G, B); 253 and 2 are neither.
    func testOneClippedChannelCountsThePixel() throws {
        let cg = frame(width: 100, height: 100, fill: (128, 128, 128), blocks: [
            (CGRect(x: 0, y: 0, width: 10, height: 10), (255, 0, 0)),     // 100 px blown and crushed
            (CGRect(x: 10, y: 0, width: 10, height: 10), (253, 253, 253)), // not blown
            (CGRect(x: 20, y: 0, width: 10, height: 10), (2, 2, 2)),       // not crushed
            (CGRect(x: 30, y: 0, width: 10, height: 10), (254, 128, 128)), // blown
            (CGRect(x: 40, y: 0, width: 10, height: 10), (128, 128, 1)),   // crushed
        ])
        let hist = try XCTUnwrap(Histogram.compute(cg))
        XCTAssertEqual(hist.highlightClipping, 200.0 / 10000, accuracy: 1e-12)
        XCTAssertEqual(hist.shadowClipping, 200.0 / 10000, accuracy: 1e-12)
    }

    // MARK: Timing

    /// A preview-sized frame (2600 px long side, 3:2) in under 20 ms, timed
    /// after one warm-up: the median of five, up to three rounds, the best
    /// round counts (see `assertFrameBudget`).
    func testPreviewSizedFrameUnderTwentyMilliseconds() throws {
        let cg = syntheticImage(width: 2600, height: 1733)
        var load = loadAverage()
        _ = try XCTUnwrap(Histogram.compute(cg))  // warm-up: vImage's threads, the scratch
        var times: [Double] = []
        var median = Double.infinity
        var attempts = 0
        repeat {
            attempts += 1
            var round: [Double] = []
            for _ in 0..<5 {
                let h = try XCTUnwrap(Histogram.compute(cg))
                round.append(h.milliseconds)
                XCTAssertEqual(h.pixelCount, 2600 * 1733)
            }
            round.sort()
            if round[round.count / 2] < median { median = round[round.count / 2]; times = round }
            load = max(load, loadAverage())
        } while median >= frameBudgetBound(20, load: load) && attempts < 3
        print(String(format: "BENCH-HISTOGRAM 2600×1733: median %.2f ms (min %.2f, max %.2f) over 5, best of %d — bound %.0f ms, load %.2f",
                     median, times.first!, times.last!, attempts, frameBudgetBound(20, load: load), load))
        try assertFrameBudget(median, bound: 20, load: load, "the histogram of a 2600 px frame")
    }

    // MARK: The overlay

    /// The J overlay paints pure red over every blown pixel, pure blue over
    /// every crushed one (red wins where both), and leaves every other pixel
    /// byte-identical to the frame; the painted set is exactly the set the
    /// fractions count.
    func testOverlayFlagsExactlyTheClippedPixels() throws {
        // The ramp-and-bands photo plus edge cases on both sides.
        var blocks: [(CGRect, (UInt8, UInt8, UInt8))] = [
            (CGRect(x: 0, y: 0, width: 40, height: 30), (255, 255, 255)),
            (CGRect(x: 40, y: 0, width: 40, height: 30), (0, 0, 0)),
            (CGRect(x: 80, y: 0, width: 40, height: 30), (255, 0, 0)),     // both: red wins
            (CGRect(x: 120, y: 0, width: 40, height: 30), (254, 128, 128)),
            (CGRect(x: 160, y: 0, width: 40, height: 30), (253, 253, 253)),
            (CGRect(x: 200, y: 0, width: 40, height: 30), (1, 128, 128)),
            (CGRect(x: 240, y: 0, width: 40, height: 30), (2, 2, 2)),
            (CGRect(x: 280, y: 0, width: 40, height: 30), (128, 254, 2)),
        ]
        // Thin stripes of every level, so each 8-bit value appears somewhere.
        for v in 0..<256 {
            blocks.append((CGRect(x: v, y: 40, width: 1, height: 20), (UInt8(v), UInt8(255 - v), 128)))
        }
        let cg = frame(width: 320, height: 240, fill: (90, 120, 150), blocks: blocks)
        let hist = try XCTUnwrap(Histogram.compute(cg))
        let ref = Reference(cg)
        let overlay = try XCTUnwrap(ClippingOverlay.compose(over: cg, context: Renderer.shared.context))
        XCTAssertEqual(overlay.width, cg.width)
        XCTAssertEqual(overlay.height, cg.height)
        XCTAssertEqual(overlay.colorSpace?.name, cg.colorSpace?.name, "the overlay keeps the frame's color space")

        let src = try XCTUnwrap(RGBA8Pixels(cg))
        let out = try XCTUnwrap(RGBA8Pixels(overlay))
        var red = 0, blue = 0, wrong = 0, firstWrong = ""
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let s = src.pixel(x, y), o = out.pixel(x, y)
                let i = y * cg.width + x
                let expected: (UInt8, UInt8, UInt8)
                if ref.blownPixels.contains(i) { expected = (255, 0, 0); red += 1 }
                else if ref.crushedPixels.contains(i) { expected = (0, 0, 255); blue += 1 }
                else { expected = (s.r, s.g, s.b) }
                if (o.r, o.g, o.b) != expected {
                    wrong += 1
                    if firstWrong.isEmpty { firstWrong = "(\(x),\(y)) frame \(s) overlay \(o) expected \(expected)" }
                }
            }
        }
        XCTAssertEqual(wrong, 0, "every pixel is the frame's or the warning color; first mismatch \(firstWrong)")
        XCTAssertGreaterThan(red, 0)
        XCTAssertGreaterThan(blue, 0)
        XCTAssertEqual(red, ref.blown, "the red set is the blown set")
        XCTAssertEqual(red + blue, ref.blownPixels.union(ref.crushedPixels).count)
        XCTAssertEqual(Double(ref.blown) / Double(cg.width * cg.height), hist.highlightClipping, accuracy: 1e-12,
                       "the overlay and the triangle count the same pixels")
        XCTAssertEqual(Double(ref.crushed) / Double(cg.width * cg.height), hist.shadowClipping, accuracy: 1e-12)
    }

    /// The overlay is a stage over the frame the chain rendered: a real
    /// render with +4 EV blows most of the synthetic photo, and composing the
    /// overlay over that frame flags the same pixels the frame's histogram
    /// counts; the frame itself is untouched by the overlay request.
    func testOverlayOverARenderedFrameMatchesItsHistogram() throws {
        let master = CIImage(cgImage: syntheticImage(width: 800, height: 600))
        var recipe = Recipe.neutral
        recipe.set(.exposure, to: 4)
        let frame = try XCTUnwrap(Renderer.shared.render(master, recipe: recipe, maxPixelSize: 400)).image
        let hist = try XCTUnwrap(Histogram.compute(frame))
        XCTAssertGreaterThan(hist.highlightClipping, 0.3, "+4 EV blows a large part of the ramp")
        let overlay = try XCTUnwrap(ClippingOverlay.compose(over: frame, context: Renderer.shared.context))
        let out = try XCTUnwrap(RGBA8Pixels(overlay))
        var red = 0
        for y in 0..<overlay.height {
            for x in 0..<overlay.width where out.pixel(x, y) == (255, 0, 0, 255) { red += 1 }
        }
        XCTAssertEqual(Double(red) / Double(frame.width * frame.height), hist.highlightClipping, accuracy: 1e-12)
        XCTAssertEqual(maxDiff(frame, try XCTUnwrap(Renderer.shared.render(master, recipe: recipe, maxPixelSize: 400)).image), 0,
                       "the plain frame is what it was")
    }
}
