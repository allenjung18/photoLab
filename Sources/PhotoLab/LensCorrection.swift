import Foundation
import CoreImage

/// The pure math of the two lens corrections (`AdjustmentKind.lensDistortion`,
/// `.lensVignette`), apart from Core Image so it can be tested on its own.
///
/// Positions are normalised about the frame centre by the half diagonal, so
/// a corner sits at radius 1 whatever the image's size: the preview's
/// downsampled master and the full-resolution export get the same warp.
enum LensMath {
    /// The radial coefficient at slider +100 (magnitude). Kept below 1/3 with
    /// room to spare so the warp stays monotonic out to the corners even
    /// after the fill zoom (`scale`).
    static let maxK = 0.2

    /// The warp coefficient for a slider value: plus corrects barrel
    /// distortion (the output samples the source nearer the centre, pulling
    /// the bowed-out edges back in), minus corrects pincushion.
    static func k(for value: Double) -> Double { -value / 100 * maxK }

    /// The source point an output point reads, both normalised (`q`, units
    /// of the half diagonal, about the centre): `q * (1 + k |q|²)` at the
    /// zoomed point `q = s * p`. The zoom is applied before the warp, so the
    /// corrected picture is only scaled about the centre and a line the warp
    /// straightens stays straight.
    static func source(of p: SIMD2<Double>, k: Double, scale s: Double) -> SIMD2<Double> {
        let q = p * s
        return q * (1 + k * (q.x * q.x + q.y * q.y))
    }

    /// The fill zoom for a `width` × `height` frame: the largest `s` for
    /// which every point of the frame's border reads the source at least one
    /// pixel inside its own edge, so no empty edge shows and the output keeps
    /// the input's extent. The border point that binds is the corner for
    /// k > 0 (it is pushed out the most) and the midpoint of the nearer edge
    /// for k < 0 (pulled in the least). One for k = 0.
    static func scale(k: Double, width: Double, height: Double) -> Double {
        guard k != 0, width > 2, height > 2 else { return 1 }
        let hd = hypot(width, height) / 2
        let rho = k > 0 ? 1 : min(width, height) / 2 / hd
        let target = 1 - 2 / min(width, height)
        // s (1 + k s² ρ²) = target: increasing in s on this bracket for
        // |k| <= maxK (its derivative 1 + 3 k s² ρ² stays positive).
        var lo = 0.25, hi = 1.5
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if mid * (1 + k * mid * mid * rho * rho) > target { hi = mid } else { lo = mid }
        }
        return lo
    }

    /// The lens-vignette gain at normalised radius `r` (0 centre, 1 corner):
    /// `2^(value/100 · r²)`, so +100 lifts the corners one stop, -100 darkens
    /// them one stop, and the centre is untouched.
    static func vignetteGain(value: Double, radius r: Double) -> Double {
        exp2(value / 100 * r * r)
    }
}

/// The Core Image side of the lens corrections: one warp kernel and one
/// color kernel, compiled once at runtime from Metal source
/// (`CIKernel.kernels(withMetalString:)`, macOS 12 and later, below the
/// package's macOS 14 floor), so SwiftPM needs no .metal build step. Both
/// keep the input's extent. They run only on a Metal-backed context (the
/// app's `Renderer` makes one); without kernels a stage returns its input.
enum LensCorrection {
    private final class Kernels: @unchecked Sendable {
        let warp: CIWarpKernel?
        let gain: CIColorKernel?

        init() {
            let kernels = (try? CIKernel.kernels(withMetalString: LensCorrection.source)) ?? []
            warp = kernels.first { $0.name == "lensDistortion" } as? CIWarpKernel
            gain = kernels.first { $0.name == "lensVignette" } as? CIColorKernel
        }
    }

    private static let kernels = Kernels()

    /// True when both kernels compiled.
    static var isAvailable: Bool { kernels.warp != nil && kernels.gain != nil }

    static let source = """
    #include <CoreImage/CoreImage.h>
    extern "C" {
    namespace coreimage {
    // Output point -> source point: q = s (p - c) / hd, source = c + hd q (1 + k |q|^2).
    [[stitchable]] float2 lensDistortion(float2 c, float hd, float k, float s, destination dest) {
        float2 q = (dest.coord() - c) * (s / hd);
        return c + q * (hd * (1.0 + k * dot(q, q)));
    }
    // A radial gain in stops, 0 at the centre, `stops` at the corners.
    [[stitchable]] float4 lensVignette(sample_t px, float2 c, float hd, float stops, destination dest) {
        float2 q = (dest.coord() - c) / hd;
        float g = exp2(stops * dot(q, q));
        return float4(px.rgb * g, px.a);
    }
    }
    }
    """

    /// The distortion correction for slider `value` over `image`'s extent.
    static func distort(_ image: CIImage, value: Double) -> CIImage {
        guard let warp = kernels.warp else { return image }
        let e = image.extent
        let k = LensMath.k(for: value)
        let s = LensMath.scale(k: k, width: e.width, height: e.height)
        let c = CGPoint(x: e.midX, y: e.midY)
        let hd = hypot(e.width, e.height) / 2
        // The source a destination rect reads: every point is scaled about
        // the centre by s (1 + k s² r²), a factor between its values at the
        // rect's nearest and farthest radius, so the box spanned by the rect
        // scaled by those two factors holds it; two pixels of slack for the
        // bilinear footprint.
        let roi: CIKernelROICallback = { _, rect in
            func factor(_ r: Double) -> Double { s * (1 + k * s * s * r * r) }
            let nx = min(max(c.x, rect.minX), rect.maxX), ny = min(max(c.y, rect.minY), rect.maxY)
            let rNear = hypot(nx - c.x, ny - c.y) / hd
            let rFar = max(hypot(rect.minX - c.x, rect.minY - c.y), hypot(rect.maxX - c.x, rect.minY - c.y),
                           hypot(rect.minX - c.x, rect.maxY - c.y), hypot(rect.maxX - c.x, rect.maxY - c.y)) / hd
            var box = CGRect.null
            for f in [factor(rNear), factor(rFar)] {
                box = box.union(CGRect(x: c.x + (rect.minX - c.x) * f, y: c.y + (rect.minY - c.y) * f,
                                       width: rect.width * f, height: rect.height * f))
            }
            return box.insetBy(dx: -2, dy: -2)
        }
        let out = warp.apply(extent: e, roiCallback: roi, image: image,
                             arguments: [CIVector(x: c.x, y: c.y), hd, k, s])
        return out?.cropped(to: e) ?? image
    }

    /// The lens-vignette correction for slider `value` over `image`'s extent.
    static func vignette(_ image: CIImage, value: Double) -> CIImage {
        guard let gain = kernels.gain else { return image }
        let e = image.extent
        let c = CIVector(x: e.midX, y: e.midY)
        let hd = hypot(e.width, e.height) / 2
        return gain.apply(extent: e, arguments: [image, c, hd, value / 100])?.cropped(to: e) ?? image
    }
}
