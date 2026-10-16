import XCTest
@testable import PhotoLab

/// The loupe's zoom arithmetic (`ZoomMath`): a click on the fit frame lands
/// at the centre of the 1:1 window at any display scale, the clamp keeps the
/// window inside the frame at all four edges, a photo that fits the view
/// whole stays at fit, and a drag moves the window by the pixels it covers.
final class ZoomMathTests: XCTestCase {
    /// A 6000×4000 rendered frame shown at fit in a 1000×700 pane; the fit
    /// frame's pixel size only gives the shape.
    private let frame = CGSize(width: 6000, height: 4000)
    private let fitFrame = CGSize(width: 1476, height: 984)
    private let pane = CGSize(width: 1000, height: 700)

    func testTheFitRectIsTheFrameScaledIntoThePaddedPane() {
        // 984×684 inside the padding; the 3:2 frame is width-bound.
        let r = ZoomMath.fitRect(frame: fitFrame, pane: pane)
        XCTAssertEqual(r.minX, 8, accuracy: 1e-9)
        XCTAssertEqual(r.width, 984, accuracy: 1e-9)
        XCTAssertEqual(r.height, 656, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 350, accuracy: 1e-9)
    }

    func testAClickMapsToTheCentreOfTheWindowAtDisplayScaleOneAndTwo() throws {
        let fit = ZoomMath.fitRect(frame: fitFrame, pane: pane)
        let point = CGPoint(x: fit.minX + 0.3 * fit.width, y: fit.minY + 0.4 * fit.height)
        let center = try XCTUnwrap(ZoomMath.center(forClick: point, frame: fitFrame, pane: pane))
        XCTAssertEqual(center.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.4, accuracy: 1e-9)

        var windows: [CGSize] = []
        for scale in [1.0, 2.0] {
            let window = ZoomMath.window(pane: pane, displayScale: scale)
            windows.append(window)
            let clamped = ZoomMath.clamp(center, window: window, frame: frame)
            let rect = Renderer.Region(center: clamped, size: window).rect(in: frame)
            XCTAssertEqual(rect.size, window, "scale \(scale): one image pixel per view pixel")
            XCTAssertEqual(rect.midX, 0.3 * frame.width, accuracy: 1, "scale \(scale): the clicked pixel is the window's centre")
            XCTAssertEqual(rect.midY, 0.4 * frame.height, accuracy: 1, "scale \(scale)")
        }
        XCTAssertEqual(windows, [CGSize(width: 1000, height: 700), CGSize(width: 2000, height: 1400)])

        XCTAssertNil(ZoomMath.center(forClick: CGPoint(x: 500, y: 10), frame: fitFrame, pane: pane),
                     "a click on the black above the photo")
        let corner = try XCTUnwrap(ZoomMath.center(forClick: CGPoint(x: fit.minX, y: fit.minY), frame: fitFrame, pane: pane))
        XCTAssertEqual(corner, .zero)
    }

    func testTheClampHoldsTheWindowInsideTheFrameAtAllFourEdges() {
        let window = CGSize(width: 1000, height: 700)
        let halfW = 500 / frame.width, halfH = 350 / frame.height
        let cases: [(CGPoint, CGPoint, String)] = [
            (CGPoint(x: 0, y: 0.5), CGPoint(x: halfW, y: 0.5), "left"),
            (CGPoint(x: 1, y: 0.5), CGPoint(x: 1 - halfW, y: 0.5), "right"),
            (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: halfH), "top"),
            (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 1 - halfH), "bottom"),
        ]
        for (raw, held, edge) in cases {
            let c = ZoomMath.clamp(raw, window: window, frame: frame)
            XCTAssertEqual(c.x, held.x, accuracy: 1e-9, edge)
            XCTAssertEqual(c.y, held.y, accuracy: 1e-9, edge)
            let rect = Renderer.Region(center: c, size: window).rect(in: frame)
            XCTAssertTrue(CGRect(origin: .zero, size: frame).contains(rect), "\(edge): \(rect)")
            XCTAssertEqual(rect, Renderer.Region(center: raw, size: window).rect(in: frame),
                           "\(edge): the held centre shows what the renderer's slide shows")
        }
        // A centre inside the band is left alone.
        XCTAssertEqual(ZoomMath.clamp(CGPoint(x: 0.4, y: 0.6), window: window, frame: frame), CGPoint(x: 0.4, y: 0.6))
        // On an axis the window covers whole, the middle.
        XCTAssertEqual(ZoomMath.clamp(CGPoint(x: 0.4, y: 0.9), window: CGSize(width: 1000, height: 900),
                                      frame: CGSize(width: 3000, height: 800)),
                       CGPoint(x: 0.4, y: 0.5))
    }

    func testAPhotoSmallerThanTheViewStaysAtFit() {
        let window = CGSize(width: 1200, height: 800)
        XCTAssertTrue(ZoomMath.fits(frame: CGSize(width: 640, height: 480), in: window))
        XCTAssertTrue(ZoomMath.fits(frame: window, in: window), "exactly the view's size: 1:1 is fit")
        XCTAssertFalse(ZoomMath.fits(frame: CGSize(width: 2000, height: 400), in: window), "wider than the view")
        XCTAssertFalse(ZoomMath.fits(frame: CGSize(width: 600, height: 900), in: window), "taller than the view")
    }

    func testAPanMovesTheWindowByThePixelsTheDragCovers() {
        let window = CGSize(width: 2000, height: 1400)
        // 10 points right and 5 up at display scale 2: 20 and 10 frame
        // pixels; the picture follows the pointer, so the centre moves the
        // other way.
        let moved = ZoomMath.pan(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 10, height: -5),
                                 displayScale: 2, window: window, frame: frame)
        XCTAssertEqual(moved.x, 0.5 - 20 / 6000, accuracy: 1e-12)
        XCTAssertEqual(moved.y, 0.5 + 10 / 4000, accuracy: 1e-12)
        let before = Renderer.Region(center: CGPoint(x: 0.5, y: 0.5), size: window).rect(in: frame)
        let after = Renderer.Region(center: moved, size: window).rect(in: frame)
        XCTAssertEqual(after.minX - before.minX, -20)
        XCTAssertEqual(after.minY - before.minY, 10)
        // At display scale 1 the same drag moves half as far.
        let one = ZoomMath.pan(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 10, height: -5),
                               displayScale: 1, window: window, frame: frame)
        XCTAssertEqual(one.x, 0.5 - 10 / 6000, accuracy: 1e-12)
        // A drag past the edge stops at the edge.
        let far = ZoomMath.pan(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 5000, height: -5000),
                               displayScale: 2, window: window, frame: frame)
        XCTAssertEqual(far.x, 1000 / 6000, accuracy: 1e-12)
        XCTAssertEqual(far.y, 1 - 700 / 4000, accuracy: 1e-12)
    }
}
