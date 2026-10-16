import XCTest
import CoreGraphics
@testable import PhotoLab

private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

/// The weight (0...1) of raster pixel (x, y) (top-down) of a `width`-wide raster.
private func at(_ raster: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> Double {
    Double(raster[y * width + x]) / 255
}

/// The pure brush raster: dabs, flow, feather, accumulation and erase, and
/// the raster agreeing with the one-point rule `MaskMath` reports.
final class BrushRasterTests: XCTestCase {
    let w = 200, h = 100

    /// One dab (a single-point stroke) at the centre of a 200 x 100 raster:
    /// radius 0.1 of the long side is 20 px.
    func dab(flow: Double = 0.6, feather: Double = 0.5, erase: Bool = false, at q: MaskPoint = p(0.5, 0.5)) -> BrushStroke {
        BrushStroke(points: [q], radius: 0.1, feather: feather, flow: flow, erase: erase)
    }

    func testADabsCentreEqualsItsFlow() {
        for flow in [0.25, 0.6, 1.0] {
            let r = BrushRaster.render(strokes: [dab(flow: flow)], width: w, height: h)
            XCTAssertEqual(at(r, w, 100, 50), flow, accuracy: 0.5 / 255 + 1e-9, "flow \(flow)")
            XCTAssertEqual(BrushRaster.weight(of: [dab(flow: flow)], at: p(0.5, 0.5), in: CGSize(width: w, height: h)),
                           flow, accuracy: 1e-12)
        }
    }

    func testBeyondTheRadiusIsZero() {
        let r = BrushRaster.render(strokes: [dab(flow: 1, feather: 0.3)], width: w, height: h)
        // 20 px radius around (100, 50): every pixel whose centre is 20 px or more away is 0.
        for y in 0..<h {
            for x in 0..<w {
                let d = hypot(Double(x) + 0.5 - 100, Double(y) + 0.5 - 50)
                if d >= 20 { XCTAssertEqual(r[y * w + x], 0, "(\(x), \(y)) at \(d) px") }
            }
        }
        XCTAssertGreaterThan(at(r, w, 100, 50), 0.99)
    }

    /// Walking out from the centre the weight never rises: flat inside
    /// radius x (1 - feather), a strictly falling ramp across the feather,
    /// 0 at the radius.
    func testTheFeatherRampIsMonotonic() {
        let size = CGSize(width: w, height: h)
        for feather in [0.0, 0.3, 1.0] {
            let stroke = [dab(flow: 1, feather: feather)]
            var last = 2.0
            var inRamp: [Double] = []
            for i in 0...200 {
                let dx = Double(i) / 200 * 0.12  // 0 ... 1.2 radii, in long-side units
                let v = BrushRaster.weight(of: stroke, at: p(0.5 + dx, 0.5), in: size)
                XCTAssertLessThanOrEqual(v, last + 1e-12, "feather \(feather), step \(i)")
                last = v
                let d = dx / 0.1
                if d > 1 - feather + 1e-6, d < 1 - 1e-6 { inRamp.append(v) }
                if d <= 1 - feather { XCTAssertEqual(v, 1, accuracy: 1e-12) }
                if d >= 1 { XCTAssertEqual(v, 0) }
            }
            if feather > 0 {
                XCTAssertFalse(inRamp.isEmpty)
                XCTAssertTrue(zip(inRamp, inRamp.dropFirst()).allSatisfy { $0 > $1 }, "feather \(feather) falls strictly")
            }
        }
        // Smooth: the ramp leaves 1 and arrives at 0 flat (smoothstep), so the
        // first and last tenths of the ramp move less than the middle tenth.
        let f = { (d: Double) in BrushRaster.dabWeight(distance: d, feather: 1, flow: 1) }
        XCTAssertLessThan(f(0) - f(0.1), f(0.45) - f(0.55))
        XCTAssertLessThan(f(0.9) - f(1), f(0.45) - f(0.55))
    }

    func testTwoOverlappingDabsAccumulateAndClipAtOne() {
        let size = CGSize(width: w, height: h)
        let r = BrushRaster.render(strokes: [dab(flow: 0.4), dab(flow: 0.4)], width: w, height: h)
        XCTAssertEqual(at(r, w, 100, 50), 0.8, accuracy: 1 / 255)
        XCTAssertEqual(BrushRaster.weight(of: [dab(flow: 0.4), dab(flow: 0.4)], at: p(0.5, 0.5), in: size), 0.8, accuracy: 1e-12)
        let three = [dab(flow: 0.7), dab(flow: 0.7), dab(flow: 0.7)]
        XCTAssertEqual(BrushRaster.render(strokes: three, width: w, height: h)[50 * w + 100], 255, "clipped at 1")
        XCTAssertEqual(BrushRaster.weight(of: three, at: p(0.5, 0.5), in: size), 1)
        // Within one stroke the dabs merge by their maximum: a long stroke of
        // flow 0.4 lays down 0.4 along its middle, not the sum of its dabs.
        let line = BrushStroke(points: [p(0.2, 0.5), p(0.8, 0.5)], radius: 0.1, feather: 0.5, flow: 0.4)
        XCTAssertEqual(at(BrushRaster.render(strokes: [line], width: w, height: h), w, 100, 50), 0.4, accuracy: 1 / 255)
    }

    func testEraseZeroesWhatItCovers() {
        let paint = BrushStroke(points: [p(0.2, 0.5), p(0.8, 0.5)], radius: 0.15, feather: 0.3, flow: 1)
        let erase = BrushStroke(points: [p(0.5, 0.5)], radius: 0.08, feather: 0, flow: 1, erase: true)
        let r = BrushRaster.render(strokes: [paint, erase], width: w, height: h)
        // Erase radius 16 px around (100, 50): zero inside, paint untouched outside.
        for y in 36...64 {
            for x in 86...114 where hypot(Double(x) + 0.5 - 100, Double(y) + 0.5 - 50) < 15.5 {
                XCTAssertEqual(r[y * w + x], 0, "(\(x), \(y)) is erased")
            }
        }
        XCTAssertEqual(at(r, w, 60, 50), 1, accuracy: 1 / 255, "outside the erase the paint stays")
        // A half-flow erase halves what it covers; an erase before any paint does nothing.
        var half = erase
        half.flow = 0.5
        XCTAssertEqual(at(BrushRaster.render(strokes: [paint, half], width: w, height: h), w, 100, 50), 0.5, accuracy: 1 / 255)
        XCTAssertEqual(at(BrushRaster.render(strokes: [erase, paint], width: w, height: h), w, 100, 50), 1, accuracy: 1 / 255,
                       "a later paint lays down over an earlier erase")
    }

    func testBothEndsOfAStrokeAreCovered() {
        // A 0.53-long stroke: not a whole number of dab spacings, so the end
        // dab is the one the walk adds for the last point.
        let stroke = BrushStroke(points: [p(0.13, 0.3), p(0.4, 0.5), p(0.66, 0.7)], radius: 0.05, feather: 0, flow: 1)
        let r = BrushRaster.render(strokes: [stroke], width: w, height: h)
        for q in stroke.points {
            XCTAssertEqual(at(r, w, Int(q.x * Double(w)), Int(q.y * Double(h))), 1, "the point (\(q.x), \(q.y)) is painted")
        }
        let (centres, radius) = BrushRaster.dabs(of: stroke, width: Double(w), height: Double(h))
        XCTAssertEqual(radius, 10)
        XCTAssertEqual(centres.first!.x, 26, accuracy: 1e-9)
        XCTAssertEqual(centres.last!.x, 132, accuracy: 1e-9)
        XCTAssertEqual(centres.last!.y, 70, accuracy: 1e-9)
        // Dabs a quarter radius apart along the path (2.5 px), none further.
        for (a, b) in zip(centres, centres.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(b.x - a.x, b.y - a.y), 2.5 + 1e-9)
        }
    }

    /// The raster is the one-point rule at each pixel centre, rounded to 8 bits.
    func testTheRasterIsTheWeightAtEachPixelCentre() {
        let strokes = [
            BrushStroke(points: [p(0.1, 0.2), p(0.5, 0.8), p(0.9, 0.3)], radius: 0.07, feather: 0.6, flow: 0.7),
            BrushStroke(points: [p(0.3, 0.3), p(0.35, 0.35)], radius: 0.05, feather: 1, flow: 0.5),
            BrushStroke(points: [p(0.5, 0.75)], radius: 0.04, feather: 0.4, flow: 0.8, erase: true),
        ]
        let r = BrushRaster.render(strokes: strokes, width: w, height: h)
        var worst = 0.0
        for y in Swift.stride(from: 0, to: h, by: 3) {
            for x in Swift.stride(from: 0, to: w, by: 3) {
                let want = MaskMath.weight(of: .brush(strokes), at: p((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)),
                                           in: CGSize(width: w, height: h))
                worst = max(worst, abs(at(r, w, x, y) - want))
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.5 / 255 + 1e-6)
    }

    func testTheRasterSizeIsTheSourceCappedAt4096() {
        XCTAssertTrue(BrushRaster.rasterSize(for: CGSize(width: 2600, height: 1733)) == (2600, 1733))
        XCTAssertTrue(BrushRaster.rasterSize(for: CGSize(width: 6000, height: 4000)) == (4096, 2731))
        XCTAssertTrue(BrushRaster.rasterSize(for: CGSize(width: 3000, height: 8192)) == (1500, 4096))
        XCTAssertEqual(BrushRaster.maxLongSide, 4096)
    }

    func testNoPointsOrNoRadiusPaintsNothing() {
        let none = BrushRaster.render(strokes: [BrushStroke(points: [], radius: 0.1, feather: 0.5, flow: 1),
                                                BrushStroke(points: [p(0.5, 0.5)], radius: 0, feather: 0.5, flow: 1)],
                                      width: w, height: h)
        XCTAssertEqual(none.count, w * h)
        XCTAssertTrue(none.allSatisfy { $0 == 0 })
    }
}
