import CoreImage
import CoreImage.CIFilterBuiltins

/// The two noise-reduction stages (`AdjustmentKind.luminanceNoise`,
/// `.colorNoise`), apart from `Renderer` so their maths and their one Metal
/// kernel sit together. Both keep values outside 0…1 (a Display P3 red, a
/// highlight above white): the working space is extended linear sRGB, and
/// exposure or the tone stages after them may still bring such a value back.
enum NoiseReduction {
    /// The colour blur's radius at 100, as a share of the long side.
    static let colorRadiusShare = 0.005
    /// The radius the colour blur runs at on its downsized copy: the copy is
    /// scaled so the blur is this many of its pixels, so the round trip's
    /// pixel pitch is a fixed share of the frame too and a preview and an
    /// export match.
    static let smallRadius = 2.5

    /// Colour noise at `k` (0…1) over `image`: a downsized copy blurred
    /// (`colorRadiusShare` of the long side, whatever `k`), scaled back, and
    /// its colour mixed in by `k` over the original's luminance
    /// (`chromaMix`). Unclamped, so a wide-gamut colour or a highlight
    /// survives; the strength rises evenly with the slider.
    static func color(_ image: CIImage, k: Double) -> CIImage {
        guard let kernel = kernels.chroma, k > 0 else { return image }
        let e = image.extent
        let radius = max(1, max(e.width, e.height) * colorRadiusShare)
        let q = min(1, smallRadius / radius)
        let small = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: q, y: q))
            .cropped(to: CGRect(x: 0, y: 0, width: e.width * q, height: e.height * q))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = small.clampedToExtent()
        blur.radius = Float(radius * q)
        guard let blurred = blur.outputImage else { return image }
        let back = blurred.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
        return kernel.apply(extent: e, arguments: [image, back, Float(k)]) ?? image
    }

    /// Luminance noise at `k` (0…1): `CINoiseReduction` on gamma-encoded
    /// values (its level is a threshold, and in linear values the shadows'
    /// noise is so small that any level smeared them before exposure lifts
    /// them), level 0.1·k, edge sharpness 0.4·k (at a low level a fixed one
    /// only sharpened the noise). One input: a dissolve from the original
    /// made Core Image compute the chain before it twice.
    static func luminance(_ image: CIImage, k: Double) -> CIImage {
        guard k > 0 else { return image }
        let toGamma = CIFilter.linearToSRGBToneCurve()
        toGamma.inputImage = image.clampedToExtent()
        let f = CIFilter.noiseReduction()
        f.inputImage = toGamma.outputImage
        f.noiseLevel = Float(0.1 * k)
        f.sharpness = Float(0.4 * k)
        let toLinear = CIFilter.sRGBToneCurveToLinear()
        toLinear.inputImage = f.outputImage
        return toLinear.outputImage?.cropped(to: image.extent) ?? image
    }

    private struct Kernels {
        let chroma: CIColorKernel?
        init() {
            let all = (try? CIKernel.kernels(withMetalString: NoiseReduction.source)) ?? []
            chroma = all.first { $0.name == "chromaMix" } as? CIColorKernel
        }
    }

    private static let kernels = Kernels()

    /// True when the colour kernel compiled (without it colour noise is a no-op).
    static var isAvailable: Bool { kernels.chroma != nil }

    static let source = """
    #include <CoreImage/CoreImage.h>
    extern "C" {
    namespace coreimage {
    // The blurred colour over the original's luminance (Rec. 709 weights,
    // linear), mixed in by k. No clamp: values outside 0...1 pass through.
    [[stitchable]] float4 chromaMix(sample_t px, sample_t blurred, float k) {
        float3 w = float3(0.2126, 0.7152, 0.0722);
        float3 chroma = blurred.rgb + (dot(px.rgb, w) - dot(blurred.rgb, w));
        return float4(mix(px.rgb, chroma, k), px.a);
    }
    }
    }
    """
}
