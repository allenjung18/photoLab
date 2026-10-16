import XCTest
import CoreImage
@testable import PhotoLab

/// `ImageStats`: the measurement core a look-matching solver and Auto in my
/// style share. Every image is built in memory.
final class ImageStatsTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An sRGB RGBA8 image whose pixel (x, y) is `color(x, y)`.
    private func image(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let i = y * width * 4 + x * 4
                p[i] = c.0; p[i + 1] = c.1; p[i + 2] = c.2; p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    // MARK: Tone

    /// A grey ramp, one column per code: each luma percentile lands within
    /// one code of q × 255.
    func testGreyRampPercentilesWithinOneCode() throws {
        let ramp = image(width: 256, height: 8) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        let s = try XCTUnwrap(ImageStats.measure(ramp))
        XCTAssertEqual(s.lumaPercentiles.count, ImageStats.percentileLevels.count)
        for (q, v) in zip(ImageStats.percentileLevels, s.lumaPercentiles) {
            XCTAssertEqual(v * 255, q * 255, accuracy: 1, "luma percentile \(q)")
        }
        XCTAssertEqual(s.luma(at: 0.5)! * 255, 127.5, accuracy: 1)
        XCTAssertEqual(s.pixelCount, 256 * 8)
    }

    /// Luma is Rec. 709, as `Histogram.luminance`: the stats' percentiles
    /// match the histogram's on a colourful frame, and pure green sits at
    /// 0.7152 of white (Rec. 601 would put it at 0.587).
    func testLumaIsRec709AsHistogram() throws {
        let green = image(width: 16, height: 16) { _, _ in (0, 255, 0) }
        let g = try XCTUnwrap(ImageStats.measure(green))
        XCTAssertEqual(g.luma(at: 0.5)! * 255, 0.7152 * 255, accuracy: 1, "pure green's luma")

        let photo = syntheticImage(width: 300, height: 200)
        let s = try XCTUnwrap(ImageStats.measure(photo))
        let h = try XCTUnwrap(Histogram.compute(photo))
        for (q, v) in zip(ImageStats.percentileLevels, s.lumaPercentiles) {
            XCTAssertEqual(v * 255, AutoTone.percentile(h.luminance, q) * 255, accuracy: 1, "percentile \(q) against Histogram")
        }
    }

    // MARK: Colour

    /// A warm-tinted grey measures more red than blue; a neutral grey equal.
    func testWarmTintedGreyMeanRedAboveBlue() throws {
        let warm = try XCTUnwrap(ImageStats.measure(image(width: 32, height: 32) { _, _ in (150, 128, 106) }))
        XCTAssertGreaterThan(warm.mean.red, warm.mean.blue)
        XCTAssertEqual(warm.mean.red, 150.0 / 255, accuracy: 1e-9)
        let grey = try XCTUnwrap(ImageStats.measure(image(width: 32, height: 32) { _, _ in (128, 128, 128) }))
        XCTAssertEqual(grey.mean.red, grey.mean.blue, accuracy: 1e-9)
    }

    /// Two tones, a blue-ish shadow half and a yellow-ish highlight half:
    /// each range's mean is its own half's colour, and the midtone range,
    /// with no pixels, is nil.
    func testShadowAndHighlightRangeMeansOnTwoToneImage() throws {
        let two = image(width: 40, height: 20) { x, _ in x < 20 ? (20, 30, 60) : (230, 220, 180) }
        let s = try XCTUnwrap(ImageStats.measure(two))
        let shadow = try XCTUnwrap(s.mean(in: .shadow))
        let highlight = try XCTUnwrap(s.mean(in: .highlight))
        XCTAssertEqual(shadow.red, 20.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(shadow.blue, 60.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(highlight.red, 230.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(highlight.blue, 180.0 / 255, accuracy: 1e-9)
        XCTAssertNil(s.mean(in: .midtone), "no pixel is a midtone")
        XCTAssertEqual(s.mean.red, (20.0 + 230) / 2 / 255, accuracy: 1e-9)

        // A uniform mid grey is all midtone.
        let mid = try XCTUnwrap(ImageStats.measure(image(width: 8, height: 8) { _, _ in (128, 128, 128) }))
        XCTAssertNil(mid.mean(in: .shadow))
        XCTAssertNil(mid.mean(in: .highlight))
        XCTAssertEqual(try XCTUnwrap(mid.mean(in: .midtone)).green, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(ImageStats.range(ofLuma: 0.2), .shadow)
        XCTAssertEqual(ImageStats.range(ofLuma: 0.5), .midtone)
        XCTAssertEqual(ImageStats.range(ofLuma: 0.8), .highlight)
    }

    /// A desaturated copy (each pixel pulled half way to its own grey)
    /// measures lower saturation and chroma; a grey frame measures zero.
    func testDesaturatedCopyHasLowerSaturation() throws {
        let colours: [(Int, Int, Int)] = [(200, 40, 40), (40, 180, 60), (50, 60, 210), (220, 200, 30)]
        let vivid = image(width: 40, height: 40) { x, y in
            let c = colours[(x / 10 + y / 10) % 4]
            return (UInt8(c.0), UInt8(c.1), UInt8(c.2))
        }
        let muted = image(width: 40, height: 40) { x, y in
            let c = colours[(x / 10 + y / 10) % 4]
            let grey = (c.0 + c.1 + c.2) / 3
            return (UInt8((c.0 + grey) / 2), UInt8((c.1 + grey) / 2), UInt8((c.2 + grey) / 2))
        }
        let a = try XCTUnwrap(ImageStats.measure(vivid))
        let b = try XCTUnwrap(ImageStats.measure(muted))
        XCTAssertLessThan(b.saturation, a.saturation)
        XCTAssertLessThan(b.chroma, a.chroma)
        let grey = try XCTUnwrap(ImageStats.measure(image(width: 8, height: 8) { _, _ in (90, 90, 90) }))
        XCTAssertEqual(grey.saturation, 0)
        XCTAssertEqual(grey.chroma, 0)
        let black = try XCTUnwrap(ImageStats.measure(image(width: 8, height: 8) { _, _ in (0, 0, 0) }))
        XCTAssertEqual(black.saturation, 0, "black has no saturation, not NaN")
    }

    // MARK: Distance

    func testDistanceZeroToItselfAndSymmetric() throws {
        let a = try XCTUnwrap(ImageStats.measure(syntheticImage(width: 200, height: 120)))
        let b = try XCTUnwrap(ImageStats.measure(image(width: 40, height: 20) { x, _ in x < 20 ? (20, 30, 60) : (230, 220, 180) }))
        XCTAssertEqual(a.distance(to: a), 0)
        XCTAssertEqual(b.distance(to: b), 0)
        XCTAssertGreaterThan(a.distance(to: b), 0)
        XCTAssertEqual(a.distance(to: b), b.distance(to: a), accuracy: 1e-12)
        // Each weight scales its own term only.
        let toneOnly = ImageStats.Weights(tone: 1, colour: 0, saturation: 0)
        let colourOnly = ImageStats.Weights(tone: 0, colour: 1, saturation: 0)
        let satOnly = ImageStats.Weights(tone: 0, colour: 0, saturation: 1)
        let w = ImageStats.Weights(tone: 2, colour: 3, saturation: 5)
        let parts = 2 * a.distance(to: b, weights: toneOnly) + 3 * a.distance(to: b, weights: colourOnly)
            + 5 * a.distance(to: b, weights: satOnly)
        XCTAssertEqual(a.distance(to: b, weights: w), parts, accuracy: 1e-12)
        XCTAssertEqual(a.distance(to: b, weights: toneOnly), b.distance(to: a, weights: toneOnly), accuracy: 1e-12)
    }

    /// Codable round trip keeps every value, the nil ranges included.
    func testCodableRoundTrip() throws {
        let s = try XCTUnwrap(ImageStats.measure(image(width: 40, height: 20) { x, _ in x < 20 ? (20, 30, 60) : (230, 220, 180) }))
        let back = try JSONDecoder().decode(ImageStats.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: Through the render path

    /// `of(master:recipe:)` renders at `AutoTone.analysisPixelSize` and
    /// measures: a neutral recipe gives the stats of the frame itself, and a
    /// warmer white balance raises red over blue.
    func testOfMasterRendersAtAnalysisSize() throws {
        let cg = syntheticImage(width: 1200, height: 800)
        let master = CIImage(cgImage: cg)
        let neutral = try XCTUnwrap(ImageStats.of(master: master, recipe: .neutral))
        XCTAssertEqual(neutral.pixelCount, 512 * 341, accuracy: 512 + 341, "long side \(AutoTone.analysisPixelSize)")
        let frame = try XCTUnwrap(Renderer.shared.render(master, recipe: .neutral, maxPixelSize: AutoTone.analysisPixelSize))
        XCTAssertEqual(neutral, ImageStats.measure(frame.image))

        var warm = Recipe.neutral
        warm[.temperature] = Adjustment(kind: .temperature, value: 60)
        let w = try XCTUnwrap(ImageStats.of(master: master, recipe: warm))
        XCTAssertGreaterThan(w.mean.red - w.mean.blue, neutral.mean.red - neutral.mean.blue)
        XCTAssertGreaterThan(neutral.distance(to: w), 0)
    }

    // MARK: Timing

    /// A 512 px frame (the analysis size) measures in under 20 ms: the
    /// median of five after one warm-up, best of up to three rounds
    /// (`assertFrameBudget`).
    func testMeasuresAnalysisFrameUnderTwentyMilliseconds() throws {
        let cg = syntheticImage(width: 512, height: 341)
        var load = loadAverage()
        _ = try XCTUnwrap(ImageStats.measure(cg))
        var median = Double.infinity
        var attempts = 0
        repeat {
            attempts += 1
            var round: [Double] = []
            for _ in 0..<5 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = ImageStats.measure(cg)
                round.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            round.sort()
            median = min(median, round[round.count / 2])
            load = max(load, loadAverage())
        } while median >= frameBudgetBound(20, load: load) && attempts < 3
        print(String(format: "BENCH-IMAGESTATS 512×341: median %.2f ms, best of %d, load %.2f", median, attempts, load))
        try assertFrameBudget(median, bound: 20, load: load, "ImageStats of a 512 px frame")
    }
}
