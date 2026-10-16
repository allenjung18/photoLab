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

    func testInvertedIsOneMinusTheWeightAndABrushWeighsNothingYet() {
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
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.5, 0.5), in: wide), 0)
        brush.inverted = true
        XCTAssertEqual(MaskMath.weight(of: brush, at: p(0.5, 0.5), in: wide), 0)
    }
}
