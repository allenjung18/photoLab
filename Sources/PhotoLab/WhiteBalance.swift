import Foundation
import CoreImage
import CoreGraphics

/// The white-balance eyedropper's arithmetic, kept out of the view and the
/// library so it can be tested: the frame it samples (`base`), the patch
/// under a click (`patch`), and the temperature and tint that render that
/// patch grey (`neutralising`). No new adjustment kind: the result is the
/// existing Temperature and Tint sliders, set by `Library.pickWhiteBalance`
/// through `setRecipe` as one undo step.
///
/// Colours are sRGB-encoded, 0…1 per channel, as the sliders' own renders
/// read back in sRGB.
enum WhiteBalance {
    /// A channel at or above this in the patch is clipped: the true colour
    /// is lost, so the patch is refused.
    static let clippedLevel = 0.98
    /// A channel below this in the patch is too dark to read a cast from:
    /// refused.
    static let darkLevel = 0.02
    /// A pixel whose channels differ by more than this is a colour, not a
    /// neutral, and is left out of Auto's grey-world mean.
    static let saturatedLevel = 0.25
    /// Fewer than this share of the frame near-neutral: Auto falls back to
    /// every unclipped pixel.
    static let neutralShare = 0.05
    /// The patch sampled around the click, in pixels of the sampled frame.
    static let patchSize = 5

    /// The eyedropper's answer for one patch.
    enum Solve: Equatable {
        /// The slider values that render the patch grey (clamped to the
        /// sliders' ranges, so a cast beyond them is reduced, not removed).
        case balanced(temperature: Double, tint: Double)
        /// A channel at or above `clippedLevel`: nothing is changed.
        case clipped
        /// A channel below `darkLevel`: nothing is changed.
        case tooDark

        /// The status line for a refusal; nil when balanced.
        var refusal: String? {
            switch self {
            case .balanced: return nil
            case .clipped: return "White balance: that spot is clipped. Click a neutral area that is not blown out."
            case .tooDark: return "White balance: that spot is too dark. Click a lighter neutral area."
            }
        }
    }

    /// The white-balance stage's own input: `recipe` with every kind from
    /// temperature onward (in chain order, `AdjustmentKind.allCases`) at its
    /// neutral value, and no local adjustments (`Recipe.masks`: their stage
    /// sits after HSL, past the white-balance stage). Geometry and exposure
    /// stay, so a point normalised in the shown frame lands on the same
    /// pixel here.
    static func base(_ recipe: Recipe) -> Recipe {
        var r = recipe
        r.masks = []
        guard let first = AdjustmentKind.allCases.firstIndex(of: .temperature) else { return r }
        for kind in AdjustmentKind.allCases[first...] { r.reset(kind) }
        return r
    }

    /// Auto's answer for one photo: the temperature and tint that render the
    /// frame's average colour grey (a grey-world estimate), solved by the
    /// same `neutralising` as the eyedropper. The frame is `recipe` through
    /// `base` and `AutoTone.base` (so Auto reads it the same however often
    /// it ran), rendered at `AutoTone.analysisPixelSize`; the average is over
    /// the pixels that are not clipped, not dark and not strongly saturated
    /// (`greyWorldMean`). Nil when nothing is readable (an all-black or
    /// all-white frame): white balance is then left alone.
    static func auto(for master: CIImage, recipe: Recipe,
                     renderer: Renderer = .shared) -> (temperature: Double, tint: Double)? {
        let input = AutoTone.base(base(recipe))
        guard let frame = renderer.render(master, recipe: input, maxPixelSize: AutoTone.analysisPixelSize),
              let mean = greyWorldMean(frame.image),
              case .balanced(let temperature, let tint) = neutralising(mean, renderer: renderer)
        else { return nil }
        return (temperature, tint)
    }

    /// The mean sRGB colour of `cg`'s near-neutral pixels (no channel at or
    /// above `clippedLevel` or below `darkLevel`, channels within
    /// `saturatedLevel` of each other); when fewer than `neutralShare` of
    /// the pixels qualify, the mean of every unclipped pixel. Nil when there
    /// is none.
    static func greyWorldMean(_ cg: CGImage) -> SIMD3<Double>? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var neutral = SIMD3<Double>(repeating: 0), unclipped = neutral
        var nNeutral = 0, nUnclipped = 0
        for i in 0..<(w * h) {
            let c = SIMD3(Double(p[i * 4]), Double(p[i * 4 + 1]), Double(p[i * 4 + 2])) / 255
            if c.max() >= clippedLevel { continue }
            unclipped += c; nUnclipped += 1
            if c.min() >= darkLevel, spread(c) <= saturatedLevel { neutral += c; nNeutral += 1 }
        }
        if nNeutral > 0, Double(nNeutral) >= neutralShare * Double(w * h) { return neutral / Double(nNeutral) }
        return nUnclipped > 0 ? unclipped / Double(nUnclipped) : nil
    }

    /// The mean colour of the `patchSize`-pixel square around `point`
    /// (normalised in the rendered frame, origin top-left) of `recipe` over
    /// `source`: one `Renderer.render` with a `Renderer.Region`, read back in
    /// sRGB. Nil when the render fails.
    static func patch(of source: CIImage, recipe: Recipe, at point: CGPoint,
                      renderer: Renderer = .shared) -> SIMD3<Double>? {
        let region = Renderer.Region(center: point, size: CGSize(width: patchSize, height: patchSize))
        guard let cg = renderer.render(source, recipe: recipe, region: region)?.image else { return nil }
        return meanSRGB(cg)
    }

    /// `cg`'s mean colour, drawn into an sRGB bitmap first so a photo in
    /// another colour space reads in the same space as `neutralising`.
    static func meanSRGB(_ cg: CGImage) -> SIMD3<Double>? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = SIMD3<Double>(repeating: 0)
        for i in 0..<(w * h) {
            sum += SIMD3(Double(p[i * 4]), Double(p[i * 4 + 1]), Double(p[i * 4 + 2]))
        }
        return sum / Double(w * h * 255)
    }

    /// The temperature and tint that render a patch of colour `rgb` (the
    /// white-balance stage's input) grey: a coarse-to-fine search through
    /// `Renderer.apply` on a 1×1 `CIImage(color:)`, so the filter itself is
    /// the truth and the sign of each slider is whatever it renders. A 5×5
    /// grid over both ranges picks the start, then a compass search halves
    /// its step down to 1/32 of a slider unit. Values are clamped to the
    /// sliders' ranges and rounded to 0.01. A clipped or near-black patch
    /// is refused.
    static func neutralising(_ rgb: SIMD3<Double>, renderer: Renderer = .shared) -> Solve {
        if rgb.max() >= clippedLevel { return .clipped }
        if rgb.min() < darkLevel { return .tooDark }
        let probe = Probe(rgb, renderer: renderer)
        let tRange = AdjustmentKind.temperature.range, iRange = AdjustmentKind.tint.range

        var best = (t: 0.0, i: 0.0), bestCost = probe.cost(0, 0)
        for t in stride(from: tRange.lowerBound, through: tRange.upperBound, by: 50) {
            for i in stride(from: iRange.lowerBound, through: iRange.upperBound, by: 50) {
                let c = probe.cost(t, i)
                if c < bestCost { best = (t, i); bestCost = c }
            }
        }
        var step = 25.0
        while step >= 1.0 / 32 {
            var moved = false
            for (dt, di) in [(step, 0.0), (-step, 0.0), (0.0, step), (0.0, -step)] {
                let t = min(max(best.t + dt, tRange.lowerBound), tRange.upperBound)
                let i = min(max(best.i + di, iRange.lowerBound), iRange.upperBound)
                let c = probe.cost(t, i)
                if c < bestCost { best = (t, i); bestCost = c; moved = true }
            }
            if !moved { step /= 2 }
        }
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return .balanced(temperature: round2(best.t), tint: round2(best.i))
    }

    /// `rgb` rendered with only temperature and tint set, read back in sRGB.
    static func rendered(_ rgb: SIMD3<Double>, temperature: Double, tint: Double,
                         renderer: Renderer = .shared) -> SIMD3<Double> {
        Probe(rgb, renderer: renderer).render(temperature, tint)
    }

    /// The largest difference between two channels.
    static func spread(_ rgb: SIMD3<Double>) -> Double { rgb.max() - rgb.min() }

    /// One patch colour, rendered at candidate slider values.
    private struct Probe {
        let image: CIImage
        let renderer: Renderer
        static let space = CGColorSpace(name: CGColorSpace.sRGB)!

        init(_ rgb: SIMD3<Double>, renderer: Renderer) {
            let color = CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1, colorSpace: Self.space)
                ?? CIColor(red: rgb.x, green: rgb.y, blue: rgb.z)
            image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            self.renderer = renderer
        }

        func render(_ temperature: Double, _ tint: Double) -> SIMD3<Double> {
            var r = Recipe.neutral
            r.set(.temperature, to: temperature)
            r.set(.tint, to: tint)
            let out = renderer.apply(r, to: image)
            var px = [Float](repeating: 0, count: 4)
            renderer.context.render(out, toBitmap: &px, rowBytes: 16,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: Self.space)
            return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
        }

        /// How far from grey: the squared distance of each channel from the
        /// patch's mean.
        func cost(_ temperature: Double, _ tint: Double) -> Double {
            let c = render(temperature, tint)
            let d = c - SIMD3(repeating: (c.x + c.y + c.z) / 3)
            return (d * d).sum()
        }
    }
}
