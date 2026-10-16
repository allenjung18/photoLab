import Foundation
import CoreGraphics
import CoreImage
import Accelerate

/// What a frame looks like, in a handful of numbers: the shared measurement
/// a look-matching solver minimises (`distance(to:weights:)`) and that Auto
/// in my style reads. Measured from one 8-bit frame (`measure(_:)`) through
/// `RGBA8Pixels`, the bytes `Histogram` counts, so every value is of the
/// displayed sRGB-encoded frame, on a 0…1 scale:
/// - `lumaPercentiles`: Rec. 709 luma (as `Histogram.luminance`) at each of
///   `percentileLevels`, read by `AutoTone.percentile` from 256 bins;
/// - `mean`: the mean red, green and blue;
/// - `rangeMeans`: the mean colour of the pixels in each
///   `AdjustmentKind.GradeRange` (`range(ofLuma:)`: luma below
///   `shadowCeiling`, above `highlightFloor`, else midtone), nil for a range
///   no pixel falls in;
/// - `saturation`: mean HSV saturation, (max − min) / max per pixel, 0 on
///   black; `chroma`: mean max − min.
///
/// Pure and synchronous; no UI and no state.
struct ImageStats: Sendable, Equatable, Codable {
    /// The luma quantiles measured, in the order of `lumaPercentiles`.
    static let percentileLevels: [Double] = [0.005, 0.05, 0.25, 0.5, 0.75, 0.95, 0.995]
    /// Luma below this is a shadow pixel; above `highlightFloor` a highlight.
    static let shadowCeiling = 1.0 / 3
    static let highlightFloor = 2.0 / 3
    /// Rec. 709 luma weights (`Histogram.compute`'s matrix, 2126 / 7152 /
    /// 722 out of 10 000).
    static let lumaWeights = (red: 0.2126, green: 0.7152, blue: 0.0722)

    /// A mean colour, sRGB-encoded, 0…1 per channel.
    struct RGB: Sendable, Equatable, Codable {
        var red: Double
        var green: Double
        var blue: Double

        func distance(to other: RGB) -> Double {
            let dr = red - other.red, dg = green - other.green, db = blue - other.blue
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }

    /// Luma at each of `percentileLevels`, 0…1.
    let lumaPercentiles: [Double]
    let mean: RGB
    /// Mean colour per grade range, in `GradeRange.allCases` order (shadow,
    /// midtone, highlight); nil where the range has no pixels.
    let rangeMeans: [RGB?]
    let saturation: Double
    let chroma: Double
    let pixelCount: Int

    /// The mean colour of `range`'s pixels, nil when it has none.
    func mean(in range: AdjustmentKind.GradeRange) -> RGB? {
        rangeMeans[AdjustmentKind.GradeRange.allCases.firstIndex(of: range)!]
    }

    /// Luma at quantile `q`, one of `percentileLevels`.
    func luma(at q: Double) -> Double? {
        Self.percentileLevels.firstIndex(of: q).map { lumaPercentiles[$0] }
    }

    /// The grade range a luma value (0…1) falls in.
    static func range(ofLuma y: Double) -> AdjustmentKind.GradeRange {
        if y < shadowCeiling { return .shadow }
        if y > highlightFloor { return .highlight }
        return .midtone
    }

    // MARK: Distance

    /// How much each part of `distance(to:weights:)` counts.
    struct Weights: Sendable, Equatable, Codable {
        /// Mean absolute difference of the luma percentiles.
        var tone: Double
        /// Mean RGB distance of the overall mean and the range means both
        /// frames have (a range only one frame has adds `missingRange`).
        var colour: Double
        /// Absolute difference of mean saturation plus that of mean chroma.
        var saturation: Double

        static let standard = Weights(tone: 1, colour: 1, saturation: 0.5)
    }

    /// The colour term a range present in one frame and absent in the other
    /// adds: the farthest two colours can be apart (black to white).
    static let missingRange = 3.0.squareRoot()

    /// A non-negative distance, zero to itself and symmetric, for a solver
    /// to minimise: the weighted sum of the tone, colour and saturation terms.
    func distance(to other: ImageStats, weights: Weights = .standard) -> Double {
        var tone = 0.0
        let n = min(lumaPercentiles.count, other.lumaPercentiles.count)
        for i in 0..<n { tone += abs(lumaPercentiles[i] - other.lumaPercentiles[i]) }
        if n > 0 { tone /= Double(n) }

        var colour = mean.distance(to: other.mean)
        var terms = 1.0
        for (a, b) in zip(rangeMeans, other.rangeMeans) {
            switch (a, b) {
            case let (a?, b?): colour += a.distance(to: b); terms += 1
            case (nil, nil): break
            default: colour += Self.missingRange; terms += 1
            }
        }
        colour /= terms

        let sat = abs(saturation - other.saturation) + abs(chroma - other.chroma)
        return weights.tone * tone + weights.colour * colour + weights.saturation * sat
    }

    // MARK: Measurement

    /// The stats of `master` under `recipe` exactly as it renders: the
    /// recipe through `Renderer.shared` at `AutoTone.analysisPixelSize` (as
    /// `AutoTone.histogram(of:recipe:)`, without its neutral base), then
    /// `measure(_:)`. Synchronous; call off the main thread.
    static func of(master: CIImage, recipe: Recipe) -> ImageStats? {
        guard let frame = Renderer.shared.render(master, recipe: recipe, maxPixelSize: AutoTone.analysisPixelSize)
        else { return nil }
        return measure(frame.image)
    }

    /// The stats of one frame. Any CGImage is accepted (one not 8-bit RGBA
    /// in memory is redrawn once, as for `Histogram`); alpha is ignored.
    /// Vectorised (vDSP over Double planes, one vImage histogram for the
    /// luma bins), a couple of milliseconds at `AutoTone.analysisPixelSize`.
    static func measure(_ frame: CGImage) -> ImageStats? {
        guard let pixels = RGBA8Pixels(frame) else { return nil }
        let w = pixels.width, h = pixels.height
        let count = w * h
        guard count > 0, let base = CFDataGetBytePtr(pixels.data) else { return nil }
        let n = vDSP_Length(count)

        // The three channels as Double planes, 0…255.
        var r = [Double](repeating: 0, count: count)
        var g = [Double](repeating: 0, count: count)
        var b = [Double](repeating: 0, count: count)
        for y in 0..<h {
            let row = base + y * pixels.bytesPerRow
            let o = y * w
            r.withUnsafeMutableBufferPointer { vDSP_vfltu8D(row, 4, $0.baseAddress! + o, 1, vDSP_Length(w)) }
            g.withUnsafeMutableBufferPointer { vDSP_vfltu8D(row + 1, 4, $0.baseAddress! + o, 1, vDSP_Length(w)) }
            b.withUnsafeMutableBufferPointer { vDSP_vfltu8D(row + 2, 4, $0.baseAddress! + o, 1, vDSP_Length(w)) }
        }

        // Luma, Rec. 709.
        var luma = [Double](repeating: 0, count: count)
        var wr = lumaWeights.red, wg = lumaWeights.green, wb = lumaWeights.blue
        vDSP_vsmulD(r, 1, &wr, &luma, 1, n)
        vDSP_vsmaD(g, 1, &wg, luma, 1, &luma, 1, n)
        vDSP_vsmaD(b, 1, &wb, luma, 1, &luma, 1, n)

        // 256 luma bins: round to the nearest code, count with vImage.
        var half = 0.5
        var rounded = [Double](repeating: 0, count: count)
        vDSP_vsaddD(luma, 1, &half, &rounded, 1, n)
        var codes = [UInt8](repeating: 0, count: count)
        vDSP_vfixu8D(rounded, 1, &codes, 1, n)
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        let histOK = codes.withUnsafeMutableBytes { raw -> Bool in
            var buf = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            return hist.withUnsafeMutableBufferPointer {
                vImageHistogramCalculation_Planar8(&buf, $0.baseAddress!, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard histOK else { return nil }
        let bins = hist.map { Int($0) }

        // Means.
        var sr = 0.0, sg = 0.0, sb = 0.0
        vDSP_sveD(r, 1, &sr, n); vDSP_sveD(g, 1, &sg, n); vDSP_sveD(b, 1, &sb, n)

        // Chroma (max − min) and HSV saturation (chroma / max, 0 on black).
        var mx = [Double](repeating: 0, count: count)
        var mn = [Double](repeating: 0, count: count)
        vDSP_vmaxD(r, 1, g, 1, &mx, 1, n); vDSP_vmaxD(mx, 1, b, 1, &mx, 1, n)
        vDSP_vminD(r, 1, g, 1, &mn, 1, n); vDSP_vminD(mn, 1, b, 1, &mn, 1, n)
        var chroma = [Double](repeating: 0, count: count)
        vDSP_vsubD(mn, 1, mx, 1, &chroma, 1, n)  // mx − mn
        var chromaSum = 0.0
        vDSP_sveD(chroma, 1, &chromaSum, n)
        var tiny = 1e-9
        vDSP_vsaddD(mx, 1, &tiny, &mx, 1, n)
        var sat = [Double](repeating: 0, count: count)
        vDSP_vdivD(mx, 1, chroma, 1, &sat, 1, n)  // chroma / (mx + tiny)
        var satSum = 0.0
        vDSP_sveD(sat, 1, &satSum, n)

        // Range masks, 0 or 1 per pixel: ceil(t − luma) clipped to 0…1 is 1
        // exactly when luma < t (the shadows), ceil(luma − t) when luma > t.
        var zero = 0.0, one = 1.0
        func mask(_ sign: Double, _ t: Double) -> [Double] {
            var m = [Double](repeating: 0, count: count)
            var s = sign, bias = -sign * t * 255
            vDSP_vsmsaD(luma, 1, &s, &bias, &m, 1, n)
            var c = Int32(count)
            m.withUnsafeMutableBufferPointer { vvceil($0.baseAddress!, $0.baseAddress!, &c) }
            vDSP_vclipD(m, 1, &zero, &one, &m, 1, n)
            return m
        }
        let lows = mask(-1, shadowCeiling)
        let highs = mask(1, highlightFloor)
        func sums(_ m: [Double]) -> (r: Double, g: Double, b: Double, n: Double) {
            var x = 0.0, y = 0.0, z = 0.0, k = 0.0
            vDSP_dotprD(m, 1, r, 1, &x, n); vDSP_dotprD(m, 1, g, 1, &y, n); vDSP_dotprD(m, 1, b, 1, &z, n)
            vDSP_sveD(m, 1, &k, n)
            return (x, y, z, k)
        }
        let lo = sums(lows), hi = sums(highs)
        let midN = Double(count) - lo.n - hi.n
        let mid = (r: sr - lo.r - hi.r, g: sg - lo.g - hi.g, b: sb - lo.b - hi.b, n: midN)
        let ranges: [RGB?] = [lo, mid, hi].map { s in
            guard s.n > 0.5 else { return nil }
            let m = s.n * 255
            return RGB(red: s.r / m, green: s.g / m, blue: s.b / m)
        }

        let total = Double(count)
        let percentiles = percentileLevels.map { AutoTone.percentile(bins, $0) }
        let mean = RGB(red: sr / total / 255, green: sg / total / 255, blue: sb / total / 255)
        return ImageStats(lumaPercentiles: percentiles, mean: mean, rangeMeans: ranges,
                          saturation: satSum / total, chroma: chromaSum / total / 255, pixelCount: count)
    }
}
