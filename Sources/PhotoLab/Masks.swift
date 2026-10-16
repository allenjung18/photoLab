import Foundation

// MARK: - Local adjustments: the data model

/// A point in the SOURCE frame: the photo as decoded, before the recipe's
/// rotate and crop, origin top-left, `x` a fraction of the width and `y` of
/// the height (0...1 spans the photo; a gradient's end may lie outside it).
/// Pinning masks to the source is what keeps one on the same pixels under
/// any later crop, rotate, preview size or 1:1 window.
struct MaskPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// The two radii of a radial mask's ellipse, each a fraction of the source's
/// LONG side (not of its own axis), so equal radii are a circle on any
/// aspect ratio.
struct MaskRadii: Codable, Hashable {
    var x: Double
    var y: Double
}

/// One brush stroke: a path through source-frame points, painted (or, with
/// `erase`, removed) at `radius` (a fraction of the source long side), with
/// a soft edge `feather` (0 hard ... 1 all soft) and a `flow` (0...1, how
/// much one pass lays down).
struct BrushStroke: Codable, Hashable {
    var points: [MaskPoint]
    var radius: Double
    var feather: Double
    var flow: Double
    var erase: Bool = false
}

/// Where a local adjustment applies. Geometry is in the source frame
/// (`MaskPoint`, `MaskRadii`), never the view or the cropped frame.
enum MaskShape: Hashable {
    /// A graduated filter: full effect at `start`, fading to none at `end`,
    /// constant along the perpendicular.
    case linear(start: MaskPoint, end: MaskPoint)
    /// An ellipse at `center` with `radii`, turned by `angle` (degrees);
    /// full effect inside the inner ellipse (radii x (1 - feather)), easing
    /// to none at the outer one. `feather` is 0...1.
    case radial(center: MaskPoint, radii: MaskRadii, angle: Double, feather: Double)
    /// Painted strokes, in order (a later erase removes an earlier paint).
    case brush([BrushStroke])
}

/// The sidecar form of a shape: one object with a `type` and that type's
/// fields (`{"type": "linear", "start": …, "end": …}`), so the file reads
/// plainly and a new shape is a new `type`.
extension MaskShape: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, start, end, center, radii, angle, feather, strokes
    }

    private enum Kind: String, Codable { case linear, radial, brush }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .linear:
            self = .linear(start: try c.decode(MaskPoint.self, forKey: .start),
                           end: try c.decode(MaskPoint.self, forKey: .end))
        case .radial:
            self = .radial(center: try c.decode(MaskPoint.self, forKey: .center),
                           radii: try c.decode(MaskRadii.self, forKey: .radii),
                           angle: try c.decode(Double.self, forKey: .angle),
                           feather: try c.decode(Double.self, forKey: .feather))
        case .brush:
            self = .brush(try c.decode([BrushStroke].self, forKey: .strokes))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let start, let end):
            try c.encode(Kind.linear, forKey: .type)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        case .radial(let center, let radii, let angle, let feather):
            try c.encode(Kind.radial, forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radii, forKey: .radii)
            try c.encode(angle, forKey: .angle)
            try c.encode(feather, forKey: .feather)
        case .brush(let strokes):
            try c.encode(Kind.brush, forKey: .type)
            try c.encode(strokes, forKey: .strokes)
        }
    }
}

/// One local adjustment: a shape and the adjustments it applies where the
/// shape's weight is above zero. It holds only `LocalMask.kinds`; the
/// renderer applies them through the global chain blended by the mask.
/// Masks live in `Recipe.masks`, so undo, the sidecar, Photos adjustment
/// data and `Library.setRecipe` (the one writer) carry them with no path of
/// their own.
struct LocalMask: Codable, Hashable, Identifiable {
    /// The kinds a mask can carry, in chain order. An explicit list: a new
    /// global kind does not become a local one by being added to
    /// `AdjustmentKind`.
    static let kinds: [AdjustmentKind] =
        [.exposure, .temperature, .tint, .contrast, .highlights, .shadows, .saturation]
    private static let kindSet = Set(kinds)

    var id: UUID
    var shape: MaskShape
    /// Only kinds in `LocalMask.kinds`; a missing kind reads as neutral.
    var adjustments: [Adjustment]
    var enabled: Bool
    /// Applies where the shape does not (weight 1 - w).
    var inverted: Bool

    /// A mask over `shape`; adjustments outside `LocalMask.kinds` are dropped.
    init(id: UUID = UUID(), shape: MaskShape, adjustments: [Adjustment] = [],
         enabled: Bool = true, inverted: Bool = false) {
        self.id = id
        self.shape = shape
        self.adjustments = adjustments.filter { Self.kindSet.contains($0.kind) }
        self.enabled = enabled
        self.inverted = inverted
    }

    private enum CodingKeys: String, CodingKey { case id, shape, adjustments, enabled, inverted }

    /// A file's mask, with any kind outside `LocalMask.kinds` dropped as
    /// `init` drops it, so a hand-edited sidecar cannot smuggle crop or HSL
    /// into a mask.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  shape: try c.decode(MaskShape.self, forKey: .shape),
                  adjustments: try c.decodeIfPresent([Adjustment].self, forKey: .adjustments) ?? [],
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  inverted: try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false)
    }

    static func allows(_ kind: AdjustmentKind) -> Bool { kindSet.contains(kind) }

    /// The entry for `kind` (neutral when absent). Setting a kind outside
    /// `LocalMask.kinds` is ignored.
    subscript(kind: AdjustmentKind) -> Adjustment {
        get { adjustments.first { $0.kind == kind } ?? Adjustment(kind: kind, value: kind.neutral) }
        set {
            guard Self.allows(kind) else { return }
            if let i = adjustments.firstIndex(where: { $0.kind == kind }) {
                adjustments[i] = newValue
            } else {
                adjustments.append(newValue)
            }
        }
    }

    func value(of kind: AdjustmentKind) -> Double { self[kind].value }
    mutating func set(_ kind: AdjustmentKind, to value: Double) { self[kind].value = value }

    /// The canonical form: every kind of `LocalMask.kinds` once, in that
    /// order, so two masks that render the same compare equal whatever order
    /// a sidecar listed them in.
    var normalized: LocalMask {
        var out = self
        out.adjustments = Self.kinds.map { self[$0] }
        return out
    }

    /// True when rendering this mask would change nothing: switched off, or
    /// every adjustment a no-op (whatever its shape or inversion).
    var isNoop: Bool { !enabled || adjustments.allSatisfy(\.isNoop) }

    /// The render-side recipe of the mask: its adjustments as a global
    /// recipe, which the renderer applies under the mask.
    var recipe: Recipe { Recipe(adjustments: adjustments) }
}

// MARK: - Mask weights: the maths the renderer draws

/// The weight of a mask at a point, 0 (no effect) ... 1 (full effect): the
/// pure statement of what `MaskRender` draws with Core Image, so the shapes
/// are testable without a render and the on-canvas handles (a later chunk)
/// can read them. Distances are measured in pixels of the source, scaled by
/// its long side, so a perpendicular is perpendicular on screen and equal
/// radii are a circle on any aspect ratio; hence the source `size`.
enum MaskMath {
    /// `mask`'s weight at `point` (source frame) over a source of `size`
    /// pixels: the shape's weight, or 1 minus it when `inverted`; a
    /// disabled mask still has its weight (the renderer skips it).
    static func weight(of mask: LocalMask, at point: MaskPoint, in size: CGSize) -> Double {
        let w = weight(of: mask.shape, at: point, in: size)
        return mask.inverted ? 1 - w : w
    }

    /// The shape's own weight (no inversion).
    /// - linear: 1 at and before `start`, 0 at and beyond `end`, a straight
    ///   ramp between, constant along the perpendicular to start -> end. A
    ///   zero-length gradient weighs 0.
    /// - radial: 1 inside the inner ellipse (radii x (1 - feather)), 0 at
    ///   and outside the outer one (radii), a straight ramp in normalised
    ///   radius between; the ellipse is turned clockwise on screen by
    ///   `angle` degrees. A zero radius weighs 0.
    /// - brush: `BrushRaster.weight(of:at:in:)` (dabs along each stroke,
    ///   flow and feather, paint adding and erase multiplying down).
    static func weight(of shape: MaskShape, at point: MaskPoint, in size: CGSize) -> Double {
        let long = max(Double(size.width), Double(size.height))
        guard long > 0 else { return 0 }
        let sx = Double(size.width) / long, sy = Double(size.height) / long
        let px = point.x * sx, py = point.y * sy
        switch shape {
        case .linear(let start, let end):
            let ax = start.x * sx, ay = start.y * sy
            let dx = end.x * sx - ax, dy = end.y * sy - ay
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { return 0 }
            let t = ((px - ax) * dx + (py - ay) * dy) / len2
            return min(max(1 - t, 0), 1)
        case .radial(let center, let radii, let angle, let feather):
            guard radii.x > 0, radii.y > 0 else { return 0 }
            let d = ellipseRadius(px - center.x * sx, py - center.y * sy, radii: radii, angle: angle)
            let f = min(max(feather, 0), 1)
            if d >= 1 { return 0 }
            if d <= 1 - f { return 1 }
            return (1 - d) / f
        case .brush(let strokes):
            return BrushRaster.weight(of: strokes, at: point, in: size)
        }
    }

    /// The normalised radius of offset (dx, dy) (long-side units, y down)
    /// in an ellipse of `radii` turned clockwise on screen by `angle`
    /// degrees: 1 on the ellipse, below 1 inside.
    static func ellipseRadius(_ dx: Double, _ dy: Double, radii: MaskRadii, angle: Double) -> Double {
        let a = angle * .pi / 180
        // Into the ellipse's own axes: turn the offset back by `angle`.
        let u = dx * cos(a) + dy * sin(a)
        let v = -dx * sin(a) + dy * cos(a)
        return ((u / radii.x) * (u / radii.x) + (v / radii.y) * (v / radii.y)).squareRoot()
    }
}

// MARK: - View to source: where a mask point sits on the loupe

extension MaskMath {
    /// Where the loupe draws the rendered frame (after rotate and crop), in
    /// view points: scaled into a fit rect (`ZoomMath.fitRect`), or the 1:1
    /// window, `region` pixels of a frame `frame` pixels in size drawn
    /// unscaled at `displayScale` and centred in `pane` (as
    /// `ZoomMath.point(forClick:region:frame:pane:displayScale:)` reads it,
    /// without its snap to a pixel centre).
    enum Viewport: Equatable {
        case fit(CGRect)
        case window(region: CGRect, frame: CGSize, pane: CGSize, displayScale: CGFloat)

        /// A point normalised in the rendered frame (0...1, top-left) to view points.
        func view(_ f: CGPoint) -> CGPoint {
            switch self {
            case .fit(let r):
                return CGPoint(x: r.minX + f.x * r.width, y: r.minY + f.y * r.height)
            case .window(let region, let frame, let pane, let scale):
                let shown = Self.shownOrigin(region: region, pane: pane, displayScale: scale)
                return CGPoint(x: shown.x + (f.x * frame.width - region.minX) / scale,
                               y: shown.y + (f.y * frame.height - region.minY) / scale)
            }
        }

        /// The inverse of `view`; nil for an empty fit rect or frame.
        func frame(_ v: CGPoint) -> CGPoint? {
            switch self {
            case .fit(let r):
                guard r.width > 0, r.height > 0 else { return nil }
                return CGPoint(x: (v.x - r.minX) / r.width, y: (v.y - r.minY) / r.height)
            case .window(let region, let frame, let pane, let scale):
                guard frame.width > 0, frame.height > 0, scale > 0 else { return nil }
                let shown = Self.shownOrigin(region: region, pane: pane, displayScale: scale)
                return CGPoint(x: (region.minX + (v.x - shown.x) * scale) / frame.width,
                               y: (region.minY + (v.y - shown.y) * scale) / frame.height)
            }
        }

        /// The top-left of the 1:1 window as drawn, centred in the pane.
        private static func shownOrigin(region: CGRect, pane: CGSize, displayScale: CGFloat) -> CGPoint {
            CGPoint(x: (pane.width - region.width / displayScale) / 2,
                    y: (pane.height - region.height / displayScale) / 2)
        }
    }

    /// The recipe geometry a mask point goes through to reach the screen:
    /// the source's size (only its aspect is used), the rotate stage's turn
    /// (degrees, clockwise-positive on screen) and the crop insets of the
    /// rotated frame. Mirrors `Renderer`'s chain order (rotate, then crop)
    /// and its rotate stage: the turn about the centre, then the largest
    /// same-aspect rectangle inside the turned frame. The renderer also
    /// takes one pixel off each side of that rectangle; at a render's size
    /// that is under a pixel of the frame, so it is left out here.
    struct Geometry: Equatable {
        var source: CGSize
        var rotate: Double
        var crop: CropMath.Crop

        init(source: CGSize, rotate: Double = 0, crop: CropMath.Crop = .none) {
            self.source = source
            self.rotate = rotate
            self.crop = crop
        }

        /// The geometry `recipe` renders over a source of `source`.
        init(recipe: Recipe, source: CGSize) {
            self.init(source: source, rotate: recipe.effective(.rotate), crop: CropMath.crop(of: recipe))
        }

        /// The inscribed rectangle's scale: its sides over the source's.
        var inscribedScale: Double {
            let w = Double(source.width), h = Double(source.height)
            let t = rotate * .pi / 180
            let c = abs(cos(t)), s = abs(sin(t))
            guard w > 0, h > 0 else { return 1 }
            return min(w / (w * c + h * s), h / (w * s + h * c))
        }
    }

    /// A source point to the rendered frame, normalised (0...1 spans the
    /// frame shown, top-left): turned about the source's centre, then
    /// placed in the inscribed rectangle, then in the crop.
    static func frame(_ p: MaskPoint, _ g: Geometry) -> CGPoint {
        let w = Double(g.source.width), h = Double(g.source.height)
        let t = g.rotate * .pi / 180
        let dx = (p.x - 0.5) * w, dy = (p.y - 0.5) * h
        // Clockwise on screen with y down.
        let qx = dx * cos(t) - dy * sin(t), qy = dx * sin(t) + dy * cos(t)
        let s = g.inscribedScale
        let rx = qx / (w * s) + 0.5, ry = qy / (h * s) + 0.5
        let k = g.crop.rect
        return CGPoint(x: (rx - Double(k.minX)) / Double(k.width), y: (ry - Double(k.minY)) / Double(k.height))
    }

    /// The inverse of `frame`: a point of the rendered frame back to the
    /// source (the crop undone, then the inscribed inset, then the turn).
    static func source(_ f: CGPoint, _ g: Geometry) -> MaskPoint {
        let w = Double(g.source.width), h = Double(g.source.height)
        let k = g.crop.rect
        let rx = Double(k.minX) + Double(f.x) * Double(k.width)
        let ry = Double(k.minY) + Double(f.y) * Double(k.height)
        let s = g.inscribedScale
        let qx = (rx - 0.5) * w * s, qy = (ry - 0.5) * h * s
        let t = g.rotate * .pi / 180
        // The turn undone: rotate back by -t.
        let dx = qx * cos(t) + qy * sin(t), dy = -qx * sin(t) + qy * cos(t)
        return MaskPoint(x: dx / w + 0.5, y: dy / h + 0.5)
    }

    /// A source point to view points on the loupe.
    static func sourceToView(_ p: MaskPoint, _ g: Geometry, _ viewport: Viewport) -> CGPoint {
        viewport.view(frame(p, g))
    }

    /// A view point on the loupe to the source frame; nil when the viewport
    /// is empty. Points off the photo map too (a gradient's end may lie
    /// outside it).
    static func viewToSource(_ v: CGPoint, _ g: Geometry, _ viewport: Viewport) -> MaskPoint? {
        viewport.frame(v).map { source($0, g) }
    }
}
