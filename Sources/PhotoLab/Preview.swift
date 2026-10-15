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

    private var master: CIImage?
    private var masterURL: URL?
    private var loadTask: Task<Void, Never>?
    private var pending: Request?
    private var rendering = false

    private struct Request {
        let url: URL
        let recipe: Recipe
        let maxPixelSize: Int
    }

    /// Decodes the master for `url` off the main thread, then renders the
    /// request that is waiting (if any).
    func load(_ url: URL) {
        guard url != masterURL else { return }
        loadTask?.cancel()
        master = nil
        masterURL = url
        let size = Self.masterPixelSize
        loadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Renderer.previewMaster(url, maxPixelSize: size)
            }.value
            guard let self, !Task.isCancelled, self.masterURL == url else { return }
            self.master = decoded
            self.masterSize = decoded?.extent.size ?? .zero
            self.pump()
        }
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
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Renderer.shared.render(master, recipe: req.recipe, maxPixelSize: req.maxPixelSize)
            }.value
            guard let self else { return }
            self.rendering = false
            if let result, self.masterURL == req.url {
                self.image = result.image
                self.imageURL = req.url
                self.renderMilliseconds = result.milliseconds
            }
            self.pump()
        }
    }
}
