import CoreGraphics

/// The loupe's zoom arithmetic, kept out of the view so it can be tested:
/// where a click on the fit frame lands in the rendered frame, how far a
/// drag moves the 1:1 window, the clamp that keeps the window inside the
/// frame, and when a photo is too small to zoom at all.
///
/// Units: a pane is in view points; a window and a frame are in pixels (one
/// image pixel per view pixel at 1:1, so a window is the pane times the
/// display scale); a centre is normalised in the rendered frame (after crop
/// and rotate), 0…1 on each axis, origin top-left, as in `PreviewZoom`.
enum ZoomMath {
    /// The fit frame's inset from the pane's edges, in points (the canvas's
    /// padding around a fit frame).
    static let fitInset: CGFloat = 8

    /// The 1:1 window for a pane: its size in pixels.
    static func window(pane: CGSize, displayScale: CGFloat) -> CGSize {
        CGSize(width: (pane.width * displayScale).rounded(.down),
               height: (pane.height * displayScale).rounded(.down))
    }

    /// True when the whole frame fits inside the window at 1:1: zooming in
    /// would only shrink it, so the loupe stays at fit.
    static func fits(frame: CGSize, in window: CGSize) -> Bool {
        frame.width <= window.width && frame.height <= window.height
    }

    /// Where a frame of `frame`'s shape sits when scaled to fit `pane`
    /// inset by `inset` on every side (SwiftUI's `scaledToFit` in a padded
    /// pane), in pane points.
    static func fitRect(frame: CGSize, pane: CGSize, inset: CGFloat = fitInset) -> CGRect {
        let box = CGRect(origin: .zero, size: pane).insetBy(dx: inset, dy: inset)
        guard frame.width > 0, frame.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let s = min(box.width / frame.width, box.height / frame.height)
        let w = frame.width * s, h = frame.height * s
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// A click at `point` (pane points) on the fit frame of a frame shaped
    /// `frame`: the normalised point of the frame under it, or nil when the
    /// click is on the black around the photo. The display scale does not
    /// enter: the fit frame is laid out in points.
    static func center(forClick point: CGPoint, frame: CGSize, pane: CGSize,
                       inset: CGFloat = fitInset) -> CGPoint? {
        let r = fitRect(frame: frame, pane: pane, inset: inset)
        guard r.width > 0, r.height > 0, r.contains(point) else { return nil }
        return CGPoint(x: (point.x - r.minX) / r.width, y: (point.y - r.minY) / r.height)
    }

    /// The centre held so a window of `window` pixels around it stays inside
    /// a frame of `frame` pixels: never closer to an edge than half the
    /// window, and the middle on an axis where the window covers the whole
    /// frame. Held the same way `Renderer.Region.rect(in:)` slides the
    /// window, so a pan back from an edge moves the picture at once instead
    /// of first unwinding a centre that had run past it.
    static func clamp(_ center: CGPoint, window: CGSize, frame: CGSize) -> CGPoint {
        func axis(_ c: CGFloat, _ w: CGFloat, _ f: CGFloat) -> CGFloat {
            guard f > 0 else { return 0.5 }
            let half = min(w, f) / 2 / f
            guard half < 0.5 else { return 0.5 }
            return min(max(c, half), 1 - half)
        }
        return CGPoint(x: axis(center.x, window.width, frame.width),
                       y: axis(center.y, window.height, frame.height))
    }

    /// A drag of `translation` view points while at 1:1: the picture follows
    /// the pointer, so the centre moves the other way by the same number of
    /// frame pixels (points times the display scale), then is clamped.
    static func pan(_ center: CGPoint, by translation: CGSize, displayScale: CGFloat,
                    window: CGSize, frame: CGSize) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return center }
        let moved = CGPoint(x: center.x - translation.width * displayScale / frame.width,
                            y: center.y - translation.height * displayScale / frame.height)
        return clamp(moved, window: window, frame: frame)
    }
}
