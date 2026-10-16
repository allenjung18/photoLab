import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Refining an automatic mask with the brush (BrushTool.swift, BrushRaster.swift,
/// MaskRender.swift): K arms the brush on a selected automatic mask, a drag
/// paints into `AutoMask.strokes` (erase takes the detection away, paint
/// adds to it), one stroke is one undo step and one sidecar write, a live
/// raster seeded with the bitmap is byte-identical to a fresh render, and the
/// raster cache keys the bitmap's digest so two detections never share a raster.
@MainActor
final class AutoMaskRefineTests: XCTestCase {
    private var folder: URL!
    private let wide = CGSize(width: 1200, height: 800)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-automaskrefine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

    /// A synthetic bitmap: `f(x, y)` per pixel, rows top-down.
    private func bitmap(_ width: Int, _ height: Int, _ f: (Int, Int) -> UInt8) -> MaskBitmap {
        var g = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { g[y * width + x] = f(x, y) } }
        return MaskBitmap(gray: g, width: width, height: height)
    }

    /// The left half white, the right half black.
    private var leftHalf: MaskBitmap { bitmap(64, 48) { x, _ in x < 32 ? 255 : 0 } }

    /// One flat photo open in the loupe.
    private func openOne() throws -> (Library, Photo.ID) {
        let url = folder.appendingPathComponent("a.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        lib.loupe = true
        return (lib, id)
    }

    /// An automatic mask over `leftHalf` added to the photo (one step) and selected.
    private func addAuto(_ lib: Library, _ id: Photo.ID) -> UUID {
        let mask = LocalMask(shape: .auto(AutoMask(kind: .subject, bitmap: leftHalf)),
                             adjustments: [Adjustment(kind: .exposure, value: 1)])
        var r = lib.recipe(for: id)
        r.masks.append(mask)
        lib.setRecipe(r, for: id)
        lib.selectedMask = mask.id
        return mask.id
    }

    private func auto(_ lib: Library, _ id: Photo.ID, _ mask: UUID) -> AutoMask? {
        guard case .auto(let a) = lib.mask(mask, for: id)?.shape else { return nil }
        return a
    }

    /// A vertical stroke at `x` from top to bottom, painted point by point and released.
    private func stroke(_ lib: Library, _ id: Photo.ID, x: Double, erase: Bool) {
        let points = (0...40).map { p(x, Double($0) / 40) }
        for q in points { lib.paintBrush(from: points[0], to: q, erase: erase, size: wide, for: id) }
        lib.endBrushStroke(id)
    }

    /// The drawn mask's weight (green channel) at source fraction (x, y) over `w` x `h`.
    private func drawn(_ shape: MaskShape, _ w: Int, _ h: Int, cache: BrushRasterCache,
                       at points: [(Double, Double)]) throws -> [Double] {
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let image = try XCTUnwrap(MaskRender.image(for: shape, over: extent, brushes: cache))
        var buf = [Float](repeating: 0, count: w * h * 4)
        Renderer.shared.context.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        return points.map { x, y in
            let px = min(w - 1, Int(x * Double(w))), py = min(h - 1, Int(y * Double(h)))
            return Double(buf[(py * w + px) * 4 + 1])
        }
    }

    func testEraseAcrossTheWhiteHalfAndPaintOnTheBlackHalf() throws {
        let (lib, id) = try openOne()
        let mask = addAuto(lib, id)
        XCTAssertTrue(lib.selectedMaskIsPaintable)
        XCTAssertFalse(lib.maskBrushArmed, "selecting an automatic mask does not arm the brush")
        XCTAssertNil(lib.paintingBrush)
        let k = AppCommand.command(.brushMask)
        k.perform(CommandContext(library: lib))
        XCTAssertTrue(lib.maskBrushArmed, "K arms the brush on the selected automatic mask")
        XCTAssertEqual(lib.paintingBrush, mask)
        XCTAssertEqual(lib.recipe(for: id).masks.count, 1, "K did not add a brush mask")
        lib.brush = BrushSettings(size: 0.08, feather: 0, flow: 1)

        let s = wide
        func weight(_ x: Double, _ y: Double) -> Double {
            MaskMath.weight(of: lib.mask(mask, for: id)!.shape, at: p(x, y), in: s)
        }
        XCTAssertEqual(weight(0.25, 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(weight(0.75, 0.5), 0, accuracy: 1e-9)

        stroke(lib, id, x: 0.25, erase: true)
        stroke(lib, id, x: 0.75, erase: false)
        let refined = try XCTUnwrap(auto(lib, id, mask))
        XCTAssertEqual(refined.bitmap, leftHalf, "the detection is kept; strokes go over it")
        XCTAssertEqual(refined.strokes.map(\.erase), [true, false])
        for y in stride(from: 0.05, through: 0.95, by: 0.15) {
            XCTAssertEqual(weight(0.25, y), 0, accuracy: 1e-9, "erased on the white half at y \(y)")
            XCTAssertEqual(weight(0.75, y), 1, accuracy: 1e-9, "painted on the black half at y \(y)")
        }
        XCTAssertEqual(weight(0.1, 0.5), 1, accuracy: 1e-9, "white beyond the erase stroke")
        XCTAssertEqual(weight(0.9, 0.5), 0, accuracy: 1e-9, "black beyond the paint stroke")
        // Drawn as MaskMath says, through the raster cache.
        let cache = BrushRasterCache()
        let got = try drawn(lib.mask(mask, for: id)!.shape, 300, 200, cache: cache,
                            at: [(0.25, 0.5), (0.75, 0.5), (0.1, 0.5), (0.9, 0.5)])
        XCTAssertEqual(got[0], 0, accuracy: 0.01)
        XCTAssertEqual(got[1], 1, accuracy: 0.01)
        XCTAssertEqual(got[2], 1, accuracy: 0.01)
        XCTAssertEqual(got[3], 0, accuracy: 0.01)
        XCTAssertEqual(cache.rasters, 1, "a refined automatic mask rasters through the cache")
        _ = try drawn(lib.mask(mask, for: id)!.shape, 300, 200, cache: cache, at: [])
        XCTAssertEqual(cache.rasters, 1, "and a second render reuses it")
    }

    func testOneStrokeIsOneUndoStepAndOneSidecarWrite() throws {
        let (lib, id) = try openOne()
        let mask = addAuto(lib, id)
        lib.maskBrushArmed = true
        let writes = lib.sidecarWrites
        let points = (0...60).map { p(0.2 + 0.01 * Double($0), 0.5) }
        for q in points { lib.paintBrush(from: points[0], to: q, erase: true, size: wide, for: id) }
        XCTAssertGreaterThan(auto(lib, id, mask)?.strokes.first?.points.count ?? 0, 10, "the stroke grows live")
        XCTAssertEqual(lib.sidecarWrites, writes, "nothing written mid-stroke")
        lib.endBrushStroke(id)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        XCTAssertEqual(auto(lib, id, mask)?.strokes.count, 1)
        lib.undo()
        XCTAssertEqual(auto(lib, id, mask)?.strokes, [], "one undo takes the whole stroke away")
        XCTAssertEqual(auto(lib, id, mask)?.bitmap, leftHalf, "and only the stroke: the detection stays")
        lib.redo()
        XCTAssertEqual(auto(lib, id, mask)?.strokes.count, 1, "one redo puts it back")
    }

    /// A live raster seeded with a base, grown point by point, is the bytes
    /// of a fresh `BrushRaster.render(strokes:base:)` at every step; no
    /// strokes is the base itself.
    func testALiveRasterOverABaseIsByteIdenticalToAFreshRender() {
        let w = 160, h = 100
        let base = bitmap(53, 37) { x, y in UInt8((x * 9 + y * 5) % 256) }.resampled(width: w, height: h)
        let paint = BrushStroke(points: (0..<30).map { i in p(0.1 + 0.025 * Double(i), 0.3 + 0.1 * sin(Double(i) / 4)) },
                                radius: 0.06, feather: 0.4, flow: 0.7)
        let erase = BrushStroke(points: (0..<25).map { i in p(0.85 - 0.025 * Double(i), 0.2 + 0.02 * Double(i)) },
                                radius: 0.05, feather: 0.8, flow: 1, erase: true)
        let live = LiveRaster(width: w, height: h, base: base)
        XCTAssertEqual(live.out, base)
        XCTAssertEqual(BrushRaster.render(strokes: [], base: base, width: w, height: h), base)
        var done: [BrushStroke] = []
        for stroke in [paint, erase] {
            for n in 1...stroke.points.count {
                var s = stroke
                s.points = Array(stroke.points.prefix(n))
                live.update(done + [s])
                XCTAssertEqual(live.out, BrushRaster.render(strokes: done + [s], base: base, width: w, height: h),
                               "after \(done.count) strokes and \(n) points")
            }
            done.append(stroke)
        }
        XCTAssertNotEqual(live.out, base, "the strokes changed it")
        live.update([paint])
        XCTAssertEqual(live.lastPath, .rebuilt)
        XCTAssertEqual(live.out, BrushRaster.render(strokes: [paint], base: base, width: w, height: h),
                       "an undo rebuilds from the base, not from 0")
        live.update([])
        XCTAssertEqual(live.out, base)
        // And the composition rule: a pixel the strokes never touch keeps the base.
        let far = BrushRaster.render(strokes: [BrushStroke(points: [p(0.05, 0.05)], radius: 0.01, feather: 0, flow: 1)],
                                     base: base, width: w, height: h)
        XCTAssertEqual(far[(h - 1) * w + (w - 1)], base[(h - 1) * w + (w - 1)])
    }

    /// The raster cache keys the bitmap: two automatic masks with the same
    /// strokes over different bitmaps each get their own raster.
    func testTwoAutomaticMasksWithDifferentBitmapsAndTheSameStrokesDoNotShareARaster() throws {
        let strokes = [BrushStroke(points: [p(0.5, 0.1), p(0.5, 0.9)], radius: 0.05, feather: 0, flow: 1, erase: true)]
        let left = MaskShape.auto(AutoMask(kind: .subject, bitmap: leftHalf, strokes: strokes))
        let right = MaskShape.auto(AutoMask(kind: .subject, bitmap: bitmap(64, 48) { x, _ in x < 32 ? 0 : 255 },
                                            strokes: strokes))
        let cache = BrushRasterCache()
        let a = try drawn(left, 240, 160, cache: cache, at: [(0.2, 0.5), (0.8, 0.5)])
        let b = try drawn(right, 240, 160, cache: cache, at: [(0.2, 0.5), (0.8, 0.5)])
        XCTAssertEqual(a[0], 1, accuracy: 0.01)
        XCTAssertEqual(a[1], 0, accuracy: 0.01)
        XCTAssertEqual(b[0], 0, accuracy: 0.01, "the second bitmap's own weights, not the first's raster")
        XCTAssertEqual(b[1], 1, accuracy: 0.01)
        XCTAssertEqual(cache.rasters, 2)
        XCTAssertNotEqual(BrushRasterCache.key(for: strokes, base: leftHalf, width: 240, height: 160),
                          BrushRasterCache.key(for: strokes, width: 240, height: 160),
                          "a base is part of the key")
    }
}
