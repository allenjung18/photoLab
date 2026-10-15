import Foundation
import Accelerate

/// Builds the 3D lookup tables (`CIColorCube` data) for the two grouped
/// color stages: the tone lookup (highlights, shadows, whites, blacks and the
/// five curve points, one per-channel curve) and the per-band HSL cube. Both
/// cubes are applied in sRGB (gamma) space, where tone and lightness read the
/// way the sliders suggest.
///
/// Everything is vectorized with Accelerate so a debug build rebuilds a cube
/// in well under a millisecond: a slider step must stay inside one frame and
/// the tests run against a debug build. Built cubes are cached by their
/// parameters, so dragging an unrelated slider never rebuilds one.
enum ColorCubes {
    /// 32 samples per axis: 32768 entries, 512 KB of float RGBA, rebuilt in
    /// ~0.5 ms. Tone curves are smooth, so trilinear interpolation between
    /// 32 samples stays within one 8-bit step.
    static let dimension = 32

    // MARK: Tone

    /// Per-channel tone curve for the tone group, sampled at 256 points.
    /// Parameters are -1…1. Order: shadows/highlights bumps, then the
    /// whites/blacks end points, then the five-point curve.
    static func toneLUT(highlights: Double, shadows: Double, whites: Double, blacks: Double,
                        curve: [Double]) -> [Float] {
        let points = curvePoints(curve)
        return (0..<256).map { i in
            let x = Double(i) / 255
            var y = x
            y += shadows * 0.35 * 4 * x * (1 - x) * (1 - x)
            y += highlights * 0.35 * 4 * x * x * (1 - x)
            y += whites * 0.25 * x * x
            y += blacks * 0.25 * (1 - x) * (1 - x)
            y = min(1, max(0, y))
            return Float(min(1, max(0, catmullRom(points, y))))
        }
    }

    /// The five curve points: x at 0, ¼, ½, ¾, 1; each y offset by up to ±¼.
    private static func curvePoints(_ offsets: [Double]) -> [(Double, Double)] {
        let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
        return xs.enumerated().map { i, x in (x, min(1, max(0, x + (offsets.count > i ? offsets[i] : 0) * 0.25))) }
    }

    /// Catmull-Rom spline through `p` (ascending x), evaluated at `x`.
    private static func catmullRom(_ p: [(Double, Double)], _ x: Double) -> Double {
        let n = p.count
        var i = 0
        while i < n - 2 && x > p[i + 1].0 { i += 1 }
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, n - 1)]
        let h = p2.0 - p1.0
        let t = max(0, min(1, (x - p1.0) / h))
        // Tangents from the neighbors (one-sided at the ends), scaled to the interval.
        let m1 = (p2.1 - p0.1) / (p2.0 - p0.0) * h
        let m2 = (p3.1 - p1.1) / (p3.0 - p1.0) * h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p1.1 + (t3 - 2 * t2 + t) * m1
             + (-2 * t3 + 3 * t2) * p2.1 + (t3 - t2) * m2
    }

    /// Cube data applying `lut` to every channel.
    static func toneCube(_ lut: [Float]) -> Data {
        lock.lock(); defer { lock.unlock() }
        let ws = Workspace.shared
        ws.reset()
        let id = Identity.shared
        let r = gather(lut, id.index255[0], ws), g = gather(lut, id.index255[1], ws), b = gather(lut, id.index255[2], ws)
        return interleave(r, g, b, ws.count)
    }

    // MARK: HSL

    /// Cube data for the 24 HSL sliders (-1…1 each, indexed by
    /// `AdjustmentKind.HSLBand.rawValue`). Hue rotates a color about the gray
    /// axis by up to ±30° per band, saturation scales the distance from gray,
    /// luminance lifts toward white or pulls toward black; all three are
    /// weighted by the pixel's own saturation so grays never move.
    static func hslCube(hue: [Double], sat: [Double], lum: [Double]) -> Data {
        lock.lock(); defer { lock.unlock() }
        let ws = Workspace.shared
        ws.reset()
        let id = Identity.shared
        let (hueTable, satTable, lumTable) = bandTables(hue: hue, sat: sat, lum: lum)

        // Hue angle of every entry, (-π, π], then the per-entry deltas.
        let y = vsmul(vsub(id.g, id.b, ws), Float(3.0.squareRoot()), ws)
        let x = vsub(vsub(vsmul(id.r, 2, ws), id.g, ws), id.b, ws)
        let h = vatan2(y, x, ws)
        let idx = vsmul(vsadd(h, .pi, ws), Float(bandTableSize - 1) / (2 * .pi), ws)
        // Saturation weight: chroma over max, 0 on the gray axis.
        let mx = vmax(vmax(id.r, id.g, ws), id.b, ws), mn = vmin(vmin(id.r, id.g, ws), id.b, ws)
        let w = vdiv(vsub(mx, mn, ws), vsadd(mx, 1e-4, ws), ws)
        let dh = vmul(gather(hueTable, idx, ws), w, ws)
        let ds = vmul(gather(satTable, idx, ws), w, ws)
        let dl = vmul(gather(lumTable, idx, ws), w, ws)

        // Rotate about the gray axis (Rodrigues, k = (1,1,1)/√3).
        let cs = vcos(dh, ws), sn = vsin(dh, ws)
        let m = vsmul(vadd(vadd(id.r, id.g, ws), id.b, ws), 1.0 / 3, ws)
        let mk = vmul(m, vsadd(vsmul(cs, -1, ws), 1, ws), ws)
        let k = Float(1.0 / 3.0.squareRoot())
        let r1 = vadd(vadd(vmul(id.r, cs, ws), vsmul(vmul(vsub(id.b, id.g, ws), sn, ws), k, ws), ws), mk, ws)
        let g1 = vadd(vadd(vmul(id.g, cs, ws), vsmul(vmul(vsub(id.r, id.b, ws), sn, ws), k, ws), ws), mk, ws)
        let b1 = vadd(vadd(vmul(id.b, cs, ws), vsmul(vmul(vsub(id.g, id.r, ws), sn, ws), k, ws), ws), mk, ws)

        // Saturation: scale the distance from the mean.
        let m1 = vsmul(vadd(vadd(r1, g1, ws), b1, ws), 1.0 / 3, ws)
        let f = vsadd(ds, 1, ws)
        let r2 = vadd(m1, vmul(vsub(r1, m1, ws), f, ws), ws)
        let g2 = vadd(m1, vmul(vsub(g1, m1, ws), f, ws), ws)
        let b2 = vadd(m1, vmul(vsub(b1, m1, ws), f, ws), ws)

        // Luminance: v·(1+k⁻) + (1−v)·k⁺.
        let kl = vsmul(dl, 0.6, ws)
        let kp = vclip(kl, 0, 1, ws), kn1 = vsadd(vclip(kl, -1, 0, ws), 1, ws)
        func lift(_ v: Buf) -> Buf {
            vclip(vadd(vmul(v, kn1, ws), vmul(vsadd(vsmul(v, -1, ws), 1, ws), kp, ws), ws), 0, 1, ws)
        }
        return interleave(lift(r2), lift(g2), lift(b2), ws.count)
    }

    private static let bandTableSize = 720

    /// Per-hue tables of the summed band deltas (hue in radians, sat and lum
    /// as fractions): each band's static weight table times its slider.
    private static func bandTables(hue: [Double], sat: [Double], lum: [Double]) -> ([Float], [Float], [Float]) {
        var hueT = [Float](repeating: 0, count: bandTableSize)
        var satT = hueT, lumT = hueT
        let n = vDSP_Length(bandTableSize)
        for (b, weights) in bandWeights.enumerated() {
            var h = Float(hue[b] * 30 * .pi / 180), s = Float(sat[b]), l = Float(lum[b])
            vDSP_vsma(weights, 1, &h, hueT, 1, &hueT, 1, n)
            vDSP_vsma(weights, 1, &s, satT, 1, &satT, 1, n)
            vDSP_vsma(weights, 1, &l, lumT, 1, &lumT, 1, n)
        }
        return (hueT, satT, lumT)
    }

    /// Each band's weight over the hue table (index 0 is -π), falling
    /// linearly to zero at the neighboring bands' centers; the eight sum to 1.
    private static let bandWeights: [[Float]] = {
        let bands = AdjustmentKind.HSLBand.allCases
        let centers = bands.map { $0.centerDegrees }
        var tables = [[Float]](repeating: [Float](repeating: 0, count: bandTableSize), count: bands.count)
        for i in 0..<bandTableSize {
            let deg = (Double(i) / Double(bandTableSize - 1) * 360 + 180).truncatingRemainder(dividingBy: 360)
            // The two centers around `deg` on the circle (red wraps at 360).
            let upper = centers.firstIndex { $0 > deg } ?? 0
            let lower = (upper + bands.count - 1) % bands.count
            let lo = centers[lower]
            var hi = centers[upper]
            if hi <= lo { hi += 360 }
            let t = (deg - lo) / (hi - lo)
            tables[lower][i] += Float(1 - t)
            tables[upper][i] += Float(t)
        }
        return tables
    }()

    // MARK: Identity planes

    typealias Buf = UnsafeMutablePointer<Float>

    /// The R, G and B coordinate of every cube entry (0…1, r fastest), plus
    /// the same scaled to 0…255 with the half added for truncating gathers.
    /// Written once in `init` and only read after, so sharing it is safe.
    private final class Identity: @unchecked Sendable {

        static let shared = Identity()
        let count: Int
        let r: Buf, g: Buf, b: Buf
        let index255: [Buf]

        init() {
            let n = ColorCubes.dimension
            count = n * n * n
            r = Buf.allocate(capacity: count); g = Buf.allocate(capacity: count); b = Buf.allocate(capacity: count)
            var i = 0
            for bi in 0..<n {
                for gi in 0..<n {
                    for ri in 0..<n {
                        r[i] = Float(ri) / Float(n - 1)
                        g[i] = Float(gi) / Float(n - 1)
                        b[i] = Float(bi) / Float(n - 1)
                        i += 1
                    }
                }
            }
            let n3 = count
            index255 = [r, g, b].map { plane in
                let out = Buf.allocate(capacity: n3)
                var scale: Float = 255, half: Float = 0.5
                vDSP_vsmsa(plane, 1, &scale, &half, out, 1, vDSP_Length(n3))
                return out
            }
        }
    }

    /// Scratch buffers for one build, allocated once: a debug build spends
    /// ~50 µs on every fresh 128 KB array (an mmap and 32 page faults),
    /// which is most of a cube's cost; reusing them makes it ~0.5 ms.
    /// The pool starts at `slots` and grows by one buffer whenever a build
    /// asks for more (the new buffer is kept and reused like the rest), so a
    /// stage added to a cube can never trip a precondition. Every builder
    /// holds `ColorCubes.lock` while it uses `shared`, which is what makes
    /// the shared instance safe to hand around.
    final class Workspace: @unchecked Sendable {
        static let shared = Workspace(count: dimension * dimension * dimension, slots: 128)
        let count: Int
        private var slots: [Buf]
        private var next = 0

        init(count: Int, slots: Int) {
            self.count = count
            self.slots = (0..<slots).map { _ in Buf.allocate(capacity: count) }
        }

        /// Buffers the current (or last) build has taken since `reset`.
        var used: Int { next }
        /// Buffers allocated so far: the initial `slots` plus any growth.
        var capacity: Int { slots.count }

        func take() -> Buf {
            if next == slots.count { slots.append(Buf.allocate(capacity: count)) }
            defer { next += 1 }
            return slots[next]
        }

        func reset() { next = 0 }
    }


    private static let lock = NSLock()

    // MARK: vDSP helpers, each writing a fresh workspace buffer

    private static func vsub(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vsub(b, 1, a, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vadd(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vadd(a, 1, b, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vmul(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vmul(a, 1, b, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vdiv(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vdiv(b, 1, a, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vsmul(_ a: Buf, _ s: Float, _ ws: Workspace) -> Buf {
        let c = ws.take(); var s = s; vDSP_vsmul(a, 1, &s, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vsadd(_ a: Buf, _ s: Float, _ ws: Workspace) -> Buf {
        let c = ws.take(); var s = s; vDSP_vsadd(a, 1, &s, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vmax(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vmax(a, 1, b, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vmin(_ a: Buf, _ b: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); vDSP_vmin(a, 1, b, 1, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vclip(_ a: Buf, _ lo: Float, _ hi: Float, _ ws: Workspace) -> Buf {
        let c = ws.take(); var lo = lo, hi = hi; vDSP_vclip(a, 1, &lo, &hi, c, 1, vDSP_Length(ws.count)); return c
    }
    private static func vatan2(_ y: Buf, _ x: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); var n = Int32(ws.count); vvatan2f(c, y, x, &n); return c
    }
    private static func vsin(_ a: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); var n = Int32(ws.count); vvsinf(c, a, &n); return c
    }
    private static func vcos(_ a: Buf, _ ws: Workspace) -> Buf {
        let c = ws.take(); var n = Int32(ws.count); vvcosf(c, a, &n); return c
    }
    /// c[i] = table[Int(index[i])]; indices are clamped into the table.
    private static func gather(_ table: [Float], _ index: Buf, _ ws: Workspace) -> Buf {
        let clamped = vclip(index, 0, Float(table.count - 1), ws)
        let c = ws.take()
        vDSP_vindex(table, clamped, 1, c, 1, vDSP_Length(ws.count))
        return c
    }
    /// RGBA float data from three planes, alpha 1.
    private static func interleave(_ r: Buf, _ g: Buf, _ b: Buf, _ n: Int) -> Data {
        var data = Data(count: n * 4 * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            var zero: Float = 0, one: Float = 1
            vDSP_vsadd(r, 1, &zero, p, 4, vDSP_Length(n))
            vDSP_vsadd(g, 1, &zero, p + 1, 4, vDSP_Length(n))
            vDSP_vsadd(b, 1, &zero, p + 2, 4, vDSP_Length(n))
            vDSP_vfill(&one, p + 3, 4, vDSP_Length(n))
        }
        return data
    }
}

/// Built cubes keyed by their parameters; a slider step of an unrelated
/// kind reuses the cube, a step of a cube's own slider builds one (~0.5 ms).
final class CubeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[Double]: Data] = [:]
    private let limit = 64

    func cube(for key: [Double], build: () -> Data) -> Data {
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        lock.unlock()
        let data = build()
        lock.lock()
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = data
        lock.unlock()
        return data
    }
}
