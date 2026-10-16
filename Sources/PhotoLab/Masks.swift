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
