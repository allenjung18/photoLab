import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Local adjustments in the one chain: each mask's own adjustments are run
/// through `Renderer.apply` (the global chain, limited to `LocalMask.kinds`)
/// and composed over the picture with `CIBlendWithMask`, weighted by the
/// mask's shape (`MaskMath` states the weights; a brush is rastered on the
/// CPU by `BrushRaster`, cached in `BrushRasterCache`). The mask image is drawn over
/// the chain's INPUT extent (the scaled source) in the source frame and then
/// run through the recipe's own geometry stages (rotate, crop), so it lands
/// on the pixels it was drawn over at any crop, rotate, preview size or 1:1
/// window, with no second copy of the geometry maths.
enum MaskRender {
    /// The kinds the mask image goes through before it meets the picture:
    /// the recipe's geometry (`AdjustmentKind.geometryKinds`).
    static var geometryKinds: [AdjustmentKind] { AdjustmentKind.geometryKinds }

    /// Whether `mask` takes part in a render: enabled, some adjustment that
    /// is not a no-op, and a shape that draws something (a brush with no
    /// strokes is skipped).
    static func renders(_ mask: LocalMask) -> Bool {
        if mask.isNoop { return false }
        if case .brush(let strokes) = mask.shape, strokes.isEmpty { return false }
        return true
    }

    /// The shape's mask before geometry: white (weight 1) to black (0) over
    /// `extent` (Core Image coordinates, origin bottom-left), cropped to it.
    /// Nil for a degenerate shape (zero-length gradient, zero radius) or a
    /// brush with no strokes. Not inverted; `compose` swaps the two images
    /// for that. A brush is rastered at `extent`'s size (long side capped at
    /// `BrushRaster.maxLongSide`) through `brushes`, and scaled by Core Image
    /// to the extent beyond the cap.
    static func image(for shape: MaskShape, over extent: CGRect,
                      brushes: BrushRasterCache = .shared) -> CIImage? {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        let long = max(extent.width, extent.height)
        // A source-frame point (top-left, fractions) in Core Image space.
        func place(_ p: MaskPoint) -> CGPoint {
            CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.maxY - CGFloat(p.y) * extent.height)
        }
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)
        switch shape {
        case .linear(let start, let end):
            let a = place(start), b = place(end)
            guard a != b else { return nil }
            let f = CIFilter.linearGradient()
            f.point0 = a
            f.point1 = b
            f.color0 = white
            f.color1 = black
            return f.outputImage?.cropped(to: extent)
        case .radial(let center, let radii, let angle, let feather):
            guard radii.x > 0, radii.y > 0 else { return nil }
            // A unit circle (inner ring at 1 - feather) scaled to the radii,
            // turned clockwise on screen (negative in Core Image's y-up
            // space) and moved to the centre.
            let f = CIFilter.radialGradient()
            f.center = .zero
            f.radius0 = Float(1 - min(max(feather, 0), 1))
            f.radius1 = 1
            f.color0 = white
            f.color1 = black
            let c = place(center)
            let t = CGAffineTransform(scaleX: CGFloat(radii.x) * long, y: CGFloat(radii.y) * long)
                .concatenating(CGAffineTransform(rotationAngle: -CGFloat(angle) * .pi / 180))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            return f.outputImage?.transformed(by: t).cropped(to: extent)
        case .brush(let strokes):
            guard !strokes.isEmpty else { return nil }
            let size = BrushRaster.rasterSize(for: extent.size)
            let raster = brushes.image(for: strokes, width: size.width, height: size.height)
            // Raster pixel edges onto the extent's edges (so pixel centres
            // are the source points the raster sampled); edges clamped so the
            // scale does not fade the border.
            let t = CGAffineTransform(scaleX: extent.width / CGFloat(size.width), y: extent.height / CGFloat(size.height))
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
            return raster.clampedToExtent().transformed(by: t).cropped(to: extent)
        }
    }

    /// The mask for `mask` where the picture is after the geometry stages:
    /// drawn over `sourceExtent` and run through `recipe`'s rotate and crop
    /// by `renderer`.
    static func placedImage(for mask: LocalMask, recipe: Recipe, sourceExtent: CGRect,
                            renderer: Renderer) -> CIImage? {
        guard let drawn = image(for: mask.shape, over: sourceExtent) else { return nil }
        let geometry = Recipe(adjustments: geometryKinds.map { recipe[$0] })
        return renderer.apply(geometry, to: drawn)
    }

    /// The mask stage: every mask of `recipe` that renders, in list order,
    /// each applied to the picture so far through its own adjustments and
    /// blended by its placed mask (inverted: the two images swap, weight
    /// 1 - w). The identity when no mask renders.
    static func compose(_ recipe: Recipe, sourceExtent: CGRect, on image: CIImage,
                        renderer: Renderer) -> CIImage {
        var out = image
        for mask in recipe.masks where renders(mask) {
            guard let placed = placedImage(for: mask, recipe: recipe, sourceExtent: sourceExtent,
                                           renderer: renderer) else { continue }
            let adjusted = renderer.apply(mask.recipe, to: out)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = mask.inverted ? out : adjusted
            blend.backgroundImage = mask.inverted ? adjusted : out
            blend.maskImage = placed
            if let blended = blend.outputImage { out = blended.cropped(to: image.extent) }
        }
        return out
    }
}
