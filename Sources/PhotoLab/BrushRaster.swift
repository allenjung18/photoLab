import Foundation
import CoreImage
import BrushKernel

/// Brush masks on the CPU: a brush mask's strokes become an 8-bit gray
/// buffer (255 = full effect), which `MaskRender` turns into a mask image
/// and runs through the same geometry pass and `CIBlendWithMask` as a
/// gradient. Pure: the same strokes at the same size give the same bytes.
///
/// How strokes lay down weight:
/// - A stroke is a run of round dabs, one every `dabSpacing` (a quarter of
///   the radius) of arc length along its points, plus one on the last point,
///   so both ends are covered; a single-point stroke is one dab.
/// - A dab weighs `flow` at its centre, easing smoothly (smoothstep) to 0
///   across the feather: 1 x flow inside radius x (1 - feather), 0 at and
///   beyond the radius.
/// - The dabs of one stroke merge by their maximum (one pass lays down at
///   most its `flow`, with no beading where dabs overlap); strokes then apply
///   in order: a paint stroke adds its coverage, clipped at 1, an erase
///   stroke multiplies the weight so far by 1 - its coverage (down to 0
///   under a flow-1 erase).
///
/// Geometry is in the source frame (`MaskPoint` fractions, `radius` a
/// fraction of the source long side), so a raster at any size lands on the
/// same pixels; `weight(of:at:in:)` is the same rule at one point, which is
/// what `MaskMath` reports for a brush.
enum BrushRaster {
    /// The largest raster long side. A larger rendered source is rastered at
    /// this size and scaled up by Core Image (`MaskRender`).
    static let maxLongSide = 4096

    /// The raster size for a rendered source of `size` pixels: its own size
    /// (rounded, at least 1x1), scaled down to `maxLongSide` on the long side
    /// beyond that, aspect kept.
    static func rasterSize(for size: CGSize) -> (width: Int, height: Int) {
        let long = max(size.width, size.height)
        guard long > 0 else { return (1, 1) }
        let s = min(1, CGFloat(maxLongSide) / long)
        return (max(1, Int((size.width * s).rounded())), max(1, Int((size.height * s).rounded())))
    }

    /// The distance between dabs along a stroke, in the stroke's own units:
    /// a quarter of the radius.
    static func dabSpacing(radius: Double) -> Double { radius / 4 }

    /// A dab's weight at `distance` from its centre (units of the radius):
    /// `flow` inside 1 - feather, a smoothstep down to 0 at 1, 0 beyond.
    static func dabWeight(distance d: Double, feather: Double, flow: Double) -> Double {
        let flow = min(max(flow, 0), 1)
        if d >= 1 { return 0 }
        let inner = 1 - min(max(feather, 0), 1)
        if d <= inner { return flow }
        let t = (1 - d) / (1 - inner)
        return flow * t * t * (3 - 2 * t)
    }

    /// The dab centres of `stroke` over a frame of `width` x `height`
    /// (any units with the frame's aspect), in those units, origin
    /// top-left; and the radius in the same units. Empty for a stroke with
    /// no points or a radius at or below zero.
    static func dabs(of stroke: BrushStroke, width: Double, height: Double) -> (centres: [(x: Double, y: Double)], radius: Double) {
        let w = walk(of: stroke, width: width, height: height)
        return (w.centres, w.radius)
    }

    /// `dabs(of:width:height:)` and how many of the centres are the walk's
    /// (`walked`): all but a last-point dab, when the walk did not end on
    /// the last point. A stroke that grows by points keeps its walked dabs
    /// (the walk over its first points is the same arithmetic) and moves only
    /// that last one, which is what lets a live stroke raster incrementally
    /// (`BrushRasterCache`).
    static func walk(of stroke: BrushStroke, width: Double, height: Double)
        -> (centres: [(x: Double, y: Double)], radius: Double, walked: Int) {
        let long = max(width, height)
        let r = stroke.radius * long
        guard r > 0, long > 0, let first = stroke.points.first else { return ([], 0, 0) }
        let spacing = dabSpacing(radius: r)
        func at(_ p: MaskPoint) -> (x: Double, y: Double) { (p.x * width, p.y * height) }
        var out = [at(first)]
        var prev = at(first)
        // Arc length walked since the last dab.
        var since = 0.0
        for p in stroke.points.dropFirst() {
            let next = at(p)
            let dx = next.x - prev.x, dy = next.y - prev.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0 {
                var along = spacing - since
                while along <= len {
                    out.append((prev.x + dx * along / len, prev.y + dy * along / len))
                    along += spacing
                }
                since = len - (along - spacing)
            }
            prev = next
        }
        let walked = out.count
        // The last point always carries a dab, so the stroke's end is covered.
        if stroke.points.count > 1, let last = out.last, last.x != prev.x || last.y != prev.y {
            out.append(prev)
        }
        return (out, r, walked)
    }

    /// The brush's weight at `point` (source frame) over a source of `size`
    /// pixels: the rule above evaluated at one point (no quantisation),
    /// starting from `base` (0 for a brush mask; an automatic mask's bitmap
    /// weight for its refining strokes).
    static func weight(of strokes: [BrushStroke], at point: MaskPoint, in size: CGSize,
                       over base: Double = 0) -> Double {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return base }
        let px = point.x * w, py = point.y * h
        var v = base
        for stroke in strokes {
            let (centres, r) = dabs(of: stroke, width: w, height: h)
            var cover = 0.0
            for c in centres {
                let d = ((px - c.x) * (px - c.x) + (py - c.y) * (py - c.y)).squareRoot() / r
                cover = max(cover, dabWeight(distance: d, feather: stroke.feather, flow: stroke.flow))
            }
            v = stroke.erase ? v * (1 - cover) : min(1, v + cover)
        }
        return v
    }

    /// The strokes rastered over `width` x `height` pixels: one byte per
    /// pixel, rows top-down, 255 = weight 1. Each pixel is the rule above at
    /// its centre, rounded to 8 bits. The pixel loops are BrushKernel's (C,
    /// optimised in every build); `LiveRaster` runs the same loops a stroke
    /// at a time, so both give the same bytes.
    static func render(strokes: [BrushStroke], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let live = LiveRaster(width: width, height: height)
        live.rebuild(strokes)
        return live.out
    }

    /// `strokes` applied over `base` (an 8-bit raster, rows top-down, the
    /// starting weights) at `width` x `height`: each stroke's dabs
    /// max-merged, then composed in order by the rule above, then quantised.
    /// The same C loops as `render(strokes:width:height:)`. An automatic
    /// mask's refined raster.
    static func render(strokes: [BrushStroke], over base: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, base.count == width * height else { return base }
        var acc = base.map { Float($0) / 255 }
        var cover = [Float](repeating: 0, count: width * height)
        let x1 = Int32(width - 1), y1 = Int32(height - 1)
        for stroke in strokes {
            let d = dabs(of: stroke, width: Double(width), height: Double(height))
            guard !d.centres.isEmpty else { continue }
            cover.withUnsafeMutableBufferPointer { c in
                bk_stamp(c.baseAddress!, Int32(width), 0, 0, x1, y1, d.centres.map(\.x), d.centres.map(\.y),
                         Int32(d.centres.count), d.radius, stroke.feather, stroke.flow)
                acc.withUnsafeMutableBufferPointer { a in
                    bk_compose(a.baseAddress!, c.baseAddress!, Int32(width), 0, 0, x1, y1, stroke.erase ? 1 : 0)
                }
                bk_clear(c.baseAddress!, Int32(width), 0, 0, x1, y1)
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        acc.withUnsafeBufferPointer { a in
            out.withUnsafeMutableBufferPointer { o in bk_quantize(o.baseAddress!, a.baseAddress!, Int32(width * height)) }
        }
        return out
    }
}

/// A brush raster that can grow: the weight of every stroke but the last
/// (`acc`), the last stroke's walked dabs max-merged (`cover`) and the 8-bit
/// raster of them all (`out`). `update` takes the brush's new strokes and
/// does the least work that gives the same bytes as rastering them afresh:
/// - the last stroke grew (its points so far a prefix of the new ones, same
///   radius, feather, flow and erase): only its new walked dabs are stamped,
///   and only the pixels they, the old last-point dab and the new one touch
///   are re-quantised;
/// - a new stroke followed the last one as rastered: that one is composed
///   into `acc` over its own bounds, and the new one starts;
/// - anything else (an undo, a stroke edited, another brush): a rebuild.
/// Max-merging is exact and every pixel goes through the same C loops, so
/// the bytes never depend on the path taken.
final class LiveRaster {
    let width: Int
    let height: Int
    private(set) var acc: [Float]
    private var cover: [Float]
    private(set) var out: [UInt8]
    /// The strokes in `acc`, and the last one as `cover` holds it.
    private var base: [BrushStroke] = []
    private var stroke: BrushStroke?
    private var walked = 0
    private var tail: (x: Double, y: Double)?
    /// The pixels the last stroke touched so far (inclusive), nil before any.
    private var bounds: (x0: Int, y0: Int, x1: Int, y1: Int)?

    /// How the last `update` went: the test seam for the incremental path.
    enum Path: Equatable { case rebuilt, grew, followed, unchanged }
    private(set) var lastPath = Path.rebuilt

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        acc = [Float](repeating: 0, count: width * height)
        cover = acc
        out = [UInt8](repeating: 0, count: width * height)
    }

    var strokes: [BrushStroke] { stroke.map { base + [$0] } ?? base }

    func update(_ strokes: [BrushStroke]) {
        guard let last = strokes.last, let current = stroke else { return rebuild(strokes) }
        let before = strokes.dropLast()
        if before.elementsEqual(base), Self.grows(current, into: last) {
            if last == current { lastPath = .unchanged; return }
            grow(last)
            lastPath = .grew
        } else if before.count == base.count + 1, before.last == current, before.dropLast().elementsEqual(base) {
            commit()
            grow(last)
            lastPath = .followed
        } else {
            rebuild(strokes)
        }
    }

    /// True when `next` is `stroke` with points added (or the same).
    static func grows(_ stroke: BrushStroke, into next: BrushStroke) -> Bool {
        stroke.radius == next.radius && stroke.feather == next.feather && stroke.flow == next.flow
            && stroke.erase == next.erase && stroke.points.count <= next.points.count
            && next.points.prefix(stroke.points.count).elementsEqual(stroke.points)
    }

    /// Everything from nothing: every stroke but the last into `acc`, the
    /// last one live.
    func rebuild(_ strokes: [BrushStroke]) {
        lastPath = .rebuilt
        acc.withUnsafeMutableBufferPointer { a in
            cover.withUnsafeMutableBufferPointer { c in
                bk_clear(a.baseAddress!, Int32(width), 0, 0, Int32(width - 1), Int32(height - 1))
                bk_clear(c.baseAddress!, Int32(width), 0, 0, Int32(width - 1), Int32(height - 1))
            }
        }
        base = []
        stroke = nil
        walked = 0
        tail = nil
        bounds = nil
        for s in strokes.dropLast() {
            grow(s, quantize: false)
            commit()
        }
        acc.withUnsafeBufferPointer { a in
            out.withUnsafeMutableBufferPointer { o in bk_quantize(o.baseAddress!, a.baseAddress!, Int32(width * height)) }
        }
        if let last = strokes.last { grow(last) }
    }

    /// The live stroke becomes `next` (a stroke it grows into, or any stroke
    /// when there is none): its new walked dabs stamped, the tail moved, the
    /// touched pixels re-quantised (unless `quantize` is false: a rebuild
    /// quantises once at the end).
    private func grow(_ next: BrushStroke, quantize: Bool = true) {
        let w = BrushRaster.walk(of: next, width: Double(width), height: Double(height))
        let from = stroke == nil ? 0 : walked
        let fresh = w.walked > from ? Array(w.centres[from..<w.walked]) : []
        let newTail = w.walked < w.centres.count ? w.centres[w.centres.count - 1] : nil
        var dirty = box(fresh, w.radius)
        if let t = tail { dirty = union(dirty, box([t], w.radius)) }
        if let t = newTail { dirty = union(dirty, box([t], w.radius)) }
        if !fresh.isEmpty {
            let xs = fresh.map(\.x), ys = fresh.map(\.y)
            cover.withUnsafeMutableBufferPointer { c in
                bk_stamp(c.baseAddress!, Int32(width), 0, 0, Int32(width - 1), Int32(height - 1),
                         xs, ys, Int32(fresh.count), w.radius, next.feather, next.flow)
            }
        }
        bounds = union(bounds, box(fresh, w.radius))
        if let t = newTail { bounds = union(bounds, box([t], w.radius)) }
        stroke = next
        walked = w.walked
        tail = newTail
        if quantize, let d = dirty { requantize(d) }
    }

    /// The live stroke composed into `acc` for good (its tail dab stamped
    /// first), `cover` cleared under it.
    private func commit() {
        guard let s = stroke else { return }
        defer {
            base.append(s)
            stroke = nil
            walked = 0
            tail = nil
            bounds = nil
        }
        guard let b = bounds else { return }
        let r = s.radius * Double(max(width, height))
        cover.withUnsafeMutableBufferPointer { c in
            if let t = tail {
                bk_stamp(c.baseAddress!, Int32(width), 0, 0, Int32(width - 1), Int32(height - 1),
                         [t.x], [t.y], 1, r, s.feather, s.flow)
            }
            acc.withUnsafeMutableBufferPointer { a in
                bk_compose(a.baseAddress!, c.baseAddress!, Int32(width), Int32(b.x0), Int32(b.y0), Int32(b.x1), Int32(b.y1),
                           s.erase ? 1 : 0)
            }
            bk_clear(c.baseAddress!, Int32(width), Int32(b.x0), Int32(b.y0), Int32(b.x1), Int32(b.y1))
        }
    }

    private func requantize(_ d: (x0: Int, y0: Int, x1: Int, y1: Int)) {
        guard let s = stroke else { return }
        let r = s.radius * Double(max(width, height))
        acc.withUnsafeBufferPointer { a in
            cover.withUnsafeBufferPointer { c in
                out.withUnsafeMutableBufferPointer { o in
                    bk_quantize_live(o.baseAddress!, a.baseAddress!, c.baseAddress!, Int32(width),
                                     Int32(d.x0), Int32(d.y0), Int32(d.x1), Int32(d.y1), s.erase ? 1 : 0,
                                     tail == nil ? 0 : 1, tail?.x ?? 0, tail?.y ?? 0, r, s.feather, s.flow)
                }
            }
        }
    }

    /// The pixels dabs at `centres` of radius `r` can touch, clipped; nil for none.
    private func box(_ centres: [(x: Double, y: Double)], _ r: Double) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard !centres.isEmpty, r > 0 else { return nil }
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for c in centres {
            x0 = min(x0, max(0, Int((c.x - r).rounded(.down))))
            y0 = min(y0, max(0, Int((c.y - r).rounded(.down))))
            x1 = max(x1, min(width - 1, Int((c.x + r).rounded(.up))))
            y1 = max(y1, min(height - 1, Int((c.y + r).rounded(.up))))
        }
        return x0 <= x1 && y0 <= y1 ? (x0, y0, x1, y1) : nil
    }

    private func union(_ a: (x0: Int, y0: Int, x1: Int, y1: Int)?, _ b: (x0: Int, y0: Int, x1: Int, y1: Int)?)
        -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard let a else { return b }
        guard let b else { return a }
        return (min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1))
    }
}

/// Rastered brush masks keyed by their strokes and raster size (the
/// `CubeCache` pattern): a render whose brush has not changed (dragging the
/// mask's own exposure, any global slider, a crop or rotate, which act after
/// the mask is drawn) reuses the image and never re-rasters. The image is the
/// raster as a one-channel Core Image bitmap at the origin, unscaled and not
/// colour-managed (its values are the weights).
///
/// A miss rasters through a `LiveRaster` kept per raster size (a few: the
/// loupe, the 1:1 view, the preset strip), so a stroke being painted, whose
/// strokes change on every point and miss every time, stamps only its new
/// dabs over the buffer it left (a live stroke's frame costs its new dabs,
/// not the whole brush); any other change rebuilds that size's buffer.
final class BrushRasterCache: @unchecked Sendable {
    static let shared = BrushRasterCache()

    struct Key: Hashable {
        let strokes: [BrushStroke]
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var entries: [Key: CIImage] = [:]
    /// A 4096 px raster is ~11 MB; a handful covers the loupe, the 1:1 view
    /// and an export of the same brush, and the preset strip's thumbnails.
    private let limit = 8
    private var rasterCount = 0
    /// One growing raster per size, the most recent last; at most `liveLimit`
    /// (a 4096 px one holds ~100 MB of buffers).
    private var live: [(width: Int, height: Int, raster: LiveRaster, lock: NSLock)] = []
    private let liveLimit = 3
    /// How the last miss rastered: the test seam for the incremental path.
    var lastPath: LiveRaster.Path? {
        lock.lock(); defer { lock.unlock() }
        return lastPathValue
    }
    private var lastPathValue: LiveRaster.Path?

    /// How many times this cache has rastered (a miss): the test seam that
    /// shows a repeated render does not raster again.
    var rasters: Int {
        lock.lock(); defer { lock.unlock() }
        return rasterCount
    }

    static func key(for strokes: [BrushStroke], width: Int, height: Int) -> Key {
        Key(strokes: strokes, width: width, height: height)
    }

    /// The raster of `strokes` at `width` x `height`, from the cache or
    /// rastered now.
    func image(for strokes: [BrushStroke], width: Int, height: Int) -> CIImage {
        let key = Self.key(for: strokes, width: width, height: height)
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        let entry: (raster: LiveRaster, lock: NSLock)
        if let i = live.firstIndex(where: { $0.width == width && $0.height == height }) {
            let e = live.remove(at: i)
            live.append(e)
            entry = (e.raster, e.lock)
        } else {
            if live.count >= liveLimit { live.removeFirst() }
            let e = (width: width, height: height, raster: LiveRaster(width: width, height: height), lock: NSLock())
            live.append(e)
            entry = (e.raster, e.lock)
        }
        lock.unlock()
        entry.lock.lock()
        entry.raster.update(strokes)
        let path = entry.raster.lastPath
        let image = CIImage(bitmapData: Data(entry.raster.out), bytesPerRow: width,
                            size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        entry.lock.unlock()
        lock.lock()
        lastPathValue = path
        rasterCount += 1
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = image
        lock.unlock()
        return image
    }
}
