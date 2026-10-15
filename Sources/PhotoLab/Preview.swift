import Foundation
import CoreGraphics
import CoreImage
import Observation

/// Drives the loupe: holds one photo's preview master and renders the
/// current recipe through `Renderer` at the view's pixel size. Requests
/// coalesce (latest wins) so a fast slider never queues stale frames: at most
/// one render is in flight and the newest request replaces any waiting one.
/// In compare mode (`setCompare`) a second, neutral request of the same
/// master at the same size rides beside each one, so Before and After come
/// out of the one chain at equal pixel size.
@MainActor
@Observable
final class PreviewModel {
    nonisolated static let masterPixelSize = 3200

    /// The latest rendered frame and the photo it belongs to.
    private(set) var image: CGImage?
    private(set) var imageURL: URL?
    /// Core Image time of the latest frame, ms (filter graph + readback).
    private(set) var renderMilliseconds: Double = 0
    private(set) var masterSize: CGSize = .zero
    /// The photo whose master could not be decoded (not an image, unreadable);
    /// the canvas labels it instead of waiting for a frame. Cleared by the
    /// next decode that succeeds.
    private(set) var failed: URL?
    /// The histogram of the latest frame (the plain frame, never the overlay),
    /// computed off the main thread after the frame is shown, so it runs a
    /// few milliseconds behind `image` and skips frames under a fast slider.
    private(set) var histogram: Histogram?
    /// When on, `image` is the frame with the clipping overlay composed over
    /// it (red over blown, blue over crushed); `J` in the loupe.
    private(set) var showClipping = false
    /// Before and After side by side (`Y`). While on, every request also asks
    /// for the neutral render of the same master at the same pixel size,
    /// which lands in `beforeImage`; leaving compare mode drops it.
    private(set) var compare = false
    /// The neutral frame for compare mode and the photo it belongs to. Never
    /// carries the clipping overlay; the histogram stays the After frame's.
    private(set) var beforeImage: CGImage?
    private(set) var beforeURL: URL?

    private var master: CIImage?
    private var masterURL: URL?
    private var loadTask: Task<Void, Never>?

    private var pending: Request?
    private var rendering = false
    /// The plain frame `image` was made from, for a re-compose when the
    /// overlay toggles without a new render.
    private var frame: CGImage?
    private var frameGeneration = 0
    private var histogramRunning = false
    private var histogramDirty = false
    /// The newest request, so turning compare on knows what Before to render.
    private var lastRequest: Request?
    /// Compare mode's waiting neutral request (latest wins, like `pending`),
    /// the one rendering, and the one `beforeImage` shows; a request equal to
    /// either of the last two is not rendered again. Leaving compare mode
    /// clears `beforeInFlight`, which is how a Before still rendering then
    /// knows it is no longer wanted.
    private var pendingBefore: Request?
    private var beforeInFlight: Request?
    private var beforeShown: Request?

    private struct Request: Equatable {
        let url: URL
        let recipe: Recipe
        let maxPixelSize: Int
    }

    /// Decodes the master for `url` off the main thread, then renders the
    /// request that is waiting (if any). A decode that fails forgets the url
    /// (so the next `load` of it decodes again) and sets `failed`.
    func load(_ url: URL) {
        guard url != masterURL else { return }
        loadTask?.cancel()
        master = nil
        masterURL = url
        histogram = nil
        let size = Self.masterPixelSize
        loadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Renderer.previewMaster(url, maxPixelSize: size)
            }.value
            guard let self, !Task.isCancelled, self.masterURL == url else { return }
            guard let decoded else {
                self.masterURL = nil
                self.masterSize = .zero
                self.failed = url
                return
            }
            self.failed = nil
            self.master = decoded
            self.masterSize = decoded.extent.size
            self.pump()
        }
    }

    /// Waits for the decode `load` started (tests).
    func awaitLoad() async {
        await loadTask?.value
    }


    /// Asks for a frame; `maxPixelSize` is the view's longest side in pixels.
    /// In compare mode the caller passes the size of one half; both frames
    /// are rendered at it.
    func request(url: URL, recipe: Recipe, maxPixelSize: Int) {
        let req = Request(url: url, recipe: recipe, maxPixelSize: max(1, maxPixelSize))
        pending = req
        lastRequest = req
        if compare { requestBefore(for: req) }
        pump()
    }

    /// Turns Before / After side by side on or off. On: the neutral frame for
    /// the newest request is rendered. Off: the Before frame is dropped,
    /// along with any Before waiting or rendering.
    func setCompare(_ on: Bool) {
        guard on != compare else { return }
        compare = on
        if on {
            if let lastRequest { requestBefore(for: lastRequest) }
            pump()
        } else {
            pendingBefore = nil
            beforeInFlight = nil
            beforeShown = nil
            beforeImage = nil
            beforeURL = nil
        }
    }

    /// The Before frame does not depend on the recipe, so a slider drag asks
    /// for nothing new; only a new photo or a new size does.
    private func requestBefore(for req: Request) {
        let before = Request(url: req.url, recipe: .neutral, maxPixelSize: req.maxPixelSize)
        guard before != beforeShown, before != beforeInFlight else { pendingBefore = nil; return }
        pendingBefore = before
    }

    /// One render in flight. A waiting Before goes first: it is asked for
    /// once per photo or size, so a slider drag that keeps `pending` full
    /// cannot starve it.
    private func pump() {
        guard !rendering, let master, let masterURL else { return }
        let req: Request
        let isBefore: Bool
        if let b = pendingBefore, b.url == masterURL {
            req = b
            pendingBefore = nil
            beforeInFlight = b
            isBefore = true
        } else if let a = pending, a.url == masterURL {
            req = a
            pending = nil
            isBefore = false
        } else {
            return
        }
        rendering = true
        if isBefore {
            renderBefore(req, from: master)
            return
        }
        let overlay = showClipping
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (plain: CGImage, shown: CGImage, milliseconds: Double)? in
                guard let r = Renderer.shared.render(master, recipe: req.recipe, maxPixelSize: req.maxPixelSize) else { return nil }
                // The overlay is one stage over the finished 8-bit frame, in
                // the same hop, so a slider drag with J on never flashes plain.
                let shown = overlay ? (ClippingOverlay.compose(over: r.image, context: Renderer.shared.context) ?? r.image) : r.image
                return (r.image, shown, r.milliseconds)
            }.value
            guard let self else { return }
            self.rendering = false
            if let result, self.masterURL == req.url {
                self.frame = result.plain
                self.frameGeneration += 1
                self.image = result.shown
                self.imageURL = req.url
                self.renderMilliseconds = result.milliseconds
                self.scheduleHistogram()
            }
            self.pump()
        }
    }

    /// The neutral frame through the same chain and the same master, kept
    /// only if it is still the wanted one (compare mode has not ended, even
    /// for a moment, since it started) and the photo has not changed.
    private func renderBefore(_ req: Request, from master: CIImage) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Renderer.shared.render(master, recipe: req.recipe, maxPixelSize: req.maxPixelSize)
            }.value
            guard let self else { return }
            self.rendering = false
            let wanted = self.beforeInFlight == req
            if wanted { self.beforeInFlight = nil }
            if let result, wanted, self.compare, self.masterURL == req.url {
                self.beforeImage = result.image
                self.beforeURL = req.url
                self.beforeShown = req
            }
            self.pump()
        }
    }

    /// Turns the clipping overlay on or off. The current frame is re-composed
    /// (or shown plain) without a render; later frames carry the choice.
    func setClipping(_ on: Bool) {
        guard on != showClipping else { return }
        showClipping = on
        guard let frame else { return }
        guard on else { image = frame; return }
        let generation = frameGeneration
        Task { [weak self] in
            let composed = await Task.detached(priority: .userInitiated) {
                ClippingOverlay.compose(over: frame, context: Renderer.shared.context)
            }.value
            guard let self, let composed, self.showClipping, self.frameGeneration == generation else { return }
            self.image = composed
        }
    }

    /// One histogram in flight at a time, always of the newest frame: a
    /// frame that lands while one is computing marks it dirty and the
    /// latest frame is measured when that one returns.
    private func scheduleHistogram() {
        guard let frame else { return }
        guard !histogramRunning else { histogramDirty = true; return }
        histogramRunning = true
        histogramDirty = false
        let generation = frameGeneration
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { Histogram.compute(frame) }.value
            guard let self else { return }
            self.histogramRunning = false
            if let computed, self.frameGeneration == generation { self.histogram = computed }
            if self.histogramDirty { self.scheduleHistogram() }
        }
    }
}
