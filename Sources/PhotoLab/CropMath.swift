import CoreGraphics

/// Crop mode's arithmetic, kept out of the view so it can be tested: where
/// the crop rectangle and its eight handles sit over the loupe's fit frame,
/// and how a handle dragged some view points moves the crop's edges.
///
/// Units: a crop is four insets, each a fraction (0…1) of the frame cut from
/// that side, the recipe's crop edges divided by 100. The frame is the
/// ROTATED, UNCROPPED one: the chain applies rotate before the crop
/// (`AdjustmentKind.allCases` order), so the crop is an axis-aligned
/// rectangle in the rotated frame, and crop mode shows that frame
/// (`uncropped`) with the rectangle over it. A fit rect is in view points
/// (`ZoomMath.fitRect`); the display scale never enters, since the fit
/// frame is laid out in points whatever the pixel size of its image.
enum CropMath {
    /// The four insets, fractions of the rotated frame, origin top-left.
    struct Crop: Equatable {
        var left: CGFloat = 0, top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0

        static let none = Crop()

        subscript(edge: Edge) -> CGFloat {
            get {
                switch edge {
                case .left: left
                case .top: top
                case .right: right
                case .bottom: bottom
                }
            }
            set {
                switch edge {
                case .left: left = newValue
                case .top: top = newValue
                case .right: right = newValue
                case .bottom: bottom = newValue
                }
            }
        }

        /// The kept part of the frame, normalised, origin top-left.
        var rect: CGRect { CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom) }
    }

    enum Edge: CaseIterable {
        case left, top, right, bottom

        var kind: AdjustmentKind {
            switch self {
            case .left: .cropLeft
            case .top: .cropTop
            case .right: .cropRight
            case .bottom: .cropBottom
            }
        }

        var opposite: Edge {
            switch self {
            case .left: .right
            case .right: .left
            case .top: .bottom
            case .bottom: .top
            }
        }

        /// +1 when a drag right (or down) grows this inset, -1 when it shrinks it.
        var sign: CGFloat { self == .left || self == .top ? 1 : -1 }
        var isHorizontal: Bool { self == .left || self == .right }
    }

    /// The four edge handles and the four corners; a corner moves two edges.
    enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var id: Self { self }

        var edges: [Edge] {
            switch self {
            case .topLeft: [.left, .top]
            case .top: [.top]
            case .topRight: [.right, .top]
            case .right: [.right]
            case .bottomRight: [.right, .bottom]
            case .bottom: [.bottom]
            case .bottomLeft: [.left, .bottom]
            case .left: [.left]
            }
        }

        var isCorner: Bool { edges.count == 2 }

        /// Where the handle sits on a crop rectangle in view points.
        func point(in r: CGRect) -> CGPoint {
            let x: CGFloat = edges.contains(.left) ? r.minX : edges.contains(.right) ? r.maxX : r.midX
            let y: CGFloat = edges.contains(.top) ? r.minY : edges.contains(.bottom) ? r.maxY : r.midY
            return CGPoint(x: x, y: y)
        }

        var label: String {
            switch self {
            case .topLeft: "top-left corner"
            case .top: "top edge"
            case .topRight: "top-right corner"
            case .right: "right edge"
            case .bottomRight: "bottom-right corner"
            case .bottom: "bottom edge"
            case .bottomLeft: "bottom-left corner"
            case .left: "left edge"
            }
        }
    }

    /// The most one inset may take: the crop sliders' upper bound (40%).
    static var maxInset: CGFloat { CGFloat(AdjustmentKind.cropLeft.range.upperBound) / 100 }

    /// The least the crop keeps on each axis: what two insets at the
    /// slider's bound leave (20% of the frame).
    static var minSize: CGFloat { 1 - 2 * maxInset }

    /// The recipe's crop as it renders (a disabled edge is no inset).
    static func crop(of recipe: Recipe) -> Crop {
        var c = Crop()
        for edge in Edge.allCases { c[edge] = CGFloat(recipe.effective(edge.kind)) / 100 }
        return c
    }

    /// Writes `edges` of `crop` into `recipe` as percent, each enabled: a
    /// handle only writes the edges it moves, so a disabled edge the drag
    /// does not touch keeps its value.
    static func write(_ crop: Crop, edges: [Edge], into recipe: inout Recipe) {
        for edge in edges {
            recipe.set(edge.kind, to: Double(crop[edge] * 100))
            recipe.setEnabled(edge.kind, true)
        }
    }

    /// The recipe with no crop: what crop mode renders, the rotated frame
    /// whole, so the rectangle can be drawn and dragged over all of it.
    static func uncropped(_ recipe: Recipe) -> Recipe {
        var r = recipe
        for edge in Edge.allCases { r.reset(edge.kind) }
        return r
    }

    /// True when a frame rendered from `shown` is the frame crop mode draws
    /// `current`'s rectangle over: uncropped, at the same rotation. Until it
    /// is, the overlay waits rather than drawing over the cropped frame.
    static func isCropFrame(_ shown: Recipe, for current: Recipe) -> Bool {
        crop(of: shown) == .none && shown.effective(.rotate) == current.effective(.rotate)
    }

    /// The crop rectangle in view points over the fit rect `fit`.
    static func rect(_ crop: Crop, in fit: CGRect) -> CGRect {
        let r = crop.rect
        return CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                      width: r.width * fit.width, height: r.height * fit.height)
    }

    /// `handle` dragged by `translation` view points from the crop `start`
    /// over a fit frame `fit` points in size: each edge the handle owns
    /// follows the pointer by the same fraction of the frame, then is
    /// clamped (`clamp`). Measured from the drag's start, so a drag that
    /// runs past a bound and comes back picks up again where the pointer is.
    static func drag(_ handle: Handle, from start: Crop, by translation: CGSize, fit: CGSize) -> Crop {
        guard fit.width > 0, fit.height > 0 else { return start }
        var c = start
        for edge in handle.edges {
            let d = edge.isHorizontal ? translation.width / fit.width : translation.height / fit.height
            c[edge] = clamp(start[edge] + edge.sign * d, opposite: start[edge.opposite])
        }
        return c
    }

    /// An inset held inside the frame (never below 0, the image's edge), at
    /// most the slider's bound, and never so far that less than `minSize`
    /// of the frame is left beside the `opposite` inset.
    static func clamp(_ inset: CGFloat, opposite: CGFloat) -> CGFloat {
        let most = max(0, min(maxInset, 1 - minSize - opposite))
        return min(max(inset, 0), most)
    }
}
