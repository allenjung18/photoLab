import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Painting the brush (BrushTool.swift): a drag on the photo becomes ONE
/// thinned stroke in the source frame, Option makes it an erase stroke, one
/// stroke is one undo step and one sidecar write, [ and ] step the size
/// inside its range, and nothing paints with no brush mask selected. The
/// live-stroke render budget is `BrushStrokeBudgetTests`.
@MainActor
final class BrushToolTests: XCTestCase {
    private var folder: URL!
    private let wide = CGSize(width: 1200, height: 800)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-brushtool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

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

    private func strokes(_ lib: Library, _ id: Photo.ID, _ mask: UUID) -> [BrushStroke] {
        guard case .brush(let s) = lib.mask(mask, for: id)?.shape else { return [] }
        return s
    }

    /// A drag of `count` view points from `a` to `b`, mapped to the source
    /// as the overlay maps it, painted and released.
    private func drag(_ lib: Library, _ id: Photo.ID, from a: CGPoint, to b: CGPoint, count: Int,
                      geometry g: MaskMath.Geometry, viewport v: MaskMath.Viewport, erase: Bool = false) -> [MaskPoint] {
        let views = (0..<count).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let start = MaskMath.viewToSource(views[0], g, v)!
        var mapped: [MaskPoint] = []
        for p in views {
            let s = MaskMath.viewToSource(p, g, v)!
            mapped.append(s)
            lib.paintBrush(from: start, to: s, erase: erase, size: g.source, for: id)
        }
        lib.endBrushStroke(id)
        return mapped
    }

    func testADragOf2000ViewPointsIsOneThinnedStrokeInSourceCoordinatesUnderRotateAndCrop() throws {
        let (lib, id) = try openOne()
        let mask = lib.addMask(.brush, for: id)
        XCTAssertEqual(lib.paintingBrush, mask, "a new brush mask is armed")
        lib.brush = BrushSettings(size: 0.04, feather: 0.3, flow: 0.7)
        let g = MaskMath.Geometry(source: wide, rotate: 7.5,
                                  crop: CropMath.Crop(left: 0.1, top: 0.05, right: 0.15, bottom: 0.1))
        let v = MaskMath.Viewport.fit(CGRect(x: 40, y: 30, width: 900, height: 560))
        let a = CGPoint(x: 80, y: 100), b = CGPoint(x: 900, y: 520)
        let mapped = drag(lib, id, from: a, to: b, count: 2000, geometry: g, viewport: v)

        let all = strokes(lib, id, mask)
        XCTAssertEqual(all.count, 1, "one drag, one stroke")
        let stroke = try XCTUnwrap(all.first)
        XCTAssertEqual(stroke.radius, 0.04)
        XCTAssertEqual(stroke.feather, 0.3)
        XCTAssertEqual(stroke.flow, 0.7)
        XCTAssertFalse(stroke.erase)
        // Thinned: every point at least radius/4 (long-side units) from the
        // one before, so the 2000 pointer positions become a few dozen.
        let s = MaskHandles.scale(wide)
        let gap = 0.04 / 4
        for (p, q) in zip(stroke.points, stroke.points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(hypot((q.x - p.x) * s.x, (q.y - p.y) * s.y), gap - 1e-12)
        }
        let first = mapped[0], last = mapped[mapped.count - 1]
        let length = hypot((last.x - first.x) * s.x, (last.y - first.y) * s.y)
        XCTAssertLessThanOrEqual(stroke.points.count, Int(length / gap) + 1)
        XCTAssertGreaterThanOrEqual(stroke.points.count, Int(length / gap) - 1, "nothing thinned away beyond the gap")
        XCTAssertLessThan(stroke.points.count, 200, "a long drag stays a few hundred points at most")
        // In the source frame: the first point is the drag's start mapped
        // through rotate and crop, every point is a mapped pointer position,
        // and each maps back onto the dragged line in the view.
        XCTAssertEqual(stroke.points[0], first)
        for p in stroke.points {
            XCTAssertTrue(mapped.contains(p), "\(p) is a mapped pointer position")
            let back = MaskMath.sourceToView(p, g, v)
            let cross = ((back.x - a.x) * (b.y - a.y) - (back.y - a.y) * (b.x - a.x)) / hypot(b.x - a.x, b.y - a.y)
            XCTAssertEqual(cross, 0, accuracy: 1e-6, "on the dragged line")
        }
        XCTAssertNotEqual(first.x, (a.x - 40) / 900, accuracy: 1e-3, "not the view fraction: rotate and crop were undone")
    }

    func testOptionMakesAnEraseStroke() throws {
        let (lib, id) = try openOne()
        let mask = lib.addMask(.brush, for: id)
        let g = MaskMath.Geometry(source: wide), v = MaskMath.Viewport.fit(CGRect(x: 0, y: 0, width: 600, height: 400))
        _ = drag(lib, id, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 200), count: 50, geometry: g, viewport: v)
        _ = drag(lib, id, from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 100), count: 50, geometry: g, viewport: v,
                 erase: true)
        XCTAssertEqual(strokes(lib, id, mask).map(\.erase), [false, true])
    }

    func testOneStrokeIsOneUndoStepAndOneSidecarWrite() throws {
        let (lib, id) = try openOne()
        let mask = lib.addMask(.brush, for: id)
        let g = MaskMath.Geometry(source: wide), v = MaskMath.Viewport.fit(CGRect(x: 0, y: 0, width: 600, height: 400))
        let writes = lib.sidecarWrites
        let views = (0..<300).map { CGPoint(x: 50 + Double($0), y: 100 + Double($0) / 2) }
        let start = MaskMath.viewToSource(views[0], g, v)!
        for p in views {
            lib.paintBrush(from: start, to: MaskMath.viewToSource(p, g, v)!, erase: false, size: wide, for: id)
        }
        XCTAssertGreaterThan(strokes(lib, id, mask).first?.points.count ?? 0, 10, "the stroke grows live")
        XCTAssertEqual(lib.sidecarWrites, writes, "nothing written mid-stroke")
        lib.endBrushStroke(id)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        lib.undo()
        XCTAssertEqual(strokes(lib, id, mask), [], "one undo takes the whole stroke away")
        XCTAssertNotNil(lib.mask(mask, for: id), "and only the stroke: the mask stays")
        // A stroke cut off (Esc puts the brush down mid-drag) is kept, as one step.
        lib.redo()
        lib.maskBrushArmed = true
        let before = strokes(lib, id, mask).count
        lib.paintBrush(from: start, to: start, erase: false, size: wide, for: id)
        lib.paintBrush(from: start, to: MaskPoint(x: 0.6, y: 0.6), erase: false, size: wide, for: id)
        lib.maskBrushArmed = false
        XCTAssertEqual(strokes(lib, id, mask).count, before + 1)
        lib.paintBrush(from: start, to: MaskPoint(x: 0.8, y: 0.8), erase: false, size: wide, for: id)
        XCTAssertEqual(strokes(lib, id, mask).count, before + 1, "the brush is down: nothing more paints")
        lib.undo()
        XCTAssertEqual(strokes(lib, id, mask).count, before)
    }

    /// Review findings: an undo mid-stroke, or a drag cut off with no
    /// mouse-up, must not leave the next points growing an older stroke one
    /// undo step and one write per point.
    func testAnUndoMidStrokeOrADragWithNoMouseUpStartsTheNextStrokeAfresh() throws {
        let (lib, id) = try openOne()
        let mask = lib.addMask(.brush, for: id)
        let a = MaskPoint(x: 0.1, y: 0.1), b = MaskPoint(x: 0.6, y: 0.6)
        lib.paintBrush(from: a, to: a, erase: false, size: wide, for: id)
        lib.endBrushStroke(id)
        // Painting, then ⌘Z with the mouse still down.
        lib.paintBrush(from: b, to: b, erase: false, size: wide, for: id)
        lib.paintBrush(from: b, to: MaskPoint(x: 0.65, y: 0.6), erase: false, size: wide, for: id)
        // Undo with an edit open drops it and goes back one step (the first
        // stroke), as a slider's does.
        lib.undo()
        XCTAssertEqual(strokes(lib, id, mask).count, 0)
        let writes = lib.sidecarWrites
        for i in 1...20 {
            lib.paintBrush(from: b, to: MaskPoint(x: 0.65 + 0.02 * Double(i), y: 0.6), erase: false, size: wide, for: id)
        }
        lib.endBrushStroke(id)
        XCTAssertEqual(strokes(lib, id, mask).count, 1, "one new stroke")
        XCTAssertEqual(strokes(lib, id, mask)[0].points.first, b)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one write for the new stroke, not one per point")
        // A drag cut off (no endBrushStroke), then a new drag elsewhere.
        let c = MaskPoint(x: 0.2, y: 0.8), d = MaskPoint(x: 0.8, y: 0.2)
        lib.paintBrush(from: c, to: c, erase: false, size: wide, for: id)
        lib.paintBrush(from: c, to: MaskPoint(x: 0.3, y: 0.8), erase: false, size: wide, for: id)
        lib.paintBrush(from: d, to: d, erase: true, size: wide, for: id)
        lib.endBrushStroke(id)
        let all = strokes(lib, id, mask)
        XCTAssertEqual(all.count, 3, "the cut-off drag and the new one are two strokes")
        XCTAssertEqual(all[2].points, [d])
        XCTAssertTrue(all[2].erase)
        XCTAssertFalse(all[1].erase)
        lib.undo()
        XCTAssertEqual(strokes(lib, id, mask).count, 2, "two drags, two undo steps")
    }

    func testBracketsStepTheSizeInsideItsRange() throws {
        let (lib, id) = try openOne()
        let ctx = CommandContext(library: lib)
        let smaller = AppCommand.command(.brushSmaller), larger = AppCommand.command(.brushLarger)
        XCTAssertEqual(smaller.key, "[")
        XCTAssertEqual(larger.key, "]")
        XCTAssertFalse(larger.isEnabled(ctx), "off with no brush to paint")
        lib.addMask(.brush, for: id)
        XCTAssertTrue(larger.isEnabled(ctx))
        let size = lib.brush.size
        larger.perform(ctx)
        XCTAssertEqual(lib.brush.size, size * BrushSettings.sizeStep, accuracy: 1e-12)
        smaller.perform(ctx)
        XCTAssertEqual(lib.brush.size, size, accuracy: 1e-12)
        for _ in 0..<60 { larger.perform(ctx) }
        XCTAssertEqual(lib.brush.size, BrushSettings.sizeRange.upperBound)
        for _ in 0..<60 { smaller.perform(ctx) }
        XCTAssertEqual(lib.brush.size, BrushSettings.sizeRange.lowerBound)
        lib.textEntryActive = true
        XCTAssertFalse(larger.isEnabled(ctx), "a bare key: off while typing")
    }

    func testADragWithNoBrushSelectedChangesNothing() throws {
        let (lib, id) = try openOne()
        let g = MaskMath.Geometry(source: wide), v = MaskMath.Viewport.fit(CGRect(x: 0, y: 0, width: 600, height: 400))
        let writes = lib.sidecarWrites
        // No mask at all.
        _ = drag(lib, id, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300), count: 40, geometry: g, viewport: v)
        XCTAssertEqual(lib.recipe(for: id), .neutral)
        // A linear selected.
        let linear = lib.addMask(.linear, for: id)
        let recipe = lib.recipe(for: id)
        XCTAssertNil(lib.paintingBrush)
        _ = drag(lib, id, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300), count: 40, geometry: g, viewport: v)
        XCTAssertEqual(lib.recipe(for: id), recipe)
        // A brush in the list but not selected.
        let brush = lib.addMask(.brush, for: id)
        lib.selectedMask = linear
        let withBrush = lib.recipe(for: id)
        _ = drag(lib, id, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300), count: 40, geometry: g, viewport: v)
        XCTAssertEqual(lib.recipe(for: id), withBrush)
        XCTAssertEqual(strokes(lib, id, brush), [])
        // Selecting the brush in the list arms it; Esc puts it down and then nothing paints.
        lib.selectedMask = brush
        XCTAssertEqual(lib.paintingBrush, brush)
        AppCommand.command(.back).perform(CommandContext(library: lib))
        XCTAssertNil(lib.paintingBrush)
        _ = drag(lib, id, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300), count: 40, geometry: g, viewport: v)
        XCTAssertEqual(strokes(lib, id, brush), [])
        // K arms the selected brush again rather than adding a new one.
        AppCommand.command(.brushMask).perform(CommandContext(library: lib))
        XCTAssertEqual(lib.paintingBrush, brush)
        XCTAssertEqual(lib.recipe(for: id).masks.count, 2)
        XCTAssertEqual(lib.sidecarWrites, writes + 2, "only the two adds wrote")
    }
}

/// A raster grown a point at a time is the raster made afresh, byte for
/// byte, whichever path each step took (`LiveRaster`).
final class LiveRasterTests: XCTestCase {
    func testGrowingFollowingAndRebuildingGiveTheSameBytesAsAFreshRaster() {
        let w = 240, h = 160
        let paint = BrushStroke(points: (0..<40).map { i in
            MaskPoint(x: 0.1 + 0.02 * Double(i), y: 0.3 + 0.1 * sin(Double(i) / 5))
        }, radius: 0.06, feather: 0.4, flow: 0.7)
        let erase = BrushStroke(points: (0..<30).map { i in
            MaskPoint(x: 0.8 - 0.02 * Double(i), y: 0.2 + 0.015 * Double(i))
        }, radius: 0.04, feather: 0.8, flow: 1, erase: true)
        let again = BrushStroke(points: (0..<25).map { i in
            MaskPoint(x: 0.3 + 0.01 * Double(i), y: 0.7 - 0.012 * Double(i))
        }, radius: 0.08, feather: 0, flow: 0.5)
        let live = LiveRaster(width: w, height: h)
        var done: [BrushStroke] = []
        var paths: [LiveRaster.Path] = []
        for stroke in [paint, erase, again] {
            for n in 1...stroke.points.count {
                var s = stroke
                s.points = Array(stroke.points.prefix(n))
                let strokes = done + [s]
                live.update(strokes)
                paths.append(live.lastPath)
                XCTAssertEqual(live.out, BrushRaster.render(strokes: strokes, width: w, height: h),
                               "after \(done.count) strokes and \(n) points")
            }
            done.append(stroke)
        }
        XCTAssertEqual(paths.filter { $0 == .followed }.count, 2, "each new stroke followed the last")
        XCTAssertEqual(paths.filter { $0 == .rebuilt }.count, 1, "only the first update rebuilt")
        // An undo (a stroke gone) and an edited stroke rebuild, and are still exact.
        live.update([paint, erase])
        XCTAssertEqual(live.lastPath, .rebuilt)
        XCTAssertEqual(live.out, BrushRaster.render(strokes: [paint, erase], width: w, height: h))
        var thinner = erase
        thinner.flow = 0.5
        live.update([paint, thinner])
        XCTAssertEqual(live.lastPath, .rebuilt)
        XCTAssertEqual(live.out, BrushRaster.render(strokes: [paint, thinner], width: w, height: h))
        live.update([paint, thinner])
        XCTAssertEqual(live.lastPath, .unchanged)
        live.update([])
        XCTAssertEqual(live.out, [UInt8](repeating: 0, count: w * h))
    }
}

/// The live stroke's render budget: at the loupe's 2600 px over the
/// everything-on recipe with a linear, a radial and a 500-point brush, a
/// stroke growing 10 points per frame (the raster cache misses on every
/// frame: the strokes changed) renders under one 60 Hz frame. The file goes
/// through the loupe's master decode first; the gate is read against the
/// load average (`assertFrameBudget`), the best of up to three sweeps.
final class BrushStrokeBudgetTests: XCTestCase {
    static func recipe(liveStroke points: [MaskPoint]) -> Recipe {
        var r = ToneSetTests.everythingOnWithMasks()
        let painted = BrushStroke(points: (0..<500).map { i in
            let t = Double(i) / 499
            return MaskPoint(x: 0.1 + 0.8 * t, y: 0.5 + 0.15 * sin(t * 4 * .pi))
        }, radius: 0.05, feather: 0.5, flow: 0.8)
        let live = BrushStroke(points: points, radius: 0.05, feather: 0.5, flow: 0.8)
        r.masks[2].shape = .brush(points.isEmpty ? [painted] : [painted, live])
        return r
    }

    /// The live stroke's points: a loop around the frame's centre, spaced as
    /// thinning keeps them (a quarter of the radius, long-side units).
    static func livePoints(_ count: Int, size: CGSize) -> [MaskPoint] {
        let s = MaskHandles.scale(size)
        let gap = BrushThinning.minimumGap(radius: 0.05)
        let ring = 0.25
        return (0..<count).map { i in
            let a = Double(i) * gap / ring
            return MaskPoint(x: 0.5 + ring * cos(a) / s.x, y: 0.5 + ring * sin(a) / s.y)
        }
    }

    func testAGrowingStrokeRendersEachFrameUnderTheBudgetAt2600() throws {
        let env = ProcessInfo.processInfo.environment
        let renderer = Renderer.shared
        var load = loadAverage()
        let url = try bench24MPImageURL()
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize))
        let target = Int(env["PHOTOLAB_BENCH_TARGET"] ?? "2600") ?? 2600
        let size = master.extent.size
        let frames = 30, perFrame = 10
        let all = Self.livePoints(frames * perFrame + perFrame, size: size)
        // Warm the kernels; the same recipe again is a cache hit: the chain's
        // own cost, for the bench line.
        let still = Self.recipe(liveStroke: [])
        _ = renderer.render(master, recipe: still, maxPixelSize: target)
        let hits = try (0..<5).map { _ in try XCTUnwrap(renderer.render(master, recipe: still, maxPixelSize: target)).milliseconds }
        var best: (median: Double, p90: Double, max: Double)?
        var attempts = 0
        repeat {
            attempts += 1
            // Each sweep paints a new stroke over the 500-point brush, as a
            // new drag would: the brush as it was rendered first (untimed;
            // a rebuild after the last sweep's stroke), then every frame.
            _ = renderer.render(master, recipe: still, maxPixelSize: target)
            let misses = BrushRasterCache.shared.rasters
            var times: [Double] = []
            for f in 1...frames {
                // What the loupe renders mid-stroke (`Library.previewRecipe`).
                let r = Self.recipe(liveStroke: Array(all.prefix(f * perFrame))).draft(since: still)
                let out = try XCTUnwrap(renderer.render(master, recipe: r, maxPixelSize: target))
                times.append(out.milliseconds)
                XCTAssertEqual(BrushRasterCache.shared.lastPath, f == 1 ? .followed : .grew,
                               "frame \(f) stamps only its new dabs")
            }
            XCTAssertEqual(BrushRasterCache.shared.rasters - misses, frames, "every frame is a raster miss")
            let sorted = times.sorted()
            let m = (sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted[sorted.count - 1])
            if best == nil || m.1 < best!.p90 { best = m }
            load = max(load, loadAverage())
        } while best!.p90 >= frameBudgetBound(16, load: load) && attempts < 3
        let b = best!
        print(String(format: "BENCH-BRUSH %@: master %d×%d, preview %d px, %d frames of +%d points over a 500-point brush, a linear and a radial; median %.1f ms, p90 %.1f ms, max %.1f ms (the same recipe from the cache %.1f ms), load %.2f%@",
                     url.lastPathComponent, Int(size.width), Int(size.height), target, frames, perFrame,
                     b.median, b.p90, b.max, hits.sorted()[2], load, attempts > 1 ? " (best of \(attempts) sweeps)" : ""))
        try assertFrameBudget(b.p90, bound: 16, load: load, "a growing brush stroke's frame (p90)")
    }
}
