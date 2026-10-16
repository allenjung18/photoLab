import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoLab

// MARK: - Helpers

/// RGB (0...255) of the pixel at (x, y), top-down, of an RGBA8 image.
private func rgb(_ cg: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
    guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0, 0) }
    let i = y * cg.bytesPerRow + x * 4
    return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
}

private func rowMean(_ cg: CGImage, _ y: Int) -> Double {
    var s = 0.0
    for x in 0..<cg.width { let c = rgb(cg, x, y); s += (c.r + c.g + c.b) / 3 }
    return s / Double(cg.width)
}

/// Largest per-channel difference over row `y` of two same-width images.
private func rowDiff(_ a: CGImage, _ b: CGImage, _ y: Int) -> Double {
    var worst = 0.0
    for x in 0..<a.width {
        let p = rgb(a, x, y), q = rgb(b, x, y)
        worst = max(worst, abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b))
    }
    return worst
}

/// A flat sRGB gray (`level` 0...1), with an optional pure-red dot at
/// (`dot`, fractions, top-left) of `dotRadius` pixels.
private func flatImage(width: Int, height: Int, level: CGFloat,
                       dot: CGPoint? = nil, dotRadius: CGFloat = 5) -> CIImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let dot {
        // CGContext is bottom-up: flip the top-down fraction.
        let c = CGPoint(x: dot.x * CGFloat(width), y: (1 - dot.y) * CGFloat(height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - dotRadius, y: c.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius))
    }
    return CIImage(cgImage: ctx.makeImage()!)
}

private func exposureMask(_ shape: MaskShape, ev: Double = 1, enabled: Bool = true, inverted: Bool = false) -> LocalMask {
    LocalMask(shape: shape, adjustments: [Adjustment(kind: .exposure, value: ev)], enabled: enabled, inverted: inverted)
}

private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

// MARK: - Tests

/// Linear and radial masks rendered through the one chain: where they land,
/// what they leave alone, and where in the chain they sit.
final class MaskRenderTests: XCTestCase {
    let renderer = Renderer.shared

    func cgImage(_ image: CIImage, _ rect: CGRect) throws -> CGImage {
        try XCTUnwrap(renderer.context.createCGImage(image, from: rect, format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    }

    func render(_ recipe: Recipe, _ source: CIImage, region: Renderer.Region? = nil) throws -> Renderer.Result {
        try XCTUnwrap(renderer.render(source, recipe: recipe, region: region))
    }

    // MARK: Where a mask applies

    func testALinearMaskOverTheTopHalfBrightensTheTopAndLeavesTheBottom() throws {
        let src = flatImage(width: 256, height: 192, level: 0.35)
        var r = Recipe.neutral
        let plain = try render(r, src).image
        r.masks = [exposureMask(.linear(start: p(0.5, 0), end: p(0.5, 0.5)))]
        let masked = try render(r, src).image
        let top = rowMean(masked, 0), base = rowMean(plain, 0)
        XCTAssertGreaterThan(top, base + 40, "+1 EV at the top row")
        // Half way down the ramp: a partial lift, less than the top's.
        let mid = rowMean(masked, 48)
        XCTAssertGreaterThan(mid, base + 5)
        XCTAssertLessThan(mid, top - 5)
        for y in [96, 140, 191] {
            XCTAssertLessThanOrEqual(rowDiff(masked, plain, y), 1, "row \(y) is past the gradient's end")
        }
    }

    func testARadialMaskBrightensTheCentreAndNotTheCorners() throws {
        let src = flatImage(width: 300, height: 200, level: 0.35)
        var r = Recipe.neutral
        let plain = try render(r, src).image
        r.masks = [exposureMask(.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.15), angle: 0, feather: 0.5))]
        let masked = try render(r, src).image
        let c = rgb(masked, 150, 100), c0 = rgb(plain, 150, 100)
        XCTAssertGreaterThan(c.g, c0.g + 40, "the centre is lifted")
        for (x, y) in [(0, 0), (299, 0), (0, 199), (299, 199), (150, 5), (10, 100)] {
            let a = rgb(masked, x, y), b = rgb(plain, x, y)
            XCTAssertLessThanOrEqual(max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)), 1, "(\(x), \(y)) is outside")
        }
    }

    func testAnInvertedMaskAppliesOutsideItsShape() throws {
        let src = flatImage(width: 300, height: 200, level: 0.35)
        var r = Recipe.neutral
        let plain = try render(r, src).image
        r.masks = [exposureMask(.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.15), angle: 0, feather: 0.5),
                                inverted: true)]
        let masked = try render(r, src).image
        XCTAssertLessThanOrEqual(abs(rgb(masked, 150, 100).g - rgb(plain, 150, 100).g), 1, "the centre is left alone")
        XCTAssertGreaterThan(rgb(masked, 5, 5).g, rgb(plain, 5, 5).g + 40, "the corner is lifted")
    }

    /// The drawn mask (before geometry) is `MaskMath`'s weight, pixel for
    /// pixel within a small tolerance: the maths and the drawing agree on
    /// the ramp, the long-side radii and the direction of the angle.
    func testTheDrawnMaskIsMaskMathsWeight() throws {
        let size = CGSize(width: 240, height: 160)
        let extent = CGRect(origin: .zero, size: size)
        let shapes: [MaskShape] = [
            .linear(start: p(0.2, 0.3), end: p(0.7, 0.9)),
            .radial(center: p(0.45, 0.55), radii: MaskRadii(x: 0.3, y: 0.12), angle: 30, feather: 0.6),
            .radial(center: p(0.6, 0.4), radii: MaskRadii(x: 0.15, y: 0.15), angle: 0, feather: 1),
            .brush([BrushStroke(points: [p(0.1, 0.2), p(0.5, 0.7), p(0.85, 0.3)], radius: 0.08, feather: 0.6, flow: 0.8),
                    BrushStroke(points: [p(0.5, 0.65)], radius: 0.05, feather: 0.3, flow: 0.7, erase: true)]),
        ]
        let w = Int(size.width), h = Int(size.height)
        for shape in shapes {
            let image = try XCTUnwrap(MaskRender.image(for: shape, over: extent))
            var buf = [Float](repeating: 0, count: w * h * 4)
            // No color matching: the working-space values the blend reads.
            renderer.context.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
            var worst = 0.0
            for y in Swift.stride(from: 0, to: h, by: 4) {
                for x in Swift.stride(from: 0, to: w, by: 4) {
                    // The bitmap is top-down, row 0 the top of the extent, like the point.
                    let got = Double(buf[(y * w + x) * 4 + 1])
                    let want = MaskMath.weight(of: shape, at: p((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)), in: size)
                    worst = max(worst, abs(got - want))
                }
            }
            XCTAssertLessThan(worst, 0.02, "\(shape)")
        }
        XCTAssertNil(MaskRender.image(for: .linear(start: p(0.3, 0.3), end: p(0.3, 0.3)), over: extent))
        XCTAssertNil(MaskRender.image(for: .brush([]), over: extent))
        // Off the origin too: a brush lands on the extent, not at (0, 0).
        let moved = CGRect(x: 30, y: -12, width: 240, height: 160)
        let stroke = MaskShape.brush([BrushStroke(points: [p(0.25, 0.25)], radius: 0.05, feather: 0, flow: 1)])
        let image = try XCTUnwrap(MaskRender.image(for: stroke, over: moved))
        XCTAssertEqual(image.extent, moved)
        var px = [Float](repeating: 0, count: 4)
        // Source (0.25, 0.25) is 60 px right of the left edge and 40 px down from the top.
        renderer.context.render(image, toBitmap: &px, rowBytes: 16,
                                bounds: CGRect(x: moved.minX + 60, y: moved.maxY - 41, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        XCTAssertEqual(Double(px[1]), 1, accuracy: 0.01, "the dab is at its source point")
    }

    // MARK: Pinned to the photo

    /// A mask drawn over a marked spot in the source frame stays on that
    /// spot after the recipe rotates and crops the photo: the mask goes
    /// through the same geometry stages as the pixels.
    func testAMaskOverAMarkedSpotStaysOnItAfterRotateAndCrop() throws {
        let spot = CGPoint(x: 0.25, y: 0.25)
        let src = flatImage(width: 512, height: 384, level: 0.5, dot: spot, dotRadius: 5)
        var r = Recipe.neutral
        r.set(.rotate, to: 10)
        r.set(.cropRight, to: 20)
        r.masks = [exposureMask(.radial(center: p(spot.x, spot.y), radii: MaskRadii(x: 0.04, y: 0.04), angle: 0, feather: 0.5),
                                ev: 1.5)]
        let out = try render(r, src).image
        let plainGray = rgb(try render(Recipe.neutral, src).image, 400, 300).g
        var red = (x: 0.0, y: 0.0, n: 0.0), lit = (x: 0.0, y: 0.0, n: 0.0)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = rgb(out, x, y)
                if c.r > c.g + 60 { red.x += Double(x); red.y += Double(y); red.n += 1 }
                else if c.r - c.g < 8, c.g > plainGray + 25 { lit.x += Double(x); lit.y += Double(y); lit.n += 1 }
            }
        }
        XCTAssertGreaterThan(red.n, 20, "the spot survives the crop")
        XCTAssertGreaterThan(lit.n, 100, "the mask lifts the gray around it")
        let dx = red.x / red.n - lit.x / lit.n, dy = red.y / red.n - lit.y / lit.n
        XCTAssertLessThan(hypot(dx, dy), 3, "the lifted ring is centred on the spot (off by \(dx), \(dy))")
    }

    // MARK: What renders nothing

    func testADisabledNeutralOrBrushMaskRendersBitIdenticalToNoMask() throws {
        let src = CIImage(cgImage: syntheticImage(width: 320, height: 240))
        var r = Recipe.neutral
        r.set(.exposure, to: 0.4)
        r.set(.rotate, to: 4)
        r.set(.clarity, to: 30)
        let plain = try render(r, src).image
        let shape = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.3, y: 0.3), angle: 0, feather: 0.5)
        let stroke = BrushStroke(points: [p(0.4, 0.4), p(0.6, 0.6)], radius: 0.1, feather: 0.5, flow: 1)
        let cases: [(String, LocalMask)] = [
            ("disabled", exposureMask(shape, enabled: false)),
            ("all neutral", LocalMask(shape: shape, adjustments: LocalMask.kinds.map { Adjustment(kind: $0, value: 0) })),
            ("no adjustments, inverted", LocalMask(shape: shape, inverted: true)),
            ("brush with no strokes", exposureMask(.brush([]))),
            ("brush, disabled", exposureMask(.brush([stroke]), enabled: false)),
            ("degenerate gradient", exposureMask(.linear(start: p(0.5, 0.5), end: p(0.5, 0.5)))),
        ]
        for (name, mask) in cases {
            var m = r
            m.masks = [mask]
            XCTAssertEqual(maxDiff(try render(m, src).image, plain), 0, name)
        }
    }

    // MARK: The 1:1 window

    /// The 1:1 view renders a window of the same chain, built over the whole
    /// source: across a mask's edge it equals that window of the whole frame.
    func testA1to1RegionEqualsTheSameWindowOfTheWholeFrameAcrossAMaskEdge() throws {
        let src = CIImage(cgImage: syntheticImage(width: 640, height: 480))
        var r = Recipe.neutral
        r.set(.rotate, to: -6)
        r.set(.cropTop, to: 10)
        r.set(.clarity, to: 25)
        r.masks = [exposureMask(.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.18, y: 0.18), angle: 0, feather: 0.3),
                                ev: 1.2)]
        let whole = try render(r, src)
        let frame = whole.frameSize
        // The mask's outer edge is 0.18 * 640 ≈ 115 px right of the centre.
        let edge = CGPoint(x: (frame.width / 2 + 108) / frame.width, y: 0.5)
        let window = try render(r, src, region: Renderer.Region(center: edge, size: CGSize(width: 80, height: 60)))
        let rect = try XCTUnwrap(window.region)
        var worst = 0.0, inside = 0.0, outside = 255.0
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let a = rgb(window.image, x, y), b = rgb(whole.image, Int(rect.minX) + x, Int(rect.minY) + y)
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "the window is the whole frame's pixels")
        // And the window really crosses the edge: the masked render differs
        // from the unmasked one on its left, not on its right.
        var plain = r
        plain.masks = []
        let unmasked = try render(plain, src, region: Renderer.Region(center: edge, size: CGSize(width: 80, height: 60))).image
        for y in 0..<Int(rect.height) {
            let l = rgb(window.image, 2, y).g - rgb(unmasked, 2, y).g
            let rt = rgb(window.image, Int(rect.width) - 3, y).g - rgb(unmasked, Int(rect.width) - 3, y).g
            inside = max(inside, l); outside = min(outside, abs(rt))
        }
        XCTAssertGreaterThan(inside, 10, "the window's left side is under the mask")
        XCTAssertLessThanOrEqual(outside, 1, "its right side is not")
    }

    // MARK: Where the stage sits in the chain

    /// A full-frame mask (weight 1 everywhere) is the mask's adjustments
    /// applied after the HSL group and before Detail: equal to running the
    /// chain in three parts with the mask's recipe between them, and not
    /// equal to it run before HSL or after clarity.
    func testTheMaskStageSitsAfterHSLAndBeforeDetail() throws {
        let src = CIImage(cgImage: syntheticImage(width: 320, height: 240))
        var r = Recipe.neutral
        r.set(.exposure, to: 0.2)
        r.set(.hsl(.luminance, .red), to: 60)
        r.set(.hsl(.saturation, .blue), to: -50)
        r.set(.clarity, to: 60)
        r.set(.vignette, to: -40)
        // Starts below the frame's top and ends above it: every pixel is
        // before the start, weight 1.
        let full = MaskShape.linear(start: p(0.5, -0.5), end: p(0.5, -1))
        let local = LocalMask(shape: full, adjustments: [Adjustment(kind: .exposure, value: 0.8),
                                                          Adjustment(kind: .contrast, value: 40)])
        var masked = r
        masked.masks = [local]
        let got = try cgImage(renderer.apply(masked, to: src), src.extent)

        func split(_ kinds: (AdjustmentKind) -> Bool) -> Recipe {
            Recipe(adjustments: AdjustmentKind.allCases.map { kinds($0) ? r[$0] : Adjustment(kind: $0, value: $0.neutral) })
        }
        // Written out, not read from the renderer, so the split is the claim.
        let detailStart = AdjustmentKind.allCases.firstIndex(of: .clarity)!
        let before = split { AdjustmentKind.allCases.firstIndex(of: $0)! < detailStart }
        let after = split { AdjustmentKind.allCases.firstIndex(of: $0)! >= detailStart }
        func chain(_ parts: [Recipe]) throws -> CGImage {
            var img = src
            for part in parts { img = renderer.apply(part, to: img) }
            return try cgImage(img, src.extent)
        }
        XCTAssertLessThanOrEqual(maxDiff(got, try chain([before, local.recipe, after])), 1, "between HSL and Detail")
        XCTAssertGreaterThan(maxDiff(got, try chain([local.recipe, before, after])), 4, "not at the head of the chain")
        XCTAssertGreaterThan(maxDiff(got, try chain([before, after, local.recipe])), 4, "not after Detail and Effects")
        // The kind right after the HSL group and the color grade (which
        // follows HSL, ColorGradingTests) is the stage's anchor.
        let lastGrade = AdjustmentKind.allCases.lastIndex { $0.group == .grade }!
        XCTAssertEqual(AdjustmentKind.allCases.lastIndex { $0.group == .hsl }! + 1,
                       AdjustmentKind.allCases.firstIndex { $0.group == .grade }!)
        XCTAssertEqual(AdjustmentKind.allCases[lastGrade + 1], Renderer.maskStageBefore)
        XCTAssertEqual(Renderer.maskStageBefore.section, .detail)
    }

    func testMasksApplyInListOrderEachOverThePictureSoFar() throws {
        let src = flatImage(width: 200, height: 100, level: 0.3)
        let everywhere = MaskShape.linear(start: p(0.5, -0.5), end: p(0.5, -1))
        var r = Recipe.neutral
        r.masks = [exposureMask(everywhere, ev: 0.5), exposureMask(everywhere, ev: 0.5)]
        var one = Recipe.neutral
        one.set(.exposure, to: 1)
        XCTAssertLessThanOrEqual(maxDiff(try render(r, src).image, try render(one, src).image), 1,
                                 "two +0.5 EV masks over the same pixels are +1 EV")
    }

    // MARK: Brush masks

    /// A horizontal stroke across the middle of the frame, radius 0.06 of
    /// the long side, hard core: +1 EV under it and nowhere else.
    func testABrushStrokeAcrossTheMiddleBrightensUnderItOnly() throws {
        let src = flatImage(width: 300, height: 200, level: 0.35)
        var r = Recipe.neutral
        let plain = try render(r, src).image
        let stroke = BrushStroke(points: [p(0.1, 0.5), p(0.5, 0.52), p(0.9, 0.5)], radius: 0.06, feather: 0.3, flow: 1)
        r.masks = [exposureMask(.brush([stroke]))]
        let masked = try render(r, src).image
        for x in [40, 150, 260] {
            XCTAssertGreaterThan(rgb(masked, x, 101).g, rgb(plain, x, 101).g + 40, "(\(x), 101) is under the stroke")
        }
        // 0.06 x 300 = 18 px either side of the line; rows well clear of it and
        // the ends beyond the first and last dab are untouched.
        for y in [0, 40, 70, 130, 160, 199] {
            XCTAssertLessThanOrEqual(rowDiff(masked, plain, y), 1, "row \(y) is clear of the stroke")
        }
        for x in [0, 5, 294, 299] {
            let a = rgb(masked, x, 100), b = rgb(plain, x, 100)
            XCTAssertLessThanOrEqual(abs(a.g - b.g), 1, "(\(x), 100) is past the stroke's end")
        }
        // Inverted: the stroke is left alone and the rest lifted.
        r.masks[0].inverted = true
        let inverted = try render(r, src).image
        XCTAssertLessThanOrEqual(abs(rgb(inverted, 150, 101).g - rgb(plain, 150, 101).g), 1)
        XCTAssertGreaterThan(rgb(inverted, 150, 20).g, rgb(plain, 150, 20).g + 40)
    }

    /// A dab painted over a marked spot in the source frame stays on it
    /// after the recipe rotates and crops: the raster goes through the same
    /// geometry stages as the pixels.
    func testABrushOverAMarkedSpotStaysOnItAfterRotateAndCrop() throws {
        let spot = CGPoint(x: 0.7, y: 0.3)
        let src = flatImage(width: 512, height: 384, level: 0.5, dot: spot, dotRadius: 5)
        var r = Recipe.neutral
        r.set(.rotate, to: -12)
        r.set(.cropLeft, to: 15)
        r.set(.cropBottom, to: 10)
        let dab = BrushStroke(points: [p(spot.x - 0.004, spot.y), p(spot.x + 0.004, spot.y)], radius: 0.04, feather: 0.5, flow: 1)
        r.masks = [exposureMask(.brush([dab]), ev: 1.5)]
        let out = try render(r, src).image
        let plainGray = rgb(try render(Recipe.neutral, src).image, 100, 300).g
        var red = (x: 0.0, y: 0.0, n: 0.0), lit = (x: 0.0, y: 0.0, n: 0.0)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = rgb(out, x, y)
                if c.r > c.g + 60 { red.x += Double(x); red.y += Double(y); red.n += 1 }
                else if c.r - c.g < 8, c.g > plainGray + 25 { lit.x += Double(x); lit.y += Double(y); lit.n += 1 }
            }
        }
        XCTAssertGreaterThan(red.n, 20, "the spot survives the crop")
        XCTAssertGreaterThan(lit.n, 100, "the brush lifts the gray around it")
        let dx = red.x / red.n - lit.x / lit.n, dy = red.y / red.n - lit.y / lit.n
        XCTAssertLessThan(hypot(dx, dy), 3, "the lifted ring is centred on the spot (off by \(dx), \(dy))")
    }

    /// The raster cache: a second render with the same strokes (a mask
    /// slider dragged, a global slider, a rotate) does not raster again; a
    /// changed stroke does, and renders the new mask, not the cached one.
    func testABrushIsRasteredOnceAndAgainOnlyWhenItsStrokesChange() throws {
        let cache = BrushRasterCache.shared
        let src = flatImage(width: 320, height: 200, level: 0.35)
        let plain = try render(Recipe.neutral, src).image
        // A stroke no other test paints, so the first render is a miss.
        let left = BrushStroke(points: [p(0.2, 0.3), p(0.2, 0.7)], radius: 0.05, feather: 0.4, flow: 0.9)
        var r = Recipe.neutral
        r.masks = [exposureMask(.brush([left]))]
        let before = cache.rasters
        let first = try render(r, src).image
        XCTAssertEqual(cache.rasters, before + 1, "the first render rasters")
        r.masks[0].set(.exposure, to: 1.3)
        r.masks[0].set(.contrast, to: 20)
        r.set(.exposure, to: 0.2)
        r.set(.vignette, to: -30)
        _ = try render(r, src)
        r.set(.rotate, to: 5)
        _ = try render(r, src)
        XCTAssertEqual(cache.rasters, before + 1, "mask sliders, global sliders and a rotate reuse the raster")
        XCTAssertGreaterThan(rgb(first, 64, 100).g, rgb(plain, 64, 100).g + 30, "the left stroke is lifted")

        // Move the stroke to the right: a new raster, and the picture follows it.
        var right = left
        right.points = [p(0.8, 0.3), p(0.8, 0.7)]
        var moved = Recipe.neutral
        moved.masks = [exposureMask(.brush([right]))]
        let second = try render(moved, src).image
        XCTAssertEqual(cache.rasters, before + 2, "a changed stroke rasters")
        XCTAssertGreaterThan(rgb(second, 256, 100).g, rgb(plain, 256, 100).g + 30, "the right stroke is lifted")
        XCTAssertLessThanOrEqual(abs(rgb(second, 64, 100).g - rgb(plain, 64, 100).g), 1, "the old stroke is gone")
        // A different raster size is a different entry (the 1:1 master vs the loupe).
        _ = try XCTUnwrap(renderer.render(src, recipe: moved, maxPixelSize: 160))
        XCTAssertEqual(cache.rasters, before + 3, "another size rasters")
    }

    /// Beyond 4096 px the brush is rastered at the cap and scaled up by Core
    /// Image: the lift still lands on the stroke.
    func testABrushOverASourceAboveTheCapIsScaledOntoIt() throws {
        let src = flatImage(width: 4800, height: 300, level: 0.35)
        let stroke = BrushStroke(points: [p(0.5, 0.2), p(0.5, 0.8)], radius: 0.01, feather: 0.2, flow: 1)
        var r = Recipe.neutral
        r.masks = [exposureMask(.brush([stroke]))]
        let out = try render(r, src).image
        let plain = try render(Recipe.neutral, src).image
        XCTAssertEqual(out.width, 4800)
        // 0.01 x 4800 = 48 px radius around x = 2400.
        XCTAssertGreaterThan(rgb(out, 2400, 150).g, rgb(plain, 2400, 150).g + 40, "under the stroke")
        XCTAssertGreaterThan(rgb(out, 2436, 150).g, rgb(plain, 2436, 150).g + 30, "inside the radius")
        for x in [2340, 2460, 100, 4700] {
            XCTAssertLessThanOrEqual(abs(rgb(out, x, 150).g - rgb(plain, x, 150).g), 1, "(\(x), 150) is outside")
        }
    }
}
