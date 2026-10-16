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
/// out of the one chain at equal pixel size. At 1:1 (`setZoom`) a third
/// request renders a window of the full-resolution image through the same
/// chain (`zoomImage`).
///
/// A photo with a large embedded preview and a slow master (a camera RAW)
/// shows that preview first (`load`): it stands in as the master, so the
/// recipe renders over it through the same chain, and the decoded master
/// replaces it when it lands, re-rendering the newest request once; the
/// frame on screen is never cleared in between.
@MainActor
@Observable
final class PreviewModel {
    nonisolated static let masterPixelSize = 3200
    /// The smallest embedded preview worth showing first: a Sony ARW's
    /// 1616 px passes, a JPEG's 160 px EXIF thumbnail does not.
    nonisolated static let firstFrameMinPixelSize = 1024

    /// The two decodes behind `load`, injectable so a test can hold the
    /// master back or count its calls. Both run off the main thread.
    struct Decoders: Sendable {
        /// The embedded preview to show first, or nil (`Renderer.firstFrame`).
        var firstFrame: @Sendable (URL) -> CIImage?
        /// The preview master at a long side (`Renderer.previewMaster`).
        var master: @Sendable (URL, Int) -> CIImage?

        static let live = Decoders(
            firstFrame: { Renderer.firstFrame($0, minPixelSize: PreviewModel.firstFrameMinPixelSize,
                                              masterPixelSize: PreviewModel.masterPixelSize) },
            master: { Renderer.previewMaster($0, maxPixelSize: $1) })
    }

    private let decoders: Decoders

    init(decoders: Decoders = .live) {
        self.decoders = decoders
    }

    /// The latest rendered frame and the photo it belongs to.
    private(set) var image: CGImage?
    private(set) var imageURL: URL?
    /// `image` was rendered over the embedded preview, the decoded master
    /// not yet in (`load`).
    private(set) var imageIsFirstFrame = false
    /// Counts the frames shown in `image` (tests read it to see one swap).
    private(set) var frameGeneration = 0
    /// The recipe `image` was rendered from (crop mode draws its rectangle
    /// only over a frame rendered uncropped, `CropMath.isCropFrame`).
    private(set) var imageRecipe: Recipe?
    /// Core Image time of the latest frame, ms (filter graph + readback).
    private(set) var renderMilliseconds: Double = 0
    /// The decoded master's size; zero until it lands (never the embedded
    /// preview's, whose aspect can differ by a pixel), so the crop's aspect
    /// row waits for it.
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
    /// Show Mask Overlay: the id of the mask (in each request's recipe) that
    /// `image` and the 1:1 window carry tinted red (`MaskTint`), composed
    /// after the clipping overlay in the same hop; nil for none. Never on
    /// compare's Before.
    private(set) var maskOverlay: UUID?
    /// Before and After side by side (`Y`). While on, every request also asks
    /// for the neutral render of the same master at the same pixel size,
    /// which lands in `beforeImage`; leaving compare mode drops it.
    private(set) var compare = false
    /// The neutral frame for compare mode and the photo it belongs to. Never
    /// carries the clipping overlay; the histogram stays the After frame's.
    private(set) var beforeImage: CGImage?
    private(set) var beforeURL: URL?

    /// Fit (the whole frame in the view) or 1:1 around a centre. While 1:1,
    /// every request also asks for the window of the full-resolution render
    /// the view's pixels cover, which lands in `zoomImage`; `image` and the
    /// histogram stay the fit frame's.
    private(set) var zoom: PreviewZoom = .fit
    /// The 1:1 window and the photo it belongs to: one image pixel per view
    /// pixel, cut from the full-resolution render (`Renderer.render` with a
    /// `region`), so it matches the export pixel for pixel.
    private(set) var zoomImage: CGImage?
    private(set) var zoomURL: URL?
    /// Where `zoomImage` sits: a rect in the full-resolution rendered frame,
    /// origin top-left, slid inside the frame at the edges
    /// (`Renderer.Region.rect(in:)`).
    private(set) var zoomRegion: CGRect?
    /// The full-resolution rendered frame's size (after crop and rotate) the
    /// region was cut from: what a pan clamps against and a click maps into.
    private(set) var zoomFrameSize: CGSize = .zero
    /// Core Image time of the latest 1:1 window, ms.
    private(set) var zoomMilliseconds: Double = 0
    /// Compare mode's Before at 1:1: the neutral render's window, cut at the
    /// same `Renderer.Region` as `zoomImage` in the same hop, so the two
    /// halves always show the same region. Never carries the overlay.
    private(set) var zoomBeforeImage: CGImage?
    private(set) var zoomBeforeRegion: CGRect?
    /// The photo whose full-resolution master is held (decoded on the first
    /// 1:1 of that photo, dropped when the photo changes), and its pixel size.
    private(set) var fullResolutionURL: URL?
    private(set) var fullResolutionSize: CGSize = .zero

    private var master: CIImage?
    private var masterURL: URL?
    /// `master` is the embedded preview standing in until the decode lands.
    private var masterIsFirstFrame = false
    private var loadTask: Task<Void, Never>?
    private var firstFrameTask: Task<Void, Never>?

    private var pending: Request?
    private var rendering = false
    /// The plain frame `image` was made from, for a re-compose when the
    /// overlay toggles without a new render.
    private var frame: CGImage?
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

    /// The full-resolution master behind 1:1: the whole file decoded once
    /// (`Renderer.fullResolution(_:decodeNow:)`), held for one photo.
    private var fullMaster: CIImage?
    private var fullLoadTask: Task<Void, Never>?
    /// The view's pixel size from the newest request: the 1:1 window's size.
    private var lastViewPixelSize: CGSize = .zero
    /// The 1:1 slot, run like compare's: waiting (latest wins), rendering,
    /// shown. Leaving 1:1 or changing photo clears the in-flight one, so a
    /// window still rendering then is discarded.
    private var pendingZoom: ZoomRequest?
    private var zoomInFlight: ZoomRequest?
    private var zoomShown: ZoomRequest?
    /// The recipe the shown 1:1 window was rendered from, as `imageRecipe`
    /// is the fit frame's (the mask handles check its rotate and crop).
    var zoomRecipe: Recipe? { zoomShown?.recipe }
    /// Which slot rendered last, so a waiting window and a waiting fit frame
    /// take turns under a drag and neither starves.
    private var lastRenderWasZoom = false

    private struct Request: Equatable {
        let url: URL
        let recipe: Recipe
        let maxPixelSize: Int
    }

    private struct ZoomRequest: Equatable {
        let url: URL
        let recipe: Recipe
        let region: Renderer.Region
        let overlay: Bool
        let maskOverlay: UUID?
        /// Compare mode: the neutral window at the same region rides along.
        let before: Bool
    }

    /// Decodes the master for `url` off the main thread, then renders the
    /// request that is waiting (if any). A decode that fails forgets the url
    /// (so the next `load` of it decodes again) and sets `failed`.
    ///
    /// Beside it, the embedded preview is read (`Decoders.firstFrame`, ~20 ms
    /// for a RAW against ~800 ms for its master). If it lands first it
    /// stands in as the master: the waiting request renders over it, the
    /// recipe applied, and `imageIsFirstFrame` says so. When the master
    /// lands it takes the preview's place and the newest request (and
    /// compare's Before) render again, once; `image` keeps the preview's
    /// frame until then. A master that lands first leaves the preview unused.
    ///
    /// A new photo cancels both decodes of the old one: the cancellation is
    /// forwarded into the detached work, so a decode that has not started is
    /// skipped and one that finishes anyway is dropped (an ImageIO decode
    /// cannot be stopped once begun).
    func load(_ url: URL) {
        guard url != masterURL else { return }
        loadTask?.cancel()
        firstFrameTask?.cancel()
        master = nil
        masterIsFirstFrame = false
        masterURL = url
        masterSize = .zero
        histogram = nil
        dropFullResolution()
        // Still 1:1 with a request for this photo already in: its own
        // full-resolution master starts decoding beside the preview master.
        requestZoom()
        let size = Self.masterPixelSize
        let decoders = decoders
        firstFrameTask = Task { [weak self] in
            let preview = await Self.offMain { decoders.firstFrame(url) }
            guard let self, !Task.isCancelled, self.masterURL == url, let preview else { return }
            self.master = preview
            self.masterIsFirstFrame = true
            self.pump()
        }
        loadTask = Task { [weak self] in
            let decoded = await Self.offMain { decoders.master(url, size) }
            guard let self, !Task.isCancelled, self.masterURL == url else { return }
            // The master is in: a preview still decoding is not wanted.
            self.firstFrameTask?.cancel()
            let swapping = self.masterIsFirstFrame
            self.masterIsFirstFrame = false
            guard let decoded else {
                // The preview's frame is not left standing over a photo
                // that cannot be opened: the canvas labels it instead.
                if self.imageURL == url {
                    self.image = nil
                    self.imageURL = nil
                    self.imageIsFirstFrame = false
                }
                self.master = nil
                self.masterURL = nil
                self.masterSize = .zero
                self.failed = url
                return
            }
            self.failed = nil
            self.master = decoded
            self.masterSize = decoded.extent.size
            if swapping { self.renderAgainOverMaster() }
            self.pump()
        }
    }

    /// The master has replaced the embedded preview: every frame shown so
    /// far was rendered over the preview, so the newest request is asked
    /// again, and compare's Before (one rendering over the preview is
    /// dropped when it lands).
    private func renderAgainOverMaster() {
        guard let last = lastRequest, last.url == masterURL else { return }
        if pending == nil { pending = last }
        if compare {
            beforeShown = nil
            beforeInFlight = nil
            requestBefore(for: last)
        }
    }

    /// Runs `work` detached with the caller's cancellation forwarded into it:
    /// work cancelled before it starts is skipped.
    private nonisolated static func offMain(_ work: @escaping @Sendable () -> CIImage?) async -> CIImage? {
        let handle = Task.detached(priority: .userInitiated) { () -> CIImage? in
            if Task.isCancelled { return nil }
            return work()
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// Waits for the decode `load` started (tests).
    func awaitLoad() async {
        await loadTask?.value
    }


    /// Asks for a frame; `maxPixelSize` is the view's longest side in pixels.
    /// In compare mode the caller passes the size of one half; both frames
    /// are rendered at it. `viewPixelSize` is the view's size in pixels, the
    /// 1:1 window's size (a square of `maxPixelSize` when not given).
    func request(url: URL, recipe: Recipe, maxPixelSize: Int, viewPixelSize: CGSize? = nil) {
        let req = Request(url: url, recipe: recipe, maxPixelSize: max(1, maxPixelSize))
        pending = req
        lastRequest = req
        lastViewPixelSize = viewPixelSize ?? CGSize(width: req.maxPixelSize, height: req.maxPixelSize)
        if compare { requestBefore(for: req) }
        requestZoom()
        pump()
    }

    /// Fit or 1:1. Into 1:1 (or a new centre): the window for the newest
    /// request is asked for, decoding the photo's full-resolution master
    /// first if this is its first 1:1. Back to fit: the window is dropped
    /// (and any waiting or rendering); the master stays until the photo
    /// changes, so zooming in again on the same photo decodes nothing. A
    /// photo whose rendered frame fits inside the view whole
    /// (`ZoomMath.fits`) goes back to fit by itself once its first window
    /// says so: 1:1 would only make it smaller.
    func setZoom(_ zoom: PreviewZoom) {
        let zoom = zoom.clamped
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        if case .fit = zoom {
            clearZoomFrame()
        } else {
            requestZoom()
            pump()
        }
    }

    /// Waits for the full-resolution decode `setZoom` started (tests).
    func awaitFullResolution() async {
        await fullLoadTask?.value
    }

    private func requestZoom() {
        guard case .actual(let center) = zoom, let last = lastRequest else { pendingZoom = nil; return }
        let z = ZoomRequest(url: last.url, recipe: last.recipe,
                            region: Renderer.Region(center: center, size: lastViewPixelSize), overlay: showClipping,
                            maskOverlay: maskOverlay, before: compare)
        guard z != zoomShown, z != zoomInFlight else { pendingZoom = nil; return }
        pendingZoom = z
        loadFullResolution(z.url)
    }

    /// Decodes the whole file once, off the main thread, for the photo the
    /// loupe shows. A decode that fails leaves 1:1 with no window.
    private func loadFullResolution(_ url: URL) {
        guard url == masterURL, fullResolutionURL != url else { return }
        fullLoadTask?.cancel()
        fullMaster = nil
        fullResolutionURL = url
        fullResolutionSize = .zero
        fullLoadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Renderer.fullResolution(url, decodeNow: true)
            }.value
            guard let self, !Task.isCancelled, self.fullResolutionURL == url else { return }
            guard let decoded else {
                self.fullResolutionURL = nil
                if self.pendingZoom?.url == url { self.pendingZoom = nil }
                return
            }
            self.fullMaster = decoded
            self.fullResolutionSize = decoded.extent.size
            self.pump()
        }
    }

    /// A new photo: its full-resolution master is decoded on its own first
    /// 1:1, never carried over. The old one (about 4 bytes a pixel, 96 MB
    /// for a 24 MP photo) is released here, with the window cut from it.
    private func dropFullResolution() {
        fullLoadTask?.cancel()
        fullLoadTask = nil
        fullMaster = nil
        fullResolutionURL = nil
        fullResolutionSize = .zero
        clearZoomFrame()
    }

    private func clearZoomFrame() {
        pendingZoom = nil
        zoomInFlight = nil
        zoomShown = nil
        zoomImage = nil
        zoomURL = nil
        zoomRegion = nil
        zoomFrameSize = .zero
        zoomBeforeImage = nil
        zoomBeforeRegion = nil
    }

    /// Turns Before / After side by side on or off. On: the neutral frame for
    /// the newest request is rendered. Off: the Before frame is dropped,
    /// along with any Before waiting or rendering.
    func setCompare(_ on: Bool) {
        guard on != compare else { return }
        compare = on
        if on {
            if let lastRequest { requestBefore(for: lastRequest) }
            requestZoom()
            pump()
        } else {
            pendingBefore = nil
            beforeInFlight = nil
            beforeShown = nil
            beforeImage = nil
            beforeURL = nil
            zoomBeforeImage = nil
            zoomBeforeRegion = nil
            requestZoom()
            pump()
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
    /// cannot starve it. A waiting 1:1 window (once its full-resolution
    /// master is decoded) and a waiting fit frame take turns.
    private func pump() {
        guard !rendering, let master, let masterURL else { return }
        let req: Request
        let isBefore: Bool
        let zoomReady = pendingZoom.map { $0.url == masterURL && fullResolutionURL == $0.url && fullMaster != nil } ?? false
        let fitReady = pending.map { $0.url == masterURL } ?? false
        if let b = pendingBefore, b.url == masterURL {
            req = b
            pendingBefore = nil
            beforeInFlight = b
            isBefore = true
        } else if zoomReady && (!fitReady || !lastRenderWasZoom), let z = pendingZoom, let full = fullMaster {
            pendingZoom = nil
            zoomInFlight = z
            rendering = true
            lastRenderWasZoom = true
            renderZoom(z, from: full)
            return
        } else if fitReady, let a = pending {
            req = a
            pending = nil
            isBefore = false
            lastRenderWasZoom = false
        } else {
            return
        }
        rendering = true
        if isBefore {
            renderBefore(req, from: master)
            return
        }
        let overlay = showClipping
        let tinted = maskOverlay.flatMap { id in req.recipe.masks.first { $0.id == id } }
        let fromFirstFrame = masterIsFirstFrame
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (plain: CGImage, shown: CGImage, milliseconds: Double)? in
                guard let r = Renderer.shared.render(master, recipe: req.recipe, maxPixelSize: req.maxPixelSize) else { return nil }
                // The overlays are stages over the finished 8-bit frame, in
                // the same hop, so a slider drag with J or O on never flashes plain.
                var shown = overlay ? (ClippingOverlay.compose(over: r.image, context: Renderer.shared.context) ?? r.image) : r.image
                if let tinted {
                    let extent = MaskTint.sourceExtent(of: master.extent, maxPixelSize: req.maxPixelSize)
                    shown = MaskTint.compose(over: shown, mask: tinted, recipe: req.recipe, sourceExtent: extent) ?? shown
                }
                return (r.image, shown, r.milliseconds)
            }.value
            guard let self else { return }
            self.rendering = false
            if let result, self.masterURL == req.url {
                self.frame = result.plain
                self.frameGeneration += 1
                self.image = result.shown
                self.imageURL = req.url
                self.imageIsFirstFrame = fromFirstFrame
                self.imageRecipe = req.recipe
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

    /// The 1:1 window: the one chain over the whole full-resolution master,
    /// the output cut to the view's region, never a render of a cropped
    /// input. Kept only if it is still the wanted one and the photo has not
    /// changed. Carries the clipping overlay like the fit frame (the same
    /// per-pixel rule); the histogram stays the fit frame's. In compare mode
    /// the neutral window at the same region is cut in the same hop. A frame
    /// that fits the view whole sends the loupe back to fit instead.
    private func renderZoom(_ req: ZoomRequest, from full: CIImage) {
        Task { [weak self] in
            typealias Window = (image: CGImage, frame: CGSize, region: CGRect, milliseconds: Double,
                                before: CGImage?, beforeRegion: CGRect?)
            let result = await Task.detached(priority: .userInitiated) { () -> Window? in
                guard let r = Renderer.shared.render(full, recipe: req.recipe, region: req.region),
                      let region = r.region else { return nil }
                if ZoomMath.fits(frame: r.frameSize, in: req.region.size) {
                    return (r.image, r.frameSize, region, r.milliseconds, nil, nil)
                }
                var shown = req.overlay ? (ClippingOverlay.compose(over: r.image, context: Renderer.shared.context) ?? r.image) : r.image
                if let id = req.maskOverlay, let mask = req.recipe.masks.first(where: { $0.id == id }) {
                    shown = MaskTint.compose(over: shown, mask: mask, recipe: req.recipe, sourceExtent: full.extent,
                                             window: region) ?? shown
                }
                let b = req.before ? Renderer.shared.render(full, recipe: .neutral, region: req.region) : nil
                return (shown, r.frameSize, region, r.milliseconds, b?.image, b?.region)
            }.value
            guard let self else { return }
            self.rendering = false
            let wanted = self.zoomInFlight == req
            if wanted { self.zoomInFlight = nil }
            if let result, wanted, case .actual = self.zoom, self.masterURL == req.url,
               ZoomMath.fits(frame: result.frame, in: req.region.size) {
                self.zoom = .fit
                self.clearZoomFrame()
            } else if let result, wanted, case .actual = self.zoom, self.masterURL == req.url {
                self.zoomImage = result.image
                self.zoomBeforeImage = result.before
                self.zoomBeforeRegion = result.beforeRegion
                self.zoomURL = req.url
                self.zoomRegion = result.region
                self.zoomFrameSize = result.frame
                self.zoomMilliseconds = result.milliseconds
                self.zoomShown = req
            }
            self.pump()
        }
    }

    /// Turns the clipping overlay on or off. The current frame is re-composed
    /// (or shown plain) without a render; later frames carry the choice. A
    /// 1:1 window is rendered again with the new choice.
    func setClipping(_ on: Bool) {
        guard on != showClipping else { return }
        showClipping = on
        if case .actual = zoom { requestZoom(); pump() }
        // The plain frame lacks the mask tint: render again instead.
        if maskOverlay != nil { renderAgain(); return }
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

    /// Tints mask `id` over the After frame and the 1:1 window, or none.
    /// The newest request is rendered again with the choice (the tint needs
    /// the mask's placement, which only a render has).
    func setMaskOverlay(_ id: UUID?) {
        guard id != maskOverlay else { return }
        maskOverlay = id
        if case .actual = zoom { requestZoom() }
        renderAgain()
    }

    /// The newest request again, so a frame carries a changed overlay.
    private func renderAgain() {
        if let last = lastRequest { pending = last }
        pump()
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

/// The loupe's zoom. `fit` shows the whole rendered frame in the view;
/// `actual` shows it at one image pixel per view pixel (1:1) around
/// `center`, normalised in the rendered frame (after crop and rotate), 0…1
/// on each axis, origin top-left. A centre near an edge is kept as given;
/// the window slides inside the frame when it is cut
/// (`Renderer.Region.rect(in:)`), and `PreviewModel.zoomRegion` says where
/// it landed.
enum PreviewZoom: Equatable, Sendable {
    case fit
    case actual(center: CGPoint)

    /// The centre held to 0…1 on each axis.
    var clamped: PreviewZoom {
        guard case .actual(let c) = self else { return self }
        return .actual(center: CGPoint(x: min(max(c.x, 0), 1), y: min(max(c.y, 0), 1)))
    }
}
