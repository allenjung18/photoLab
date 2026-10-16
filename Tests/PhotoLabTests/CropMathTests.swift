import XCTest
@testable import PhotoLab

/// Crop mode's arithmetic (`CropMath`): a handle dragged some view points
/// moves its edges by the same fraction of the fit frame at any display
/// scale, every inset is clamped at the image's edge and at the slider's
/// bound so the crop keeps its minimum size, a corner moves its two edges,
/// and the rectangle and handles sit where the renderer will cut.
final class CropMathTests: XCTestCase {
    /// A 3:2 rendered frame at fit in a 1000×700 pane: 984×656 points
    /// inside the 8-point padding, whatever its pixel size.
    private let pane = CGSize(width: 1000, height: 700)

    private func fit(displayScale: CGFloat) -> CGRect {
        // The fit frame's image is the pane's longest side in PIXELS
        // (`PreviewCanvas.pixelSize`), so it doubles at scale 2; the rect it
        // is laid out in, in points, does not.
        let longest = (pane.width - 16) * displayScale
        let image = CGSize(width: longest, height: longest * 2 / 3)
        return ZoomMath.fitRect(frame: image, pane: pane)
    }

    func testAHandleDragMapsToTheSameNormalisedCropAtDisplayScaleOneAndTwo() {
        var crops: [CropMath.Crop] = []
        for scale in [1.0, 2.0] {
            let fit = fit(displayScale: scale)
            XCTAssertEqual(fit.width, 984, accuracy: 1e-9, "scale \(scale)")
            XCTAssertEqual(fit.height, 656, accuracy: 1e-9, "scale \(scale)")
            // The right edge 98.4 points in is 10% of the frame.
            let right = CropMath.drag(.right, from: .none, by: CGSize(width: -98.4, height: 40), fit: fit.size)
            XCTAssertEqual(right.right, 0.1, accuracy: 1e-9, "scale \(scale)")
            XCTAssertEqual(right.left, 0, "scale \(scale)")
            XCTAssertEqual(right.top, 0, "an edge handle ignores the other axis")
            // The top edge 65.6 points down is 10% of the frame's height.
            let top = CropMath.drag(.top, from: right, by: CGSize(width: 30, height: 65.6), fit: fit.size)
            XCTAssertEqual(top.top, 0.1, accuracy: 1e-9)
            XCTAssertEqual(top.right, 0.1, accuracy: 1e-9, "the other edges are kept")
            crops.append(top)

            // The handle then sits where the pointer let go.
            let r = CropMath.rect(top, in: fit)
            XCTAssertEqual(CropMath.Handle.right.point(in: r).x, fit.maxX - 98.4, accuracy: 1e-9)
            XCTAssertEqual(CropMath.Handle.top.point(in: r).y, fit.minY + 65.6, accuracy: 1e-9)
            XCTAssertEqual(CropMath.Handle.bottomLeft.point(in: r), CGPoint(x: fit.minX, y: fit.maxY))
        }
        XCTAssertEqual(crops[0], crops[1])
    }

    func testEveryInsetIsClampedAtTheImageEdge() {
        let fit = fit(displayScale: 2).size
        let start = CropMath.Crop(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1)
        let out = CGSize(width: 2000, height: 2000), back = CGSize(width: -2000, height: -2000)
        XCTAssertEqual(CropMath.drag(.left, from: start, by: back, fit: fit).left, 0, "left, dragged off the frame")
        XCTAssertEqual(CropMath.drag(.top, from: start, by: back, fit: fit).top, 0, "top")
        XCTAssertEqual(CropMath.drag(.right, from: start, by: out, fit: fit).right, 0, "right")
        XCTAssertEqual(CropMath.drag(.bottom, from: start, by: out, fit: fit).bottom, 0, "bottom")
        let corner = CropMath.drag(.topLeft, from: start, by: back, fit: fit)
        XCTAssertEqual(corner, CropMath.Crop(left: 0, top: 0, right: 0.1, bottom: 0.1))
    }

    func testTheMinimumSizeIsHeldWhenAnEdgeIsDraggedAcrossTheOther() {
        let fit = fit(displayScale: 1).size
        XCTAssertEqual(CropMath.maxInset, 0.4, accuracy: 1e-9, "the crop sliders' bound")
        XCTAssertEqual(CropMath.minSize, 0.2, accuracy: 1e-9)
        // The left edge dragged two frames right, past the right edge.
        let a = CropMath.drag(.left, from: CropMath.Crop(right: 0.4), by: CGSize(width: 2 * fit.width, height: 0), fit: fit)
        XCTAssertEqual(a.left, 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.rect.width, CropMath.minSize, accuracy: 1e-9)
        // With room on the far side the slider's bound still stops it.
        let b = CropMath.drag(.left, from: .none, by: CGSize(width: 2 * fit.width, height: 0), fit: fit)
        XCTAssertEqual(b.left, 0.4, accuracy: 1e-9)
        // A crop already past the bound (a hand-edited sidecar) is never inverted.
        let c = CropMath.drag(.bottom, from: CropMath.Crop(top: 0.9), by: CGSize(width: 0, height: -fit.height), fit: fit)
        XCTAssertEqual(c.bottom, 0)
        XCTAssertGreaterThan(c.rect.height, 0)
    }

    func testACornerMovesItsTwoEdgesAndNoOther() {
        let fit = CGSize(width: 900, height: 600)
        let start = CropMath.Crop(left: 0.05, top: 0.05, right: 0.05, bottom: 0.05)
        let c = CropMath.drag(.bottomRight, from: start, by: CGSize(width: -90, height: -60), fit: fit)
        XCTAssertEqual(c.right, 0.15, accuracy: 1e-9)
        XCTAssertEqual(c.bottom, 0.15, accuracy: 1e-9)
        XCTAssertEqual(c.left, 0.05)
        XCTAssertEqual(c.top, 0.05)
        let d = CropMath.drag(.topLeft, from: start, by: CGSize(width: 90, height: 60), fit: fit)
        XCTAssertEqual(d.left, 0.15, accuracy: 1e-9)
        XCTAssertEqual(d.top, 0.15, accuracy: 1e-9)
        XCTAssertEqual(d.right, 0.05)
        XCTAssertEqual(d.bottom, 0.05)
        XCTAssertEqual(CropMath.Handle.allCases.filter(\.isCorner).count, 4)
        XCTAssertEqual(Set(CropMath.Handle.allCases.flatMap(\.edges)).count, 4)
    }

    /// The recipe round trip: a crop written by a handle is the percent the
    /// renderer cuts, only the handle's edges are written (a disabled edge it
    /// does not own keeps its value), and crop mode's frame is the recipe
    /// without its crop at the same rotation.
    func testTheRecipeRoundTripAndTheUncroppedFrame() {
        var r = Recipe.neutral
        r.set(.rotate, to: 5)
        r.set(.cropTop, to: 12)
        r.setEnabled(.cropTop, false)
        r.set(.cropLeft, to: 10)
        XCTAssertEqual(CropMath.crop(of: r), CropMath.Crop(left: 0.1), "a disabled edge renders no inset")

        let moved = CropMath.drag(.bottomLeft, from: CropMath.crop(of: r), by: CGSize(width: 90, height: -60),
                                  fit: CGSize(width: 900, height: 600))
        CropMath.write(moved, edges: CropMath.Handle.bottomLeft.edges, into: &r)
        XCTAssertEqual(r.value(of: .cropLeft), 20, accuracy: 1e-9)
        XCTAssertEqual(r.value(of: .cropBottom), 10, accuracy: 1e-9)
        XCTAssertEqual(r.value(of: .cropTop), 12, "an edge the handle does not own keeps its value")
        XCTAssertFalse(r.isEnabled(.cropTop))

        let frame = CropMath.uncropped(r)
        XCTAssertEqual(CropMath.crop(of: frame), .none)
        XCTAssertEqual(frame.value(of: .rotate), 5)
        XCTAssertTrue(CropMath.isCropFrame(frame, for: r))
        XCTAssertFalse(CropMath.isCropFrame(r, for: r), "the cropped frame is not the one to draw over")
        var turned = r
        turned.set(.rotate, to: 6)
        XCTAssertFalse(CropMath.isCropFrame(frame, for: turned), "a frame at the old rotation")
    }
}
