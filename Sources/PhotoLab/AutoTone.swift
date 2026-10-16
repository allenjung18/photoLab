import Foundation
import CoreImage

/// Auto: temperature and tint first (`WhiteBalance.auto`), then exposure,
/// contrast, highlights, shadows, whites and blacks set from
/// the photo's histogram (the Basic section's **Auto** button, Photo › Auto
/// Tone, ⌘U). `values(from:)` is a pure function of one `Histogram`; the
/// rest says which histogram that is.
///
/// The histogram is of the photo's recipe with these six kinds at neutral
/// (`base`), rendered through the one chain at `analysisPixelSize` and
/// counted by `Histogram.compute`: the same measurement the panel shows,
/// minus the six values Auto is about to replace. So Auto reads the same
/// input however often it runs, and running it again sets the same values
/// (idempotent); every other edit (white balance, the tone curve, the crop)
/// is measured as it is.
///
/// The values come from a model of the chain itself (`Model`): exposure is a
/// gain on linear values (`CIExposureAdjust`), contrast scales linear values
/// about 0.5 (`CIColorControls` in the linear working space), and the tone
/// stage is `ColorCubes.toneLUT` on the sRGB-encoded result, so a target in
/// the 8-bit frame is solved for, not guessed:
/// - exposure moves the luma median to `midTarget` (half way when
///   darkening), never pushing the brightest channel's 99.5th percentile
///   past `whiteCeiling`, nor darkening it below there when it was at or
///   above it (a clipped top is the whites' to bring in);
/// - contrast (within `contrastRange`) takes the interquartile spread toward
///   `spreadTarget`, its exposure re-solved with it;
/// - whites move the brightest channel's 99.5th percentile into
///   `whiteWindow`, blacks the luma's 0.5th percentile into `blackWindow`,
///   and neither moves when the point is already inside;
/// - highlights pull down when more than `massThreshold` of the frame sits
///   above `upperZone`, shadows lift when as much sits below `lowerZone`.
enum AutoTone {
    /// The kinds Auto sets, the Basic section's.
    static let toneKinds: [AdjustmentKind] = [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
    /// White balance, set first (`WhiteBalance.auto`) and left alone when
    /// the photo has no readable cast.
    static let whiteBalanceKinds: [AdjustmentKind] = [.temperature, .tint]
    /// Every kind Auto sets: the six tone values and the white balance.
    static let kinds: [AdjustmentKind] = toneKinds + whiteBalanceKinds
    /// The batch mask Auto applies through (`Library.sync`).
    static let mask = SyncMask(kinds: Set(kinds))
    /// Auto White Balance alone: temperature and tint only.
    static let whiteBalanceMask = SyncMask(kinds: Set(whiteBalanceKinds))
    /// The long side the analysis frame is rendered at.
    static let analysisPixelSize = 512

    // Targets, as 0…1 values of the 8-bit frame.
    static let midTarget = 0.46
    static let spreadTarget = 0.30
    static let whiteCeiling = 0.97
    static let whiteWindow = 0.90...0.96
    static let blackWindow = 0.01...0.05
    static let upperZone = 0.85
    static let lowerZone = 0.15
    static let massThreshold = 0.10
    // Limits, in slider units.
    static let exposureLimit = 2.0
    static let contrastRange = -10...10
    static let zoneLimit = 50.0
    static let pointLimit = 50

    // MARK: Inputs

    /// The recipe whose frame Auto measures: `recipe` with the six kinds at
    /// neutral (and enabled, as the default has them).
    static func base(_ recipe: Recipe) -> Recipe {
        var r = recipe.normalized
        for kind in toneKinds { r[kind] = Adjustment(kind: kind, value: kind.neutral) }
        return r
    }

    /// The histogram Auto reads for a photo whose master is `master`: its
    /// `base` recipe through `Renderer` at `analysisPixelSize`, counted by
    /// `Histogram.compute`. Synchronous; call off the main thread.
    static func histogram(of master: CIImage, recipe: Recipe) -> Histogram? {
        guard let frame = Renderer.shared.render(master, recipe: base(recipe), maxPixelSize: analysisPixelSize)
        else { return nil }
        return Histogram.compute(frame.image)
    }

    /// The six values for the photo, or nil when no frame could be made.
    static func values(for master: CIImage, recipe: Recipe) -> [AdjustmentKind: Double]? {
        // White balance first; the six are then measured on the recipe with
        // it, so the tone is solved for the colours the photo will have.
        var measured = recipe.normalized
        var wb: [AdjustmentKind: Double] = [:]
        if let auto = WhiteBalance.auto(for: master, recipe: recipe) {
            wb = [.temperature: auto.temperature, .tint: auto.tint]
            for (kind, value) in wb { measured[kind] = Adjustment(kind: kind, value: value) }
        }
        guard var out = histogram(of: master, recipe: measured).map(values(from:)) else { return nil }
        out.merge(wb) { $1 }
        return out
    }

    /// `recipe` with the six values set and enabled.
    static func applying(_ values: [AdjustmentKind: Double], to recipe: Recipe) -> Recipe {
        var r = recipe.normalized
        for kind in toneKinds {
            r[kind] = Adjustment(kind: kind, value: values[kind] ?? kind.neutral)
        }
        // A white balance Auto could not read stays as the recipe has it.
        for kind in whiteBalanceKinds {
            if let value = values[kind] { r[kind] = Adjustment(kind: kind, value: value) }
        }
        return r
    }

    // MARK: The function

    /// The six values (slider units: exposure in EV to 0.05, the rest whole
    /// numbers) for a frame whose histogram, with the six at neutral, is `h`.
    static func values(from h: Histogram) -> [AdjustmentKind: Double] {
        let lo = percentile(h.luminance, 0.005)
        let q25 = percentile(h.luminance, 0.25)
        let mid = percentile(h.luminance, 0.5)
        let q75 = percentile(h.luminance, 0.75)
        let hi = max(percentile(h.red, 0.995), percentile(h.green, 0.995), percentile(h.blue, 0.995))

        // 1. Contrast, with the exposure that puts the median on target at
        //    that contrast. Ties go to the smaller contrast.
        var best: (score: Double, model: Model)?
        for k in contrastRange {
            var m = Model(contrast: Double(k))
            m.exposure = exposure(mid: mid, hi: hi, contrast: m.contrast)
            let spread = m.pre(q25: q25, q75: q75)
            let score = abs(spread - spreadTarget) + 0.004 * Double(abs(k)) + 2 * m.clippedFraction(h.luminance)
            if best == nil || score < best!.score - 1e-9 || (abs(score - best!.score) <= 1e-9 && abs(k) < abs(Int(best!.model.contrast))) {
                best = (score, m)
            }
        }
        var m = best!.model

        // 2. The end points: whites, then blacks with the whites chosen.
        //    Highlights and shadows are left out here: their terms vanish at
        //    0 and 1, and the points are the whites' and blacks' own job.
        let hiX = m.pre(hi), loX = m.pre(lo)
        m.whites = Double(solve(window: whiteWindow) { w in m.with(whites: w).lut(hiX) })
        m.blacks = Double(solve(window: blackWindow) { b in m.with(blacks: b).lut(loX) })

        // 3. Highlights and shadows from where the mass sits after 1.
        let total = Double(max(1, h.luminance.reduce(0, +)))
        var upper = 0.0, lower = 0.0
        for (i, n) in h.luminance.enumerated() where n > 0 {
            let x = m.pre(Double(i) / 255)
            if x > upperZone { upper += Double(n) }
            if x < lowerZone { lower += Double(n) }
        }
        m.highlights = -min(zoneLimit, max(0, ((upper / total - massThreshold) * 200).rounded()))
        m.shadows = min(zoneLimit, max(0, ((lower / total - massThreshold) * 200).rounded()))

        // `+ 0` turns a -0 (a rounded small pull) into 0 for the sidecar.
        return [.exposure: m.exposure + 0, .contrast: m.contrast + 0, .highlights: m.highlights + 0,
                .shadows: m.shadows + 0, .whites: m.whites + 0, .blacks: m.blacks + 0]
    }

    /// The exposure (EV, to 0.05, within `exposureLimit`) that moves `mid`
    /// toward `midTarget` at `contrast`. Brightening goes the whole way but
    /// stops where `hi` would pass `whiteCeiling`. Darkening goes half way
    /// (a bright frame is often meant bright) and stops where `hi` would
    /// fall below `whiteCeiling` when it is clipped or near it (the white
    /// point is the whites' to set, so a blown sky is recovered by whites
    /// and highlights, not by darkening the whole frame), below the white
    /// window when it is under that.
    private static func exposure(mid: Double, hi: Double, contrast: Double) -> Double {
        let k = 1 + contrast / 100
        // Linear value before contrast that lands on `target` after it.
        let before = { (target: Double) in (linear(target) - 0.5) / k + 0.5 }
        var ev = log2(max(1e-6, before(midTarget)) / linear(max(mid, 1.0 / 255)))
        if ev > 0, hi > 0 {
            let cap = log2(max(1e-6, before(whiteCeiling)) / linear(hi))
            ev = min(ev, max(0, cap))
        } else if ev < 0 {
            let floorTop = hi >= whiteCeiling ? whiteCeiling : whiteWindow.lowerBound
            let floor = hi > floorTop ? log2(max(1e-6, before(floorTop)) / linear(hi)) : 0
            ev = max(ev / 2, min(0, floor))
        }
        ev = (ev * 20).rounded() / 20
        return min(exposureLimit, max(-exposureLimit, ev))
    }

    /// The whole slider value in ±`pointLimit` whose output at the point is
    /// closest to the point's own output held into `window`: zero when the
    /// point is already inside. Ties go to the smaller magnitude.
    private static func solve(window: ClosedRange<Double>, _ output: (Int) -> Double) -> Int {
        let target = min(window.upperBound, max(window.lowerBound, output(0)))
        var best = 0, bestError = abs(output(0) - target)
        for v in -pointLimit...pointLimit {
            let e = abs(output(v) - target)
            if e < bestError - 1e-9 || (abs(e - bestError) <= 1e-9 && abs(v) < abs(best)) {
                best = v
                bestError = e
            }
        }
        return best
    }

    /// The value (0…1) below which `q` of the counts lie.
    static func percentile(_ bins: [Int], _ q: Double) -> Double {
        let total = bins.reduce(0, +)
        guard total > 0 else { return 0 }
        let wanted = q * Double(total)
        var running = 0
        for (i, n) in bins.enumerated() {
            running += n
            if Double(running) >= wanted && n > 0 { return Double(i) / 255 }
        }
        return 1
    }

    static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// The six values as the chain applies them, mapping a frame value (0…1)
    /// of the neutral render to its value under them.
    struct Model {
        var exposure = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0

        /// Exposure and contrast: the value the tone stage receives.
        func pre(_ x: Double) -> Double {
            let l = AutoTone.linear(x) * pow(2, exposure)
            let c = (l - 0.5) * (1 + contrast / 100) + 0.5
            return AutoTone.encoded(min(1, max(0, c)))
        }

        func pre(q25: Double, q75: Double) -> Double { pre(q75) - pre(q25) }

        /// The share of a histogram that exposure and contrast push to
        /// either end of the frame.
        func clippedFraction(_ bins: [Int]) -> Double {
            let total = Double(max(1, bins.reduce(0, +)))
            var n = 0
            for (i, c) in bins.enumerated() where c > 0 {
                let x = pre(Double(i) / 255)
                if x >= 254.0 / 255 || x <= 1.0 / 255 { n += c }
            }
            return Double(n) / total
        }

        /// The tone stage (`ColorCubes.toneLUT`, the renderer's own) at `x`.
        func lut(_ x: Double) -> Double {
            let table = ColorCubes.toneLUT(highlights: highlights / 100, shadows: shadows / 100,
                                           whites: whites / 100, blacks: blacks / 100, curve: [0, 0, 0, 0, 0])
            let p = min(1, max(0, x)) * 255
            let i = min(254, Int(p))
            let t = p - Double(i)
            return Double(table[i]) * (1 - t) + Double(table[i + 1]) * t
        }

        func with(whites v: Int) -> Model { var m = self; m.whites = Double(v); return m }
        func with(blacks v: Int) -> Model { var m = self; m.blacks = Double(v); return m }
    }
}
