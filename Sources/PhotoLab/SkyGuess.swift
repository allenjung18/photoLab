import Foundation
import CoreGraphics

/// Select Sky (guess): a colour-and-position guess at the sky, with no model
/// and no network (D-473). Pure: an image in, a `MaskBitmap` over its whole
/// frame (the source frame, as every automatic mask) out, or nil when the
/// guess covers under `minCoverage` of the frame. `Library.selectAuto(.sky,
/// for:)` runs it on the photo's oriented decode, with the horizon Vision
/// finds (`AutoMaskDetector.horizon(in:)`) or none.
///
/// The guess, on a decode of at most `analysisLongSide` pixels:
/// 1. a per-pixel sky score (`score(r:g:b:)`): 1 for blue sky (hue
///    190-250 deg, saturation > 0.15, luminance > 0.35) or overcast (luminance
///    > 0.75, saturation < 0.12), else 0;
/// 2. times a position prior (`prior`) falling linearly from 1 at the top
///    edge to 0 at the horizon line, doubled and capped at 1 (`weight`), so
///    the upper part of the sky is full strength and it fades toward the
///    horizon;
/// 3. kept only where 4-connected to the top edge through pixels whose
///    weight is above `connectThreshold` (a blue car or a lake below a band of
///    trees is not sky);
/// 4. box-blurred by `blurFraction` of the long side, horizontally then
///    vertically.
enum SkyGuess {
    /// The long side of the analysis decode, in pixels (never upscaled).
    static let analysisLongSide = 512
    /// Under this fraction of the frame (the kept weight's sum over the pixel
    /// count, before the blur) the guess is nil: "No sky found".
    static let minCoverage = 0.02
    /// A pixel joins the sky region only above this weight.
    static let connectThreshold = 0.1
    /// The blur radius, as a fraction of the analysis long side.
    static let blurFraction = 0.01
    /// Where the horizon is taken to be when none is passed in: this far down
    /// the frame, level.
    static let defaultHorizonY = 0.7

    /// A straight horizon line. `centerY` is its height at the frame's
    /// horizontal centre, 0 the top edge and 1 the bottom; `angle` is its
    /// tilt in radians, counter-clockwise as seen (positive rises to the
    /// right), Vision's `VNHorizonObservation.angle` convention.
    struct Horizon: Equatable, Sendable {
        var centerY: Double
        var angle: Double

        static let level = Horizon(centerY: SkyGuess.defaultHorizonY, angle: 0)

        /// The line's height in pixels (top-left origin) at pixel column
        /// centre `x` of a `width` x `height` frame.
        func y(atColumn x: Double, width: Int, height: Int) -> Double {
            centerY * Double(height) - tan(angle) * (x - Double(width) / 2)
        }
    }

    /// The sky score of one pixel, its sRGB components in 0...1: 1 for blue
    /// sky or overcast, 0 otherwise. Hue and saturation are HSV's; luminance
    /// is Rec. 709 luma on the encoded values.
    static func score(r: Double, g: Double, b: Double) -> Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        let chroma = mx - mn
        let saturation = mx > 0 ? chroma / mx : 0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance > 0.75 && saturation < 0.12 { return 1 }
        guard chroma > 0, saturation > 0.15, luminance > 0.35 else { return 0 }
        var hue: Double
        if mx == r { hue = 60 * ((g - b) / chroma).truncatingRemainder(dividingBy: 6) }
        else if mx == g { hue = 60 * ((b - r) / chroma + 2) }
        else { hue = 60 * ((r - g) / chroma + 4) }
        if hue < 0 { hue += 360 }
        return (190...250).contains(hue) ? 1 : 0
    }

    /// The position prior at pixel (x, y) of a `width` x `height` frame: 1
    /// at the top edge falling linearly to 0 at `horizon` in that column, 0
    /// at and below it (and in a column whose horizon is at or above the top).
    static func prior(x: Int, y: Int, width: Int, height: Int, horizon: Horizon) -> Double {
        let hy = horizon.y(atColumn: Double(x) + 0.5, width: width, height: height)
        guard hy > 0 else { return 0 }
        return max(0, 1 - (Double(y) + 0.5) / hy)
    }

    /// The guess for `image` (row 0 the top), against `horizon` (nil: level
    /// at `defaultHorizonY`). Nil when it covers under `minCoverage`.
    static func mask(in image: CGImage, horizon: Horizon?) -> MaskBitmap? {
        guard let (rgba, w, h) = decode(image) else { return nil }
        return mask(rgba: rgba, width: w, height: h, horizon: horizon ?? .level)
    }

    /// The guess over an RGBA8 buffer (row 0 the top, 4 bytes a pixel).
    static func mask(rgba: [UInt8], width w: Int, height h: Int, horizon: Horizon) -> MaskBitmap? {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return nil }
        var weight = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let s = score(r: Double(rgba[i]) / 255, g: Double(rgba[i + 1]) / 255, b: Double(rgba[i + 2]) / 255)
                guard s > 0 else { continue }
                weight[y * w + x] = min(1, 2 * s * prior(x: x, y: y, width: w, height: h, horizon: horizon))
            }
        }
        let kept = connectedToTop(weight, width: w, height: h)
        let coverage = kept.reduce(0, +) / Double(w * h)
        guard coverage >= minCoverage else { return nil }
        let radius = max(1, Int((Double(max(w, h)) * blurFraction).rounded()))
        let blurred = boxBlur(kept, width: w, height: h, radius: radius)
        let gray = blurred.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        let bitmap = MaskBitmap(gray: gray, width: w, height: h)
        return bitmap.isBlank ? nil : bitmap
    }

    /// `weight` kept only where 4-connected to the top row through pixels
    /// above `connectThreshold`; every other pixel 0.
    static func connectedToTop(_ weight: [Double], width w: Int, height h: Int) -> [Double] {
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w where weight[x] > connectThreshold {
            seen[x] = true
            stack.append(x)
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                if !seen[j] && weight[j] > connectThreshold {
                    seen[j] = true
                    stack.append(j)
                }
            }
        }
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) where seen[i] { out[i] = weight[i] }
        return out
    }

    /// A box blur of `radius` pixels, rows then columns, edges clamped.
    static func boxBlur(_ src: [Double], width w: Int, height h: Int, radius r: Int) -> [Double] {
        func pass(_ a: [Double], count n: Int, lines: Int, index: (Int, Int) -> Int) -> [Double] {
            var out = a
            let span = Double(2 * r + 1)
            for line in 0..<lines {
                var sum = 0.0
                for k in -r...r { sum += a[index(line, min(max(k, 0), n - 1))] }
                for k in 0..<n {
                    out[index(line, k)] = sum / span
                    sum += a[index(line, min(k + r + 1, n - 1))] - a[index(line, max(k - r, 0))]
                }
            }
            return out
        }
        let rows = pass(src, count: w, lines: h) { line, k in line * w + k }
        return pass(rows, count: h, lines: w) { line, k in k * w + line }
    }

    /// `image` drawn into an sRGB RGBA8 buffer no longer than
    /// `analysisLongSide` on its long side, aspect kept, row 0 the top.
    static func decode(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let iw = image.width, ih = image.height
        guard iw > 0, ih > 0 else { return nil }
        let scale = min(1, Double(analysisLongSide) / Double(max(iw, ih)))
        let w = max(1, Int((Double(iw) * scale).rounded()))
        let h = max(1, Int((Double(ih) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (buffer, w, h) : nil
    }
}
