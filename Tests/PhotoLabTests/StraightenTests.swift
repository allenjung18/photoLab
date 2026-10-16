import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The straighten tool (`StraightenMath`, `Library.straighten`): a line
/// drawn along a horizon sets rotate so the line is level, a steep one is
/// made upright, the correction adds to the rotate already there and stays
/// in the slider's range, the renderer agrees on the sign, and the line's
/// mouse-up is one undo step and one sidecar write.
@MainActor
final class StraightenTests: XCTestCase {
    /// The two ends of a line `length` points long at `degrees` (view
    /// points, y down) through `centre`.
    private func line(_ degrees: Double, length: Double = 300,
                      centre: CGPoint = CGPoint(x: 400, y: 300)) -> (CGPoint, CGPoint) {
        let t = degrees * .pi / 180, h = length / 2
        let d = CGVector(dx: cos(t) * h, dy: sin(t) * h)
        return (CGPoint(x: centre.x - d.dx, y: centre.y - d.dy), CGPoint(x: centre.x + d.dx, y: centre.y + d.dy))
    }

    func testALineAtPlus3Point2DegreesGivesRotateMinus3Point2() throws {
        let (a, b) = line(3.2)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: a, b, current: 0)), -3.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: b, a, current: 0)), -3.2, accuracy: 1e-9,
                       "drawn right to left it is the same line")
        let (c, d) = line(-2)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: c, d, current: 0)), 2, accuracy: 1e-9)
        let (e, f) = line(0)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: e, f, current: 0)), 0, accuracy: 1e-9,
                       "a level line changes nothing")
    }

    func testANearVerticalLineLevelsToVertical() throws {
        // 87° (y down): the top of the line leans left, so a clockwise 3° makes it upright.
        let (a, b) = line(87)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: a, b, current: 0)), 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: b, a, current: 0)), 3, accuracy: 1e-9,
                       "drawn bottom to top")
        let (c, d) = line(-86)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: c, d, current: 0)), -4, accuracy: 1e-9)
        let (e, f) = line(90)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: e, f, current: 0)), 0, accuracy: 1e-9)
        // 45° is the last angle read as a horizon.
        XCTAssertEqual(StraightenMath.tilt(from: line(45).0, to: line(45).1)!, 45, accuracy: 1e-9)
        XCTAssertEqual(StraightenMath.tilt(from: line(46).0, to: line(46).1)!, -44, accuracy: 1e-9)
    }

    /// The frame shown is already turned by the current rotate, so the
    /// correction adds to it; the result stays in the slider's ±45°.
    func testTheCorrectionAddsToTheCurrentRotateWithinTheRange() throws {
        let (a, b) = line(1.5)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: a, b, current: 5)), 3.5, accuracy: 1e-9)
        let (c, d) = line(-3)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: c, d, current: 44)), 45, accuracy: 1e-9)
        let (e, f) = line(3)
        XCTAssertEqual(try XCTUnwrap(StraightenMath.rotate(levelling: e, f, current: -44)), -45, accuracy: 1e-9)
        // A click is not a line.
        XCTAssertNil(StraightenMath.rotate(levelling: CGPoint(x: 10, y: 10), CGPoint(x: 14, y: 12), current: 7))
    }

    /// The sign against the renderer itself: a bright line drawn at +3.2°
    /// (falling to the right) on a dark image, rendered at the rotate the
    /// tool computes, comes out level (its left and right ends on the same
    /// row to within a pixel; uncorrected they are ~17 rows apart).
    func testTheRendererLevelsTheLineTheToolMeasured() throws {
        let w = 600, h = 400
        let degrees = 3.2, slope = tan(degrees * .pi / 180)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let onLine = abs(Double(y) - (Double(h) / 2 + slope * (Double(x) - Double(w) / 2))) < 2
                let v: UInt8 = onLine ? 255 : 0
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // Measured in the image's own points (the fit scale is uniform).
        let (a, b) = line(degrees, length: 400, centre: CGPoint(x: 300, y: 200))
        let value = try XCTUnwrap(StraightenMath.rotate(levelling: a, b, current: 0))
        var r = Recipe.neutral
        r.set(.rotate, to: value)
        let out = try XCTUnwrap(Renderer.shared.render(CIImage(cgImage: cg), recipe: r)).image

        let before = try rowOfLine(in: cg, columns: 0.15, 0.85)
        XCTAssertGreaterThan(before.right - before.left, 15, "the line falls to the right before")
        let after = try rowOfLine(in: out, columns: 0.15, 0.85)
        XCTAssertEqual(after.left, after.right, accuracy: 1, "level after")
    }

    /// The brightness-weighted mean row of the line in a band of columns
    /// around each of two fractions of the width.
    private func rowOfLine(in cg: CGImage, columns l: Double, _ r: Double) throws -> (left: Double, right: Double) {
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let p = try XCTUnwrap(CFDataGetBytePtr(data))
        func row(at f: Double) -> Double {
            let x0 = Int(Double(cg.width) * f) - 5
            var sum = 0.0, weight = 0.0
            for y in 0..<cg.height {
                for x in x0..<(x0 + 10) {
                    let v = Double(p[y * cg.bytesPerRow + x * 4])
                    sum += v * Double(y); weight += v
                }
            }
            return weight > 0 ? sum / weight : .nan
        }
        return (row(at: l), row(at: r))
    }

    // MARK: Through the library

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-straighten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makePhoto(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Arming the tool enters crop mode; the line's mouse-up sets rotate
    /// through `setRecipe` (one undo step, the sidecar written, the crop
    /// kept) and disarms it; Esc disarms it before it leaves crop mode, and
    /// leaving crop mode disarms it too.
    func testTheLineIsOneUndoStepAndEscDisarmsBeforeLeavingCrop() throws {
        try makePhoto("level.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.loupe = true
        var before = Recipe.neutral
        before.set(.rotate, to: 1)
        before.set(.cropLeft, to: 10)
        lib.setRecipe(before, for: photo)

        lib.straightening = true
        XCTAssertTrue(lib.cropMode, "arming the tool enters crop mode")
        let (a, b) = line(2.5)
        lib.straighten(from: a, to: b, for: photo)
        XCTAssertFalse(lib.straightening, "the line disarms it")
        XCTAssertTrue(lib.cropMode)
        let after = lib.recipe(for: photo)
        XCTAssertEqual(after.value(of: .rotate), -1.5, accuracy: 1e-9)
        XCTAssertEqual(after.value(of: .cropLeft), 10, "the crop is kept")
        XCTAssertEqual(try store.load(for: photo), after, "written at once")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "one undo step")

        // A click is not a line: nothing changes, the tool still disarms.
        lib.straightening = true
        lib.straighten(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 5), for: photo)
        XCTAssertEqual(lib.recipe(for: photo), before)
        XCTAssertFalse(lib.straightening)

        let ctx = CommandContext(library: lib)
        let back = AppCommand.command(.back)
        lib.straightening = true
        back.perform(ctx)
        XCTAssertFalse(lib.straightening, "Esc disarms the tool")
        XCTAssertTrue(lib.cropMode, "and stays in crop mode")
        back.perform(ctx)
        XCTAssertFalse(lib.cropMode)
        XCTAssertTrue(lib.loupe)

        lib.straightening = true
        lib.cropMode = false
        XCTAssertFalse(lib.straightening, "leaving crop mode disarms it")
    }
}
