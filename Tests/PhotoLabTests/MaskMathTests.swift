import XCTest
@testable import PhotoLab

/// `MaskMath`: the weights the mask renderer draws, stated without Core Image.
final class MaskMathTests: XCTestCase {
    let square = CGSize(width: 1000, height: 1000)
    let wide = CGSize(width: 1200, height: 800)

    private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

    // MARK: Linear

    func testLinearIsOneAtTheStartZeroAtTheEndAndAStraightRampBetween() {
        let s = MaskShape.linear(start: p(0.5, 0.2), end: p(0.5, 0.6))
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.2), in: square), 1, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.4), in: square), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.5), in: square), 0.25, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.6), in: square), 0, accuracy: 1e-12)
        // Beyond either end it holds its end value.
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.0), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, -3), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.9), in: square), 0)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 4), in: square), 0)
    }

    func testLinearIsConstantAlongThePerpendicularOnScreen() {
        // A diagonal gradient on a 3:2 source: the perpendicular is taken in
        // pixels, so step along it in pixels and convert back to fractions.
        let s = MaskShape.linear(start: p(0.2, 0.3), end: p(0.7, 0.8))
        let w = Double(wide.width), h = Double(wide.height)
        let dx = (0.7 - 0.2) * w, dy = (0.8 - 0.3) * h         // the gradient's direction in pixels
        let mid = (x: 0.45 * w, y: 0.55 * h)
        let base = MaskMath.weight(of: s, at: p(mid.x / w, mid.y / h), in: wide)
        XCTAssertEqual(base, 0.5, accuracy: 1e-12)
        for k in [-300.0, -40, 25, 500] {
            // (-dy, dx) is perpendicular to (dx, dy).
            let q = p((mid.x - dy * k / 1000) / w, (mid.y + dx * k / 1000) / h)
            XCTAssertEqual(MaskMath.weight(of: s, at: q, in: wide), base, accuracy: 1e-12, "offset \(k)")
        }
        // Not along the fraction-space perpendicular, which is skewed on 3:2.
        let skewed = p(0.45 - 0.1, 0.55 + 0.1)
        XCTAssertNotEqual(MaskMath.weight(of: s, at: skewed, in: wide), base, accuracy: 1e-3)
    }

    func testAZeroLengthGradientWeighsNothing() {
        let s = MaskShape.linear(start: p(0.4, 0.4), end: p(0.4, 0.4))
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.4, 0.4), in: square), 0)
    }

    // MARK: Radial

    func testRadialIsOneInsideTheInnerEllipseAndZeroAtAndOutsideTheOuter() {
        // radius 0.2 of the long side, feather 0.5: inner ring at 0.1.
        let s = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.2), angle: 0, feather: 0.5)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.5), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.59, 0.5), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.65, 0.5), in: square), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.5, 0.35), in: square), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.7, 0.5), in: square), 0, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.95, 0.95), in: square), 0)
        // Between the rings it falls monotonically.
        var last = 1.0
        for x in stride(from: 0.6, through: 0.7, by: 0.01) {
            let w = MaskMath.weight(of: s, at: p(x, 0.5), in: square)
            XCTAssertLessThanOrEqual(w, last)
            last = w
        }
    }

    func testRadiiAreFractionsOfTheLongSideSoEqualRadiiAreACircleOnAnyAspect() {
        let s = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.1, y: 0.1), angle: 0, feather: 1)
        // 0.05 of 1200 px to the right, and the same 60 px down (0.075 of 800).
        let right = MaskMath.weight(of: s, at: p(0.55, 0.5), in: wide)
        let down = MaskMath.weight(of: s, at: p(0.5, 0.5 + 60.0 / 800), in: wide)
        XCTAssertEqual(right, 0.5, accuracy: 1e-12)
        XCTAssertEqual(down, right, accuracy: 1e-12)
    }

    func testAnEllipseTurned90DegreesSwapsItsRadii() {
        let flat = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.3, y: 0.1), angle: 0, feather: 0.6)
        let turned = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.3, y: 0.1), angle: 90, feather: 0.6)
        let swapped = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.1, y: 0.3), angle: 0, feather: 0.6)
        for q in [p(0.6, 0.5), p(0.5, 0.6), p(0.75, 0.52), p(0.53, 0.25), p(0.62, 0.66)] {
            XCTAssertEqual(MaskMath.weight(of: turned, at: q, in: square),
                           MaskMath.weight(of: swapped, at: q, in: square), accuracy: 1e-9, "\(q)")
        }
        // And differs from the unturned one off the axes' symmetry.
        XCTAssertGreaterThan(MaskMath.weight(of: flat, at: p(0.75, 0.5), in: square), 0)
        XCTAssertEqual(MaskMath.weight(of: turned, at: p(0.75, 0.5), in: square), 0)
    }

    func testAPositiveAngleTurnsTheEllipseClockwiseOnScreen() {
        // A long thin ellipse turned +45°: its long axis runs from top-left
        // to bottom-right on screen (y down), as rotate's positive does.
        let s = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.3, y: 0.05), angle: 45, feather: 0.2)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.62, 0.62), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: s, at: p(0.62, 0.38), in: square), 0)
    }

    func testAHardEdgeAndAZeroRadius() {
        let hard = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.2), angle: 0, feather: 0)
        XCTAssertEqual(MaskMath.weight(of: hard, at: p(0.69, 0.5), in: square), 1)
        XCTAssertEqual(MaskMath.weight(of: hard, at: p(0.71, 0.5), in: square), 0)
        let none = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0, y: 0.2), angle: 0, feather: 0.5)
        XCTAssertEqual(MaskMath.weight(of: none, at: p(0.5, 0.5), in: square), 0)
    }

    // MARK: The mask

    func testInvertedIsOneMinusTheWeightForEveryShape() {
        let shape = MaskShape.linear(start: p(0, 0), end: p(1, 0))
        let mask = LocalMask(shape: shape, adjustments: [Adjustment(kind: .exposure, value: 1)])
        var inverted = mask
        inverted.inverted = true
        for x in [-0.2, 0, 0.3, 0.5, 0.8, 1, 1.4] {
            let q = p(x, 0.5)
            XCTAssertEqual(MaskMath.weight(of: inverted, at: q, in: wide),
                           1 - MaskMath.weight(of: mask, at: q, in: wide), accuracy: 1e-12)
        }
        XCTAssertEqual(MaskMath.weight(of: mask, at: p(0.3, 0.5), in: wide), 0.7, accuracy: 1e-12)
        let stroke = BrushStroke(points: [p(0.5, 0.5)], radius: 0.1, feather: 0.5, flow: 1)
        var brush = LocalMask(shape: .brush([stroke]), adjustments: [Adjustment(kind: .exposure, value: 1)])
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.5, 0.5), in: wide), 1, "a brush's dab centre is its flow")
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.95, 0.5), in: wide), 0, "beyond its radius")
        brush.inverted = true
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.5, 0.5), in: wide), 0)
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.95, 0.5), in: wide), 1)
    }
}

// MARK: - View to source and back

/// `MaskMath.viewToSource` / `sourceToView`: a point on the loupe goes back
/// through the fit rect or the 1:1 window, the crop and the rotate stage's
/// turn and inscribed inset to the source frame, and returns to where it
/// was; and the forward mapping lands where the renderer puts the pixel.
final class MaskMathMappingTests: XCTestCase {
    let wide = CGSize(width: 1200, height: 800)

    private let crop20 = CropMath.Crop(left: 0.2, top: 0, right: 0, bottom: 0)
    private let cropMixed = CropMath.Crop(left: 0.1, top: 0.05, right: 0.1, bottom: 0.05)

    /// Fit: a 3:2 frame in an 1000 x 700 pane.
    private func fit(_ g: MaskMath.Geometry) -> MaskMath.Viewport {
        // The frame's aspect after rotate (kept) and crop.
        let k = g.crop.rect
        let frame = CGSize(width: g.source.width * k.width, height: g.source.height * k.height)
        return .fit(ZoomMath.fitRect(frame: frame, pane: CGSize(width: 1000, height: 700)))
    }

    /// 1:1: a 1600 x 1000 pixel window of a 2400 x 1600 frame at 2x.
    private let window = MaskMath.Viewport.window(region: CGRect(x: 300, y: 250, width: 1600, height: 1000),
                                                  frame: CGSize(width: 2400, height: 1600),
                                                  pane: CGSize(width: 820, height: 520), displayScale: 2)

    private let viewPoints = [CGPoint(x: 120, y: 90), CGPoint(x: 500, y: 350), CGPoint(x: 811, y: 47),
                              CGPoint(x: 333, y: 602), CGPoint(x: -40, y: 20)]

    func testViewToSourceToViewRoundTripsWithinHalfAPoint() {
        for rotate in [0.0, 7.5, -30] {
            for crop in [CropMath.Crop.none, crop20, cropMixed] {
                let g = MaskMath.Geometry(source: wide, rotate: rotate, crop: crop)
                for viewport in [fit(g), window] {
                    for v in viewPoints {
                        let s = try! XCTUnwrap(MaskMath.viewToSource(v, g, viewport))
                        let back = MaskMath.sourceToView(s, g, viewport)
                        XCTAssertLessThan(hypot(back.x - v.x, back.y - v.y), 0.5,
                                          "rotate \(rotate), crop \(crop), \(viewport), \(v) -> \(s) -> \(back)")
                    }
                }
            }
        }
    }

    func testWithNoRotateOrCropTheFitMappingIsTheFitRect() {
        let g = MaskMath.Geometry(source: wide)
        let viewport = fit(g)
        guard case .fit(let r) = viewport else { return XCTFail() }
        let s = try! XCTUnwrap(MaskMath.viewToSource(CGPoint(x: r.minX + r.width / 4, y: r.maxY), g, viewport))
        XCTAssertEqual(s.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.y, 1, accuracy: 1e-9)
    }

    func testTheCropAndTheTurnAreUndone() {
        // A 20% left crop: the frame's left edge is source x 0.2.
        let cropped = MaskMath.Geometry(source: wide, crop: crop20)
        let left = MaskMath.source(CGPoint(x: 0, y: 0.5), cropped)
        XCTAssertEqual(left.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(left.y, 0.5, accuracy: 1e-9)
        // A turn keeps the centre, and the frame's centre is the source's.
        let turned = MaskMath.Geometry(source: wide, rotate: 7.5)
        let c = MaskMath.source(CGPoint(x: 0.5, y: 0.5), turned)
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
        // Clockwise: the frame's top-middle comes from a source point to the
        // LEFT of the middle (the picture turned right under it), and inside
        // the source by the inscribed inset.
        let top = MaskMath.source(CGPoint(x: 0.5, y: 0), turned)
        XCTAssertLessThan(top.x, 0.5)
        XCTAssertGreaterThan(top.y, 0)
    }

    /// The forward mapping is the renderer's: a red dot at a source point,
    /// rendered through rotate 7.5 and a crop, lands where `MaskMath.frame`
    /// says, within 1.5 px of a 512 px frame.
    func testTheMappingLandsWhereTheRendererPutsThePixel() throws {
        // Off-centre, so a wrong turn direction or a missing inset moves
        // it; inside the frame each case keeps.
        let spot = MaskPoint(x: 0.4, y: 0.35)
        let w = 512, h = 384
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let c = CGPoint(x: spot.x * Double(w), y: (1 - spot.y) * Double(h))
        ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        let src = CIImage(cgImage: ctx.makeImage()!)
        for (rotate, crop) in [(7.5, cropMixed), (-30, crop20), (0, crop20)] {
            var r = Recipe.neutral
            r.set(.rotate, to: rotate)
            CropMath.write(crop, edges: CropMath.Edge.allCases, into: &r)
            let out = try XCTUnwrap(Renderer.shared.render(src, recipe: r)).image
            guard let data = out.dataProvider?.data, let px = CFDataGetBytePtr(data) else { return XCTFail() }
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let i = y * out.bytesPerRow + x * 4
                    if Int(px[i]) > Int(px[i + 1]) + 60 { sx += Double(x) + 0.5; sy += Double(y) + 0.5; n += 1 }
                }
            }
            XCTAssertGreaterThan(n, 10, "the dot survives rotate \(rotate)")
            let f = MaskMath.frame(spot, MaskMath.Geometry(recipe: r, source: CGSize(width: w, height: h)))
            let ex = f.x * Double(out.width), ey = f.y * Double(out.height)
            XCTAssertLessThan(hypot(sx / n - ex, sy / n - ey), 1.5,
                              "rotate \(rotate): rendered at (\(sx / n), \(sy / n)), mapped to (\(ex), \(ey))")
        }
    }
}
