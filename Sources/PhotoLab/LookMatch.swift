import Foundation
import CoreImage

/// Look matching: the global values that make a photo look like a target,
/// solved for, not modelled. The target is an `ImageStats` (what the look
/// measures: tone, colour, saturation); `values(target:master:recipe:)`
/// searches the twelve `kinds` for the recipe whose frame measures
/// closest to it, `ImageStats.distance` the cost.
///
/// The search runs through the real chain: every candidate is the photo's
/// recipe with the candidate values set (`applying`), rendered and measured
/// by `ImageStats.of(master:recipe:)` at `AutoTone.analysisPixelSize`. No
/// slider's sign or strength is assumed, as `WhiteBalance.neutralising`
/// does for temperature and tint: the filter is the truth.
///
/// It starts from `base(_:)` (the recipe with the twelve at neutral, as
/// `AutoTone.base`), so the answer depends on the photo and the target
/// only and running it again gives the same values (idempotent):
/// 1. coarse, in three stages, each kind swept over `coarseOffsets` (slider
///    steps from where the search stands), keeping the best:
///    - tone (`toneKinds`, one at a time) on the tone term alone
///      (`toneWeights`), so whites and blacks are not spent faking a colour;
///    - colour on the full cost: temperature and saturation together over
///      `coarseOffsets` × `coarseOffsets` (a warm cast saturates every grey,
///      so either swept alone reads a warm, desaturated look as a wrong
///      turn), then tint and vibrance one at a time;
///    - each grade range's hue and saturation together over `coarseHues` ×
///      `coarseGradeSats`;
/// 2. compass on the full cost (`weights`): every kind tries one step up
///    and one down (hue wrapping round 0…360, a hue under no saturation
///    skipped), from `compassStart` steps halving to one, a move only on a
///    strictly lower cost.
/// Every point is on the sliders' own grid (`step(of:)`: exposure 0.05 EV,
/// the rest whole numbers, as `AutoTone`) inside the kind's `range`, so no
/// rounding moves the answer off what was measured.
///
/// Pure and synchronous, no UI and no state; call off the main thread.
enum LookMatch {
    /// The kinds a look match sets: the global tone and colour.
    static let kinds: [AdjustmentKind] = [
        .exposure, .contrast, .whites, .blacks,
        .temperature, .tint, .saturation, .vibrance,
        .gradeShadowHue, .gradeShadowSat, .gradeHighlightHue, .gradeHighlightSat,
    ]
    /// The batch mask a look match applies through (`Library.sync`).
    static let mask = SyncMask(kinds: Set(kinds))
    /// How the cost weighs tone, colour and saturation.
    static let weights = ImageStats.Weights.standard
    /// The coarse tone stage's weights: `weights`' tone term alone.
    static var toneWeights: ImageStats.Weights {
        ImageStats.Weights(tone: weights.tone, colour: 0, saturation: 0)
    }
    /// The kinds the coarse tone stage sweeps.
    static let toneKinds: [AdjustmentKind] = [.exposure, .contrast, .whites, .blacks]

    /// Coarse sweep offsets, in slider steps (exposure: ±0.8, 1.6, 3.2 EV).
    static let coarseOffsets = [-64, -32, -16, 16, 32, 64]
    /// Coarse grade hues (degrees) and saturations, tried in pairs.
    static let coarseHues = stride(from: 0, to: 360, by: 45).map(Double.init)
    static let coarseGradeSats: [Double] = [16, 32]
    /// The compass search's first step, in slider steps (hue twice it).
    static let compassStart = 8

    /// The grade pairs: (hue, saturation) per range searched.
    static let gradePairs: [(hue: AdjustmentKind, sat: AdjustmentKind)] = [
        (.gradeShadowHue, .gradeShadowSat), (.gradeHighlightHue, .gradeHighlightSat),
    ]

    // MARK: Inputs

    /// The recipe a look match starts from: `recipe` with the twelve kinds
    /// at neutral (and enabled, as the default has them).
    static func base(_ recipe: Recipe) -> Recipe {
        var r = recipe.normalized
        for kind in kinds { r[kind] = Adjustment(kind: kind, value: kind.neutral) }
        return r
    }

    /// One slider step of `kind`: 0.05 EV for exposure, else 1.
    static func step(of kind: AdjustmentKind) -> Double { kind == .exposure ? 0.05 : 1 }

    /// `recipe` with `values` set and enabled; a kind not in `values` keeps
    /// the recipe's own.
    static func applying(_ values: [AdjustmentKind: Double], to recipe: Recipe) -> Recipe {
        var r = recipe.normalized
        for kind in kinds {
            if let v = values[kind] { r[kind] = Adjustment(kind: kind, value: v) }
        }
        return r
    }

    // MARK: The solve

    /// The twelve values (every one in `kinds`) whose render of `master`
    /// under `recipe` measures closest to `target`, or nil when no frame
    /// could be made.
    static func values(target: ImageStats, master: CIImage, recipe: Recipe) -> [AdjustmentKind: Double]? {
        let start = base(recipe)
        var search = Search(target: target, master: master, start: start, weights: toneWeights)
        guard search.cost(of: search.point) != nil else { return nil }

        // 1a. Coarse tone, one kind at a time, on the tone term.
        for kind in toneKinds { sweep(&search, kind) }

        // 1b. Coarse colour on the full cost: temperature with saturation,
        //     then tint and vibrance.
        search.reweigh(weights)
        let t0 = search.point[.temperature]!, s0 = search.point[.saturation]!
        for dt in [0] + coarseOffsets {
            for ds in [0] + coarseOffsets where dt != 0 || ds != 0 {
                var p = search.point
                p[.temperature] = clamp(.temperature, t0 + Double(dt))
                p[.saturation] = clamp(.saturation, s0 + Double(ds))
                search.consider(p)
            }
        }
        sweep(&search, .tint)
        sweep(&search, .vibrance)

        // 1c. Coarse grade, hue and saturation together per range.
        for pair in gradePairs {
            for sat in coarseGradeSats {
                for hue in coarseHues {
                    var p = search.point
                    p[pair.hue] = hue
                    p[pair.sat] = sat
                    search.consider(p)
                }
            }
        }

        // 2. Compass, halving down to one step, on the full cost.
        var multiple = compassStart
        while multiple >= 1 {
            var moved = false
            for kind in kinds {
                let isHue = gradePairs.contains { $0.hue == kind }
                // A hue under no saturation changes nothing: leave it.
                if isHue, let sat = gradePairs.first(where: { $0.hue == kind })?.sat, search.point[sat]! == 0 { continue }
                let delta = Double(isHue ? multiple * 2 : multiple) * step(of: kind)
                for sign in [1.0, -1.0] {
                    var p = search.point
                    let v = search.point[kind]! + sign * delta
                    p[kind] = isHue ? wrapHue(v) : clamp(kind, v)
                    if search.consider(p) { moved = true }
                }
            }
            if !moved { multiple /= 2 }
        }

        var out = search.point
        for pair in gradePairs where out[pair.sat]! == 0 { out[pair.hue] = pair.hue.neutral }
        // `+ 0` turns a -0 into 0 for the sidecar; rounding drops float noise.
        for kind in kinds {
            let s = step(of: kind)
            out[kind] = ((out[kind]! / s).rounded() * s) + 0
        }
        return out
    }

    /// One kind over `coarseOffsets` from where the search stands.
    private static func sweep(_ search: inout Search, _ kind: AdjustmentKind) {
        let here = search.point[kind]!
        for offset in coarseOffsets {
            var p = search.point
            p[kind] = clamp(kind, here + Double(offset) * step(of: kind))
            search.consider(p)
        }
    }

    private static func clamp(_ kind: AdjustmentKind, _ v: Double) -> Double {
        min(kind.range.upperBound, max(kind.range.lowerBound, v))
    }

    private static func wrapHue(_ v: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// The search state: the best point so far, its cost, and every cost
    /// measured (a point is rendered once).
    private struct Search {
        let target: ImageStats
        let master: CIImage
        let start: Recipe
        var weights: ImageStats.Weights
        var point: [AdjustmentKind: Double]
        var best = Double.infinity
        /// Every point measured, rendered once whatever the weights.
        var seen: [[Double]: ImageStats] = [:]

        init(target: ImageStats, master: CIImage, start: Recipe, weights: ImageStats.Weights) {
            self.target = target
            self.master = master
            self.start = start
            self.weights = weights
            point = Dictionary(uniqueKeysWithValues: LookMatch.kinds.map { ($0, start.value(of: $0)) })
        }

        /// The cost of `p`: the target's distance to its measured frame.
        mutating func cost(of p: [AdjustmentKind: Double]) -> Double? {
            let key = LookMatch.kinds.map { p[$0]! }
            var stats = seen[key]
            if stats == nil {
                stats = ImageStats.of(master: master, recipe: LookMatch.applying(p, to: start))
                seen[key] = stats
            }
            guard let stats else { return nil }
            let c = target.distance(to: stats, weights: weights)
            if p == point { best = c }
            return c
        }

        /// Switches the cost to `w`, re-costing the point it stands on.
        mutating func reweigh(_ w: ImageStats.Weights) {
            weights = w
            best = cost(of: point) ?? .infinity
        }

        /// Moves to `p` when it costs strictly less; true when it did.
        @discardableResult
        mutating func consider(_ p: [AdjustmentKind: Double]) -> Bool {
            guard let c = cost(of: p), c < best - 1e-12 else { return false }
            point = p
            best = c
            return true
        }
    }
}
