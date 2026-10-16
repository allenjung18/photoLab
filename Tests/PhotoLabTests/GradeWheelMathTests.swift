import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The color-grading wheels: `GradeWheelMath` (a point in the wheel's square
/// to hue and saturation and back, clamped at the rim, red at 0° and the hue
/// running counter-clockwise) and a puck drag (`GradeWheelDrag`) through the
/// one recipe path, one undo step and one sidecar write.
@MainActor
final class GradeWheelMathTests: XCTestCase {
    private let side = 120.0

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: The maths

    /// 100 pucks spread over the disc (10 hues x 10 saturations, offset so
    /// none is on an axis) map to a point and back within half a degree and
    /// half a saturation unit.
    func testHueAndSaturationRoundTripThroughThePoint() {
        var n = 0
        for i in 0..<10 {
            for j in 0..<10 {
                let puck = GradeWheelMath.Puck(hue: Double(i) * 36 + 7.3, saturation: Double(j) * 10 + 4.1)
                let point = GradeWheelMath.point(for: puck, side: side)
                XCTAssertTrue((0...side).contains(Double(point.x)) && (0...side).contains(Double(point.y)),
                              "\(puck) lands inside the square: \(point)")
                let back = GradeWheelMath.puck(at: point, side: side)
                XCTAssertLessThan(hueDistance(back.hue, puck.hue), 0.5, "hue round trip of \(puck): \(back)")
                XCTAssertEqual(back.saturation, puck.saturation, accuracy: 0.5, "saturation round trip of \(puck)")
                XCTAssertTrue((0..<360).contains(back.hue), "hue in range: \(back.hue)")
                n += 1
            }
        }
        XCTAssertEqual(n, 100)
        // And the other way: a point inside the rim to a puck and back.
        let p = CGPoint(x: 83.25, y: 31.5)
        let q = GradeWheelMath.point(for: GradeWheelMath.puck(at: p, side: side), side: side)
        XCTAssertEqual(q.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
    }

    /// A point past the rim is saturation 100 at its own angle (never over
    /// the slider's range), and its puck is drawn on the rim.
    func testAPointOutsideTheRimClampsTo100() {
        let r = side / 2
        for (point, hue) in [(CGPoint(x: side + 40, y: r), 0.0),        // far right
                             (CGPoint(x: r, y: -500), 90.0),            // far above
                             (CGPoint(x: -3, y: side + 3), 225.0)] {    // past the lower-left corner
            let puck = GradeWheelMath.puck(at: point, side: side)
            XCTAssertEqual(puck.saturation, 100, "\(point) is past the rim")
            XCTAssertEqual(puck.hue, hue, accuracy: 1e-9, "\(point) keeps its angle")
            let drawn = GradeWheelMath.point(for: puck, side: side)
            XCTAssertEqual(hypot(drawn.x - r, drawn.y - r), r, accuracy: 1e-9, "the puck sits on the rim")
        }
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: side, y: r), side: side).saturation, 100, accuracy: 1e-9,
                       "the rim itself is 100")
    }

    /// The centre is saturation 0; its hue is whatever the caller keeps.
    func testTheCentreIsSaturationZero() {
        let centre = CGPoint(x: side / 2, y: side / 2)
        XCTAssertEqual(GradeWheelMath.puck(at: centre, side: side), .init(hue: 0, saturation: 0))
        XCTAssertEqual(GradeWheelMath.puck(at: centre, side: side, hueAtCentre: 210), .init(hue: 210, saturation: 0),
                       "dragging through the middle keeps the hue")
        let drawn = GradeWheelMath.point(for: .init(hue: 300, saturation: 0), side: side)
        XCTAssertEqual(drawn.x, side / 2, accuracy: 1e-9)
        XCTAssertEqual(drawn.y, side / 2, accuracy: 1e-9)
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: side / 2 + 6, y: side / 2), side: side).saturation, 10,
                       accuracy: 1e-9, "a tenth of the radius is saturation 10")
    }

    /// Red at 3 o'clock, and the hue runs COUNTER-clockwise on screen (y
    /// down): 90° at 12 o'clock, green (120°) up and to the left, blue (240°)
    /// down and to the left - the hue `ColorCubes.tintDirection` tints with.
    func testHueDirectionRedAtThreeOClockCounterClockwise() {
        let r = side / 2
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: side, y: r), side: side).hue, 0, accuracy: 1e-9, "red at 3 o'clock")
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: r, y: 0), side: side).hue, 90, accuracy: 1e-9, "90 at 12 o'clock")
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: 0, y: r), side: side).hue, 180, accuracy: 1e-9, "180 at 9 o'clock")
        XCTAssertEqual(GradeWheelMath.puck(at: CGPoint(x: r, y: side), side: side).hue, 270, accuracy: 1e-9, "270 at 6 o'clock")
        let green = GradeWheelMath.point(for: .init(hue: 120, saturation: 100), side: side)
        XCTAssertLessThan(green.x, r); XCTAssertLessThan(green.y, r)
        let blue = GradeWheelMath.point(for: .init(hue: 240, saturation: 100), side: side)
        XCTAssertLessThan(blue.x, r); XCTAssertGreaterThan(blue.y, r)
        // The disc's colour at an angle is the tint the slider gives there.
        for hue in [0.0, 120, 240] {
            let t = ColorCubes.tintDirection(hue: hue)
            let strongest = [t.r, t.g, t.b].firstIndex(of: max(t.r, t.g, t.b))
            XCTAssertEqual(strongest, Int(hue / 120), "hue \(hue) tints toward \(["red", "green", "blue"][Int(hue / 120)])")
        }
    }

    /// Setting a puck touches the range's hue and saturation only; a reset
    /// puts those two back and leaves the luminance and balance.
    func testSettingAndResettingTouchOnlyTheRangesHueAndSaturation() {
        var r = Recipe.neutral
        r.set(.gradeShadowLum, to: -20)
        r.set(.gradeBalance, to: 30)
        r.set(.gradeHighlightHue, to: 45)
        let set = GradeWheelMath.setting(.init(hue: 200, saturation: 35), for: .shadow, in: r)
        XCTAssertEqual(set.value(of: .gradeShadowHue), 200)
        XCTAssertEqual(set.value(of: .gradeShadowSat), 35)
        for kind in AdjustmentKind.allCases where kind != .gradeShadowHue && kind != .gradeShadowSat {
            XCTAssertEqual(set[kind], r[kind], "\(kind) untouched")
        }
        XCTAssertEqual(GradeWheelMath.puck(of: .shadow, in: set), .init(hue: 200, saturation: 35))
        XCTAssertEqual(GradeWheelMath.resetting(.shadow, in: set), r, "the reset takes back exactly the puck")
    }

    // MARK: The drag

    private func photoLibrary() throws -> (Library, Photo.ID, SidecarStore, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-gradewheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("wheel.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.loupe = true
        return (lib, photo, SidecarStore(folder: folder), folder)
    }

    /// A puck drag moves the range's hue and saturation live through the one
    /// recipe path; the whole drag is ONE undo step and ONE sidecar write, at
    /// mouse-up (the crop-handle drag's pattern).
    func testAPuckDragIsOneUndoStepAndOneSidecarWrite() throws {
        let (lib, photo, store, _) = try photoLibrary()
        var before = Recipe.neutral
        before.set(.gradeMidtoneLum, to: 15)
        before.set(.exposure, to: 0.5)
        lib.setRecipe(before, for: photo)
        XCTAssertEqual(try store.load(for: photo), before)

        var drag = GradeWheelDrag(range: .midtone)
        let r = side / 2
        var last = GradeWheelMath.Puck(hue: 0, saturation: 0)
        for step in 1...12 {
            let a = Double(step) * 20 * .pi / 180, d = Double(step) * 4
            let point = CGPoint(x: r + cos(a) * d, y: r - sin(a) * d)
            drag.move(to: point, side: side, photo: photo, library: lib)
            last = GradeWheelMath.puck(at: point, side: side)
            XCTAssertEqual(try store.load(for: photo), before, "no sidecar write mid-drag")
            XCTAssertEqual(GradeWheelMath.puck(of: .midtone, in: lib.recipe(for: photo)), last, "the puck moves live")
            XCTAssertTrue(drag.isOpen)
        }
        let live = lib.recipe(for: photo)
        XCTAssertEqual(live.value(of: .gradeMidtoneHue), 240, accuracy: 1e-9)
        XCTAssertEqual(live.value(of: .gradeMidtoneSat), 48 / r * 100, accuracy: 1e-9)
        XCTAssertEqual(live.value(of: .gradeMidtoneLum), 15, "the luminance is not the wheel's")
        XCTAssertEqual(live.value(of: .exposure), 0.5)
        XCTAssertEqual(live.value(of: .gradeShadowSat), 0, "the other ranges are not touched")

        drag.end(photo: photo, library: lib)
        XCTAssertFalse(drag.isOpen)
        XCTAssertEqual(try store.load(for: photo), live, "one write, at mouse-up")
        drag.end(photo: photo, library: lib)   // a second mouse-up does nothing

        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "the whole drag is one undo step")
        XCTAssertEqual(try store.load(for: photo), before)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral, "the step before it is the setRecipe")
        XCTAssertFalse(lib.canUndo)
        lib.redo(); lib.redo()
        XCTAssertEqual(lib.recipe(for: photo), live)

        // The next drag is its own step.
        drag.move(to: CGPoint(x: side, y: r), side: side, photo: photo, library: lib)
        drag.end(photo: photo, library: lib)
        XCTAssertEqual(GradeWheelMath.puck(of: .midtone, in: lib.recipe(for: photo)), .init(hue: 0, saturation: 100))
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), live)
    }

    /// The double-click resets the range's hue and saturation as ONE undo
    /// step and one write; on a range already at neutral it records nothing.
    func testADoubleClickResetsTheRangeAsOneStep() throws {
        let (lib, photo, store, _) = try photoLibrary()
        var edited = Recipe.neutral
        edited.set(.gradeHighlightHue, to: 50)
        edited.set(.gradeHighlightSat, to: 40)
        edited.set(.gradeHighlightLum, to: 10)
        edited.set(.gradeShadowSat, to: 25)
        lib.setRecipe(edited, for: photo)

        GradeWheelDrag.reset(.highlight, photo: photo, library: lib)
        var expected = edited
        expected.set(.gradeHighlightHue, to: 0)
        expected.set(.gradeHighlightSat, to: 0)
        XCTAssertEqual(lib.recipe(for: photo), expected)
        XCTAssertEqual(try store.load(for: photo), expected)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), edited, "one undo takes the reset back")
        lib.redo()

        GradeWheelDrag.reset(.highlight, photo: photo, library: lib)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), edited, "a second reset made no step")
    }
}
