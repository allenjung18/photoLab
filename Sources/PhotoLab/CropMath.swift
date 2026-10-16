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
        min(max(inset, 0), most(opposite: opposite))
    }

    /// The most an inset may take beside `opposite` (see `clamp`).
    static func most(opposite: CGFloat) -> CGFloat {
        max(0, min(maxInset, 1 - minSize - opposite))
    }

    // MARK: Aspect lock

    /// The crop's aspect picker: a preset and the portrait/landscape swap.
    /// Free leaves the handles as they are; any other preset locks a corner
    /// drag to its ratio (and hides the edge handles) and refits the crop
    /// when picked (`Library.setCropAspect`). Tool state, never part of a
    /// recipe: what a crop keeps is its four insets.
    struct Aspect: Equatable {
        enum Preset: CaseIterable, Identifiable {
            case original, free, square, fourFive, threeTwo, sixteenNine

            var id: Self { self }

            /// Width and height as the preset is named; nil for Original
            /// (the frame's own) and Free.
            var sides: (width: CGFloat, height: CGFloat)? {
                switch self {
                case .original, .free: nil
                case .square: (1, 1)
                case .fourFive: (4, 5)
                case .threeTwo: (3, 2)
                case .sixteenNine: (16, 9)
                }
            }
        }

        var preset: Preset = .free
        /// Width and height exchanged: 4:5 reads 5:4, 3:2 reads 2:3,
        /// Original is the frame's ratio turned on its side.
        var swapped = false

        static let free = Aspect()

        var isLocked: Bool { preset != .free }
        /// Free has no ratio to turn, and 1:1 turns into itself.
        var canSwap: Bool { preset != .free && preset != .square }

        /// The picker's title for `preset` under this aspect's swap.
        func title(of preset: Preset) -> String {
            switch preset {
            case .original: return swapped ? "Original, swapped" : "Original"
            case .free: return "Free"
            default:
                let s = preset.sides!
                let (w, h) = swapped ? (s.height, s.width) : (s.width, s.height)
                return "\(Int(w)):\(Int(h))"
            }
        }

        var title: String { title(of: preset) }

        /// The crop's width over its height in PIXELS of a frame `frame`
        /// in size (any unit: only its aspect is used); nil when Free or
        /// the frame is empty.
        func ratio(frame: CGSize) -> CGFloat? {
            guard isLocked, frame.width > 0, frame.height > 0 else { return nil }
            let r: CGFloat
            if let s = preset.sides { r = s.width / s.height } else { r = frame.width / frame.height }
            return swapped ? 1 / r : r
        }

        /// The same ratio in the crop's own units, fractions of the frame:
        /// the kept width fraction over the kept height fraction.
        func normalized(frame: CGSize) -> CGFloat? {
            ratio(frame: frame).map { $0 * frame.height / frame.width }
        }
    }

    /// True when `crop` keeps the normalised ratio `k`.
    static func holds(_ crop: Crop, ratio k: CGFloat) -> Bool {
        let r = crop.rect
        return abs(r.width - k * r.height) <= 1e-9 * max(1, k)
    }

    /// The crop refitted to the normalised ratio `k`: the largest rectangle
    /// of that ratio centred where the crop's centre is, inside the frame
    /// and within the sliders' bound. When that centre leaves no such
    /// rectangle (an off-centre crop and a ratio far from it) the frame's
    /// centre is used; a ratio the bound cannot hold at all (more than 5:1
    /// in frame fractions) is kept as near as the bound allows.
    static func refit(_ crop: Crop, ratio k: CGFloat) -> Crop {
        guard k > 0 else { return crop }
        let r = crop.rect
        if let c = largest(ratio: k, center: CGPoint(x: r.midX, y: r.midY)) { return c }
        if let c = largest(ratio: k, center: CGPoint(x: 0.5, y: 0.5)) { return c }
        let w = max(minSize, min(1, k)), h = max(minSize, min(1, 1 / k))
        return Crop(left: (1 - w) / 2, top: (1 - h) / 2, right: (1 - w) / 2, bottom: (1 - h) / 2)
    }

    /// The largest crop of ratio `k` centred on `c`, or nil when it would
    /// need an inset past the sliders' bound.
    private static func largest(ratio k: CGFloat, center c: CGPoint) -> Crop? {
        let wMax = 2 * min(c.x, 1 - c.x), hMax = 2 * min(c.y, 1 - c.y)
        let h = min(hMax, wMax / k), w = k * h
        guard w > 0, h > 0 else { return nil }
        let crop = Crop(left: max(0, c.x - w / 2), top: max(0, c.y - h / 2),
                        right: max(0, 1 - c.x - w / 2), bottom: max(0, 1 - c.y - h / 2))
        let insets = [crop.left, crop.top, crop.right, crop.bottom]
        return insets.allSatisfy { $0 <= maxInset + 1e-12 } ? crop : nil
    }

    /// `handle` dragged with the aspect locked to the normalised ratio `k`
    /// (nil is a free drag, `drag(_:from:by:fit:)`). A corner keeps its
    /// opposite corner where it is and sizes the crop to the ratio from
    /// whichever axis the pointer has moved further, then holds it inside
    /// the bounds `clamp` keeps, on both axes at once so the ratio holds.
    /// An edge handle does nothing under a lock (the overlay hides it). A
    /// crop that does not hold the ratio (a slider moved it, another photo)
    /// is refitted first.
    static func drag(_ handle: Handle, from start: Crop, by translation: CGSize, fit: CGSize, ratio k: CGFloat?) -> Crop {
        guard let k else { return drag(handle, from: start, by: translation, fit: fit) }
        guard k > 0, handle.isCorner, fit.width > 0, fit.height > 0 else { return start }
        let base = holds(start, ratio: k) ? start : refit(start, ratio: k)
        let hEdge = handle.edges.first(where: \.isHorizontal)!
        let vEdge = handle.edges.first(where: { !$0.isHorizontal })!
        let anchorX = base[hEdge.opposite], anchorY = base[vEdge.opposite]
        // The size the pointer asks for: a drag that grows an inset shrinks the crop.
        let wantW = base.rect.width - hEdge.sign * translation.width / fit.width
        let wantH = base.rect.height - vEdge.sign * translation.height / fit.height
        // Heights the bounds allow on both axes (the moving inset in 0…most).
        let lo = max(1 - anchorY - most(opposite: anchorY), (1 - anchorX - most(opposite: anchorX)) / k)
        let hi = min(1 - anchorY, (1 - anchorX) / k)
        guard lo <= hi + 1e-12 else { return base }
        let height = base.rect.height, dW = wantW / k - height, dH = wantH - height
        let h = min(max(height + (abs(dW) >= abs(dH) ? dW : dH), lo), hi), w = k * h
        var c = base
        c[hEdge] = max(0, 1 - anchorX - w)
        c[vEdge] = max(0, 1 - anchorY - h)
        return c
    }

    /// The edges a drag from `start` to `end` must write: the handle's own,
    /// and under a lock any other the refit moved.
    static func edgesToWrite(_ handle: Handle, from start: Crop, to end: Crop) -> [Edge] {
        Edge.allCases.filter { handle.edges.contains($0) || start[$0] != end[$0] }
    }

    /// The handles the overlay shows: the corners alone under a lock.
    static func handles(locked: Bool) -> [Handle] {
        locked ? Handle.allCases.filter(\.isCorner) : Handle.allCases
    }
}

/// The straighten tool's arithmetic: a line dragged along something that
/// should be level (a horizon) or upright (a wall) on the frame crop mode
/// shows, and the rotate value that makes it so. Angles are in the view's
/// own points, y DOWN, so a line at +3.2° falls to the right; the renderer's
/// rotate is clockwise-positive on screen (`Renderer.stage`, `.rotate`), so
/// levelling that line takes -3.2°. The frame shown is already turned by the
/// current rotate and the fit scale is uniform, so the angle seen is the
/// angle in the frame, and the correction adds to the current value.
enum StraightenMath {
    /// A press shorter than this (points) is not a line.
    static let minLength: CGFloat = 8

    /// The line's angle in degrees, y down, folded to -90…90 (a line has no
    /// direction: drawn right to left it is the same line); nil when too short.
    static func angle(from a: CGPoint, to b: CGPoint) -> Double? {
        let dx = b.x - a.x, dy = b.y - a.y
        guard hypot(dx, dy) >= minLength else { return nil }
        var deg = Double(atan2(dy, dx)) * 180 / .pi
        if deg > 90 { deg -= 180 } else if deg <= -90 { deg += 180 }
        return deg
    }

    /// How far the line is from level (within 45° of horizontal) or from
    /// upright (steeper than that), clockwise-positive on screen.
    static func tilt(from a: CGPoint, to b: CGPoint) -> Double? {
        guard let deg = angle(from: a, to: b) else { return nil }
        if abs(deg) <= 45 { return deg }
        return deg > 0 ? deg - 90 : deg + 90
    }

    /// The rotate value that levels (or uprights) the line drawn over a
    /// frame turned by `current`, held in the rotate slider's range; nil
    /// when the line is too short to read.
    static func rotate(levelling a: CGPoint, _ b: CGPoint, current: Double) -> Double? {
        guard let t = tilt(from: a, to: b) else { return nil }
        let range = AdjustmentKind.rotate.range
        return min(max(current - t, range.lowerBound), range.upperBound)
    }
}
