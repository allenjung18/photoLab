import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal

/// The size an export is written at: an exact long side in pixels, or a
/// percentage of the edited (cropped, rotated) size. Never upscales: a
/// target at or above the rendered size leaves the picture as rendered.
enum OutputSize: Hashable, Codable, Sendable {
    case longSide(Int)
    case percent(Int)

    /// The exact pixel size to write for a picture that renders at
    /// `current`, or nil when no downscale applies (keep the rendered size).
    func size(fitting current: CGSize) -> CGSize? {
        let long = max(current.width, current.height)
        let targetLong: CGFloat
        switch self {
        case .longSide(let n): targetLong = CGFloat(n)
        case .percent(let p): targetLong = (long * CGFloat(p) / 100).rounded()
        }
        guard targetLong >= 1, targetLong < long else { return nil }
        let s = targetLong / long
        return current.width >= current.height
            ? CGSize(width: targetLong, height: max(1, (current.height * s).rounded()))
            : CGSize(width: max(1, (current.width * s).rounded()), height: targetLong)
    }
}

/// The one render path. `apply` builds the Core Image chain for a recipe;
/// the loupe preview and the export both go through it, so they cannot drift
/// in color. Only the input differs: a downsampled master for the preview,
/// the full-resolution decode for an export. Every spatial parameter (blur
/// radius, sharpening radius, grain size, vignette radius) is a fraction of
/// the image's own size, so the preview and the export look the same.
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    let context: CIContext
    private let cubes = CubeCache()
    private static let cubeSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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

    /// The loupe's first frame while the preview master decodes: the file's
    /// embedded preview when it is worth showing (`ImageLoading.firstFrame`),
    /// else nil. Orientation applied, like the master, so the swap does not
    /// turn the photo.
    static func firstFrame(_ url: URL, minPixelSize: Int, masterPixelSize: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = ImageLoading.firstFrame(from: source, minPixelSize: minPixelSize, masterPixelSize: masterPixelSize)
        else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Full-resolution decode for export, orientation applied. The export
    /// leaves the decode to Core Image (lazy, at render time); the loupe's
    /// 1:1 master passes `decodeNow` so the whole file is decoded once, here,
    /// off the main thread, and every region render reads the cached pixels.
    /// The same decoder either way, so a 1:1 region and the export start from
    /// the same pixels.
    static func fullResolution(_ url: URL, decodeNow: Bool = false) -> CIImage? {
        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if decodeNow { options[.cacheImmediately] = true }
        return CIImage(contentsOf: url, options: options)
    }

    // MARK: The chain

    /// Applies `recipe` to `image` in `AdjustmentKind.allCases` order (the
    /// recipe's own order does not matter). Disabled and neutral entries are
    /// skipped, so the neutral recipe is the identity. Grouped kinds (crop,
    /// tone, HSL) are one stage each, applied where their first member sits.
    /// The recipe's masks (local adjustments) are one stage too, just before
    /// `maskStageBefore`: after HSL, before detail and effects, so clarity,
    /// sharpening, grain and the vignette sit on top of local edits. Their
    /// geometry is drawn over `image`'s extent (the source frame) and goes
    /// through the recipe's rotate and crop (`MaskRender.compose`).
    func apply(_ recipe: Recipe, to image: CIImage) -> CIImage {
        var out = image
        var done: Set<AdjustmentKind.Group> = []
        for kind in AdjustmentKind.allCases {
            if kind == Self.maskStageBefore, !recipe.masks.isEmpty {
                out = MaskRender.compose(recipe, sourceExtent: image.extent, on: out, renderer: self)
            }
            if let group = kind.group {
                guard !done.contains(group) else { continue }
                done.insert(group)
                if AdjustmentKind.members(of: group).contains(where: { !recipe[$0].isNoop }) {
                    out = groupStage(group, recipe, on: out)
                }
            } else {
                let a = recipe[kind]
                if !a.isNoop { out = Self.stage(a, on: out) }
            }
        }
        return out
    }

    /// The first kind applied after the mask stage (the head of Detail).
    static let maskStageBefore: AdjustmentKind = .clarity

    private func groupStage(_ group: AdjustmentKind.Group, _ recipe: Recipe, on image: CIImage) -> CIImage {
        let v = { (k: AdjustmentKind) in recipe.effective(k) / 100 }
        switch group {
        case .crop:
            let e = image.extent
            let rect = CGRect(x: e.minX + e.width * v(.cropLeft),
                              y: e.minY + e.height * v(.cropBottom),
                              width: e.width * (1 - v(.cropLeft) - v(.cropRight)),
                              height: e.height * (1 - v(.cropTop) - v(.cropBottom))).integral
            guard rect.width >= 1, rect.height >= 1 else { return image }
            return image.cropped(to: rect)
        case .tone:
            let curve = AdjustmentKind.members(of: .tone).filter { $0.curveX != nil }.map(v)
            let key = [v(.highlights), v(.shadows), v(.whites), v(.blacks)] + curve
            let data = cubes.cube(for: [0] + key) {
                ColorCubes.toneCube(ColorCubes.toneLUT(
                    highlights: key[0], shadows: key[1], whites: key[2], blacks: key[3], curve: curve))
            }
            return Self.cube(data, on: image)
        case .hsl:
            let bands = AdjustmentKind.HSLBand.allCases
            let hue = bands.map { v(.hsl(.hue, $0)) }
            let sat = bands.map { v(.hsl(.saturation, $0)) }
            let lum = bands.map { v(.hsl(.luminance, $0)) }
            let data = cubes.cube(for: [1] + hue + sat + lum) {
                ColorCubes.hslCube(hue: hue, sat: sat, lum: lum)
            }
            return Self.cube(data, on: image)
        }
    }

    private static func cube(_ data: Data, on image: CIImage) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(ColorCubes.dimension)
        f.cubeData = data
        f.colorSpace = cubeSpace
        return f.outputImage ?? image
    }

    private static func stage(_ a: Adjustment, on image: CIImage) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        switch a.kind {
        case .rotate:
            // Positive = clockwise on screen; the result is the largest
            // same-aspect rectangle inside the rotated frame (no empty corners),
            // inset by one pixel on every side: the exact inscribed rect
            // touches the rotated frame's antialiased edge at two corners, and
            // that edge is a dark line a pixel wide along the output's border.

            let theta = a.value * .pi / 180
            let e = image.extent
            let c = CGPoint(x: e.midX, y: e.midY)
            var t = CGAffineTransform(translationX: c.x, y: c.y)
            t = t.rotated(by: -theta)
            t = t.translatedBy(x: -c.x, y: -c.y)
            let rotated = image.transformed(by: t)
            let cs = abs(cos(theta)), sn = abs(sin(theta))
            let s = min(e.width / (e.width * cs + e.height * sn), e.height / (e.width * sn + e.height * cs))
            let w = max(1, floor(e.width * s) - 2), h = max(1, floor(e.height * s) - 2)

            let crop = CGRect(x: (c.x - w / 2).rounded(), y: (c.y - h / 2).rounded(), width: w, height: h)
            return rotated.cropped(to: crop)
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
        case .clarity:
            // Local contrast in gamma space: an unsharp mask with a radius of
            // 2% of the long side; negative values mix toward the blur (soften).
            let k = a.value / 100
            let radius = Float(max(1, longest * 0.02))
            let gamma = CIFilter.linearToSRGBToneCurve()
            gamma.inputImage = image
            guard let g = gamma.outputImage else { return image }
            let result: CIImage?
            if k > 0 {
                let usm = CIFilter.unsharpMask()
                usm.inputImage = g
                usm.radius = radius
                usm.intensity = Float(k * 0.5)
                result = usm.outputImage
            } else {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = g.clampedToExtent()
                blur.radius = radius
                let mix = CIFilter.mix()
                mix.inputImage = g
                mix.backgroundImage = blur.outputImage
                mix.amount = Float(1 + k * 0.6)
                result = mix.outputImage
            }
            let linear = CIFilter.sRGBToneCurveToLinear()
            linear.inputImage = result?.cropped(to: image.extent)
            return linear.outputImage ?? image
        case .sharpening:
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(a.value / 100 * 1.5)
            f.radius = Float(max(1, longest * 0.0007))
            return f.outputImage ?? image
        case .grain:
            // Multiplicative monochrome noise, ±20% at 100: the grain cell is
            // 1/1500 of the long side and the noise is sampled by frame
            // position, so preview and export show the same grain.
            guard let raw = CIFilter.randomGenerator().outputImage else { return image }
            // The generator's RGB is premultiplied by its random alpha (skewed
            // dark); the alpha itself is uniform on 0…1, so the grain is drawn
            // from it and the factor averages exactly 1.
            let amp = CGFloat(a.value / 100 * 0.4)
            let cell = max(1, longest / 1500)
            let e = image.extent
            let mono = CIFilter.colorMatrix()
            mono.inputImage = raw
            mono.rVector = CIVector(x: 0, y: 0, z: 0, w: amp)
            mono.gVector = CIVector(x: 0, y: 0, z: 0, w: amp)
            mono.bVector = CIVector(x: 0, y: 0, z: 0, w: amp)
            mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            mono.biasVector = CIVector(x: 1 - amp / 2, y: 1 - amp / 2, z: 1 - amp / 2, w: 1)
            guard let grain = mono.outputImage?.samplingNearest()
                .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY).scaledBy(x: cell, y: cell))
                .cropped(to: e) else { return image }
            let f = CIFilter.multiplyCompositing()
            f.inputImage = grain
            f.backgroundImage = image
            return f.outputImage ?? image
        case .vignette:
            // -100 darkens the corners, +100 brightens them.
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            let e = image.extent
            f.center = CGPoint(x: e.midX, y: e.midY)
            f.radius = Float(hypot(e.width, e.height) * 0.45)
            f.intensity = Float(-a.value / 100)
            f.falloff = 0.5
            return f.outputImage?.cropped(to: e) ?? image
        case .cropLeft, .cropTop, .cropRight, .cropBottom,
             .highlights, .shadows, .whites, .blacks,
             .curveBlacks, .curveShadows, .curveMidtones, .curveHighlights, .curveWhites,
             .hueRed, .hueOrange, .hueYellow, .hueGreen, .hueAqua, .hueBlue, .huePurple, .hueMagenta,
             .satRed, .satOrange, .satYellow, .satGreen, .satAqua, .satBlue, .satPurple, .satMagenta,
             .lumRed, .lumOrange, .lumYellow, .lumGreen, .lumAqua, .lumBlue, .lumPurple, .lumMagenta:
            // Grouped kinds are rendered by `groupStage`.
            return image
        }
    }

    // MARK: Output

    struct Result {
        let image: CGImage
        /// Wall time of the step (building the chain, including any cube,
        /// plus the Core Image render and readback), ms.
        let milliseconds: Double
        /// The size of the whole rendered frame (after crop and rotate, before
        /// any `resize`), whatever part of it `image` holds.
        var frameSize: CGSize = .zero
        /// With a `region`, the pixels `image` holds: a rect in the rendered
        /// frame, origin top-left, in whole pixels. Nil for a whole frame.
        var region: CGRect?
    }

    /// A window onto the rendered frame at one image pixel per output pixel:
    /// the loupe's 1:1 view. `center` is normalised in the rendered frame
    /// (after crop and rotate), 0…1 on each axis, origin top-left; `size` is
    /// the window in pixels.
    struct Region: Equatable, Sendable {
        var center: CGPoint
        var size: CGSize

        /// The pixels shown for a frame of `frame` size: `size` (no larger
        /// than the frame) around `center`, slid back inside the frame where
        /// it would cross an edge, so a centre near a corner shows the corner
        /// rather than empty space. Whole pixels, origin top-left.
        func rect(in frame: CGSize) -> CGRect {
            let fw = frame.width.rounded(.down), fh = frame.height.rounded(.down)
            let w = min(max(1, size.width.rounded()), fw)
            let h = min(max(1, size.height.rounded()), fh)
            let cx = min(max(center.x, 0), 1), cy = min(max(center.y, 0), 1)
            let x = min(max((cx * fw - w / 2).rounded(), 0), fw - w)
            let y = min(max((cy * fh - h / 2).rounded(), 0), fh - h)
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// Renders `recipe` over `source`, scaled to fit `maxPixelSize` (never
    /// upscaled; nil renders at source size), to an 8-bit CGImage in the
    /// source's color space. `resize` sizes the OUTPUT (after the crop) to an
    /// exact long side or percentage, never upscaling: that is the export's
    /// resize, done once at the end of the one chain. Synchronous; call off
    /// the main thread.
    ///
    /// `region` cuts the OUTPUT to a window of the rendered frame
    /// (`Region.rect(in:)`), the loupe's 1:1 view: the chain is built over the
    /// whole source exactly as for the whole frame, and only the pixels read
    /// back differ. Never render a cropped input instead: every spatial
    /// parameter is a fraction of the image's own size, so a cropped input
    /// would change clarity, sharpening, grain and vignette. Core Image
    /// evaluates only what the window needs, so a region of a 24 MP source
    /// costs about the window's pixels. Not combined with `resize`.
    ///
    /// `watermark` is the export's text mark (`ExportOptions.watermark`),
    /// drawn as the LAST stage, after `resize`, inside the output rect
    /// (`Watermark.composite(over:in:)`), so its size follows the written
    /// file's short side. Only `Exporter.write` passes one; the loupe, the
    /// preset strip, thumbnails and Save to Photos never do. Nil or blank
    /// text leaves the output as it was; ignored with a `region`.
    func render(_ source: CIImage, recipe: Recipe, maxPixelSize: Int? = nil, resize: OutputSize? = nil,
                region: Region? = nil, watermark: Watermark? = nil) -> Result? {
        let t0 = DispatchTime.now().uptimeNanoseconds
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
        var rect = image.extent.integral
        guard !rect.isEmpty else { return nil }
        let frameSize = rect.size
        var shownRegion: CGRect?
        if let region {
            // Top-left window to Core Image's bottom-left coordinates.
            let r = region.rect(in: rect.size)
            shownRegion = r
            rect = CGRect(x: rect.minX + r.minX, y: rect.maxY - r.maxY, width: r.width, height: r.height)
        } else if let target = resize?.size(fitting: rect.size) {
            // Lanczos down to the exact target. The edges are clamped so the
            // integer rect below never reads outside the picture, and the
            // CGImage is cut to exactly `target` pixels.
            let s = max(target.width, target.height) / max(rect.width, rect.height)
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .clampedToExtent()
            lanczos.scale = Float(s)
            lanczos.aspectRatio = 1
            if let scaled = lanczos.outputImage {
                image = scaled
                rect = CGRect(origin: .zero, size: target)
            }
        }
        if region == nil, let watermark, !watermark.isBlank {
            image = watermark.composite(over: image, in: rect)
        }
        let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) else {
            return nil
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        return Result(image: cg, milliseconds: Double(t1 - t0) / 1_000_000, frameSize: frameSize, region: shownRegion)
    }
}
