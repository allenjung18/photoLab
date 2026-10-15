import Foundation
import CoreGraphics
import CoreImage
import Observation

/// Drives the loupe: holds one photo's preview master and renders the
/// current recipe through `Renderer` at the view's pixel size. Requests
/// coalesce (latest wins) so a fast slider never queues stale frames: at most
/// one render is in flight and the newest request replaces any waiting one.
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

    private struct Request {
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
    func request(url: URL, recipe: Recipe, maxPixelSize: Int) {
        pending = Request(url: url, recipe: recipe, maxPixelSize: max(1, maxPixelSize))
        pump()
    }

    private func pump() {
        guard !rendering, let req = pending, let master, masterURL == req.url else { return }
        pending = nil
        rendering = true
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
