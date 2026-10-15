import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal

/// The one render path. `apply` builds the Core Image chain for a recipe;
/// the loupe preview and the export both go through it, so they cannot drift
/// in color. Only the input differs: a downsampled master for the preview,
/// the full-resolution decode for an export.
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    let context: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [
                .name: "PhotoLab",
                .cacheIntermediates: false,
            ])
        } else {
            context = CIContext(options: [.name: "PhotoLab"])
        }
    }

    // MARK: Inputs

    /// Preview master: an ImageIO downsample (fast, orientation-aware, reads
    /// RAW and HEIC) wrapped as a CIImage. Chunk 1's loupe decode, reused.
    static func previewMaster(_ url: URL, maxPixelSize: Int) -> CIImage? {
        guard let cg = ImageLoading.downsampledCGImage(url, maxPixelSize: maxPixelSize) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Full-resolution decode for export, orientation applied.
    static func fullResolution(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    // MARK: The chain

    /// Applies `recipe` to `image` in recipe order. Disabled and neutral
    /// entries are skipped, so the neutral recipe is the identity.
    func apply(_ recipe: Recipe, to image: CIImage) -> CIImage {
        var out = image
        for a in recipe.adjustments where !a.isNoop {
            out = Self.stage(a, on: out)
        }
        return out
    }

    private static func stage(_ a: Adjustment, on image: CIImage) -> CIImage {
        switch a.kind {
        case .exposure:
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(a.value)
            return f.outputImage ?? image
        case .contrast:
            // -100…100 → 0…2 around 1.
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + a.value / 100)
            f.saturation = 1
            f.brightness = 0
            return f.outputImage ?? image
        case .temperature:
            // CITemperatureAndTint maps the source neutral onto the target:
            // a LOWER target (3500 K at +100) renders the image warmer, the
            // way Lightroom's slider reads. Direction is pinned by a test.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - 30 * a.value, y: 0)
            return f.outputImage ?? image
        case .tint:
            // +100 → magenta, -100 → green (Lightroom's direction); the
            // filter's tint axis runs the other way, hence the minus.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500, y: -a.value)
            return f.outputImage ?? image
        case .vibrance:
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(a.value / 100)
            return f.outputImage ?? image
        case .saturation:
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = Float(1 + a.value / 100)
            f.contrast = 1
            f.brightness = 0
            return f.outputImage ?? image
        }
    }

    // MARK: Output

    struct Result {
        let image: CGImage
        /// Wall time of the Core Image render (filter graph + readback), ms.
        let milliseconds: Double
    }

    /// Renders `recipe` over `source`, scaled to fit `maxPixelSize` (never
    /// upscaled; nil renders at source size), to an 8-bit CGImage in the
    /// source's color space. Synchronous; call off the main thread.
    func render(_ source: CIImage, recipe: Recipe, maxPixelSize: Int? = nil) -> Result? {
        var image = source
        let extent = source.extent
        if let maxPixelSize {
            let longest = max(extent.width, extent.height)
            if longest > CGFloat(maxPixelSize) {
                let s = CGFloat(maxPixelSize) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
        }
        image = apply(recipe, to: image)
        let rect = image.extent.integral
        guard !rect.isEmpty else { return nil }
        let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) else {
            return nil
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        return Result(image: cg, milliseconds: Double(t1 - t0) / 1_000_000)
    }
}
