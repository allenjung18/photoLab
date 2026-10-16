import Foundation
import CoreImage

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
        let long = max(width, height)
        let r = stroke.radius * long
        guard r > 0, long > 0, let first = stroke.points.first else { return ([], 0) }
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
        // The last point always carries a dab, so the stroke's end is covered.
        if stroke.points.count > 1, let last = out.last, last.x != prev.x || last.y != prev.y {
            out.append(prev)
        }
        return (out, r)
    }

    /// The brush's weight at `point` (source frame) over a source of `size`
    /// pixels: the rule above evaluated at one point (no quantisation).
    static func weight(of strokes: [BrushStroke], at point: MaskPoint, in size: CGSize) -> Double {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return 0 }
        let px = point.x * w, py = point.y * h
        var v = 0.0
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
    /// its centre, rounded to 8 bits.
    static func render(strokes: [BrushStroke], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let count = width * height
        var acc = [Float](repeating: 0, count: count)
        var cover = [Float](repeating: 0, count: count)
        acc.withUnsafeMutableBufferPointer { acc in
            cover.withUnsafeMutableBufferPointer { cover in
                for stroke in strokes {
                    let (centres, r) = dabs(of: stroke, width: Double(width), height: Double(height))
                    guard !centres.isEmpty else { continue }
                    // The stroke's pixel bounds; its coverage buffer is
                    // cleared and merged only there.
                    var x0 = width, y0 = height, x1 = -1, y1 = -1
                    for c in centres {
                        x0 = min(x0, max(0, Int((c.x - r).rounded(.down))))
                        y0 = min(y0, max(0, Int((c.y - r).rounded(.down))))
                        x1 = max(x1, min(width - 1, Int((c.x + r).rounded(.up))))
                        y1 = max(y1, min(height - 1, Int((c.y + r).rounded(.up))))
                    }
                    guard x0 <= x1, y0 <= y1 else { continue }
                    for y in y0...y1 {
                        for x in x0...x1 { cover[y * width + x] = 0 }
                    }
                    let r2 = r * r
                    for c in centres {
                        let dx0 = max(x0, Int((c.x - r).rounded(.down))), dx1 = min(x1, Int((c.x + r).rounded(.up)))
                        let dy0 = max(y0, Int((c.y - r).rounded(.down))), dy1 = min(y1, Int((c.y + r).rounded(.up)))
                        guard dx0 <= dx1, dy0 <= dy1 else { continue }
                        for y in dy0...dy1 {
                            let fy = Double(y) + 0.5 - c.y
                            let row = y * width
                            for x in dx0...dx1 {
                                let fx = Double(x) + 0.5 - c.x
                                let d2 = fx * fx + fy * fy
                                if d2 >= r2 { continue }
                                let a = Float(dabWeight(distance: d2.squareRoot() / r, feather: stroke.feather, flow: stroke.flow))
                                if a > cover[row + x] { cover[row + x] = a }
                            }
                        }
                    }
                    for y in y0...y1 {
                        let row = y * width
                        for x in x0...x1 {
                            let c = cover[row + x]
                            if c == 0 { continue }
                            acc[row + x] = stroke.erase ? acc[row + x] * (1 - c) : min(1, acc[row + x] + c)
                        }
                    }
                }
            }
        }
        return acc.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }
}

/// Rastered brush masks keyed by their strokes and raster size (the
/// `CubeCache` pattern): a render whose brush has not changed (dragging the
/// mask's own exposure, any global slider, a crop or rotate, which act after
/// the mask is drawn) reuses the image and never re-rasters. The image is the
/// raster as a one-channel Core Image bitmap at the origin, unscaled and not
/// colour-managed (its values are the weights).
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
        lock.unlock()
        let bytes = BrushRaster.render(strokes: strokes, width: width, height: height)
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width,
                            size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        lock.lock()
        rasterCount += 1
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = image
        lock.unlock()
        return image
    }
}
