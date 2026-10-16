import Foundation
import AppKit
import CoreImage
import ImageIO

/// Downsampled decodes through ImageIO: fast, honours EXIF orientation, and
/// reads everything Core Image will later render (JPEG, HEIC, RAW, ...).
/// Thumbnails use the NSImage form; the loupe's preview master is the CGImage
/// form wrapped as a CIImage (see `Renderer.previewMaster`).
///
/// Two steps, cheapest first. The container's own embedded preview is asked
/// for first (`kCGImageSourceCreateThumbnailFromImageIfAbsent`): a camera RAW
/// carries a large one (a Sony ARW a 1616×1080 JPEG) that comes back in
/// ~20 ms where a full RAW decode is ~800 ms. It is accepted only when its
/// long side is at least the requested size (an iPhone JPEG embeds a 320×240
/// thumbnail, which must never fill a 480 px cell); otherwise the image is
/// decoded as before (`kCGImageSourceCreateThumbnailFromImageAlways`). A file
/// with no embedded preview decodes once: `IfAbsent` already falls through to
/// the full image, and that result passes the size rule.
enum ImageLoading {
    /// How a `thumbnail(from:maxPixelSize:)` result was produced.
    enum Source: Equatable {
        /// The container's embedded preview, scaled to `maxPixelSize`.
        case embedded
        /// A decode of the full image (no usable embedded preview).
        case decoded
    }

    static func downsampledCGImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)?.image
    }

    static func downsampled(_ url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cg = downsampledCGImage(url, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The same for a photo id that is a file; nil for an asset, whose
    /// thumbnail is its source's to produce.
    static func downsampled(_ id: PhotoID, maxPixelSize: Int) -> NSImage? {
        guard let url = id.fileURL else { return nil }
        return downsampled(url, maxPixelSize: maxPixelSize)
    }

    /// The thumbnail and where it came from; `downsampledCGImage` drops the
    /// source, tests and benchmarks read it.
    static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> (image: CGImage, source: Source)? {
        if let embedded = embeddedPreview(from: source, maxPixelSize: maxPixelSize) {
            return (embedded, .embedded)
        }
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixelSize, fromImageAlways: true)) else {
            return nil
        }
        return (decoded, .decoded)
    }

    /// The embedded preview, scaled to `maxPixelSize`, or nil when the
    /// container has none large enough: the size rule is "long side at least
    /// the requested size". A file without an embedded preview makes ImageIO
    /// decode the full image here, and that result passes the rule, so such a
    /// file is never decoded twice.
    static func embeddedPreview(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixelSize, fromImageAlways: false)),
              max(candidate.width, candidate.height) >= maxPixelSize else { return nil }
        return candidate
    }

    /// The loupe's first frame (`PreviewModel.load`): the container's embedded
    /// preview as stored, never a decode of the image. Both `FromImage`
    /// options are false, said out loud: left unset, ImageIO decodes the
    /// image when there is no preview. So a file with none gives nil at once.
    /// Accepted only when its long side is at least
    /// `minPixelSize` (ImageIO's 160 px JPEG thumbnail would be a blur on the
    /// loupe) and under `masterPixelSize`: at or above it the preview master
    /// is that same embedded preview (`thumbnail(from:maxPixelSize:)`), as
    /// fast, so nothing needs to come first. A Sony ARW's 1616×1080 preview
    /// passes; its master is a full RAW decode.
    static func firstFrame(from source: CGImageSource, minPixelSize: Int, masterPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: masterPixelSize,
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let long = max(preview.width, preview.height)
        guard long >= minPixelSize, long < masterPixelSize else { return nil }
        return preview
    }

    private static func options(_ maxPixelSize: Int, fromImageAlways: Bool) -> CFDictionary {
        let options: [CFString: Any] = [
            (fromImageAlways ? kCGImageSourceCreateThumbnailFromImageAlways
                             : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return options as CFDictionary
    }
}

/// In-memory thumbnail cache. NSCache is thread-safe; decodes and renders
/// run off the main thread and only visible grid cells ask, so no explicit
/// concurrency cap.
///
/// One cache, keyed by `Key`: a `PhotoID` and the recipe the cell shows. The
/// plain entry (the neutral recipe) is the ImageIO downsample at `pixelSize`,
/// decoded once and kept as the photo's base; an edited photo's entry is that
/// cached base run through the one chain (`Renderer.render`, injected as
/// `render`) and cached under its own key, so the grid shows the edit and a
/// slider release, a batch apply, a sync, an undo or a redo re-keys the
/// visible cells without a decode. A recipe that renders as identity
/// (`Recipe.isNeutral`) is keyed as the plain entry and never rendered.
///
/// A request is cancellable: `ThumbnailCell` asks from `.task(id:)`, which
/// SwiftUI cancels when the cell leaves the screen. `Task.detached` does not
/// inherit that cancellation, so it is forwarded by hand
/// (`withTaskCancellationHandler` cancels the detached handle) and the decode
/// or render body checks it at its start: a cell scrolled past before its
/// turn costs nothing, and a result that finishes for a cancelled request is
/// not cached. The cache, `render` and the injected decoder are `let`; the
/// one mutable field, `source`, sits behind a lock, so the shared instance
/// is safe to use from any task.
///
/// Without an injected decoder (the app's `shared`), the plain entry of a
/// `.file` id is an ImageIO downsample and that of an `.asset` id is asked
/// of `source`, the open `PhotoSource` (`Library.open` sets it): one cache,
/// one decode path per kind of id, never a second cache for a Photos album.
final class Thumbnails: @unchecked Sendable {
    typealias Decoder = @Sendable (PhotoID, Int) -> NSImage?
    /// The chain over a cached plain thumbnail: `Renderer.shared.render` at
    /// the thumbnail's own size in the app; tests inject one that counts.
    typealias Render = @Sendable (CGImage, Recipe) -> CGImage?

    /// What a cell asks for: the photo and the recipe it shows. The recipe is
    /// stored by its render identity, `Recipe.neutral` for anything
    /// `Recipe.isNeutral`, so a disabled-only edit shares the plain entry.
    /// The photo half is the one place the cache's photo key type lives.
    struct Key: Hashable, Sendable {
        let id: PhotoID
        let recipe: Recipe

        init(_ id: PhotoID, recipe: Recipe = .neutral) {
            self.id = id
            self.recipe = recipe.isNeutral ? .neutral : recipe
        }

        /// The plain (unrendered) entry of the photo.
        var isPlain: Bool { recipe == .neutral }
    }

    /// NSCache wants an object key; equality and hash are the `Key`'s.
    private final class CacheKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.key == key }
    }

    static let shared = Thumbnails()
    static let pixelSize = 480

    private let decode: Decoder?
    private let render: Render
    private let cache: NSCache<CacheKey, NSImage> = {
        let c = NSCache<CacheKey, NSImage>()
        c.countLimit = 3000
        return c
    }()
    private let sourceLock = NSLock()
    private var openSource: (any PhotoSource)?


    /// The source `.asset` ids decode through when no decoder is injected.
    var source: (any PhotoSource)? {
        get { sourceLock.lock(); defer { sourceLock.unlock() }; return openSource }
        set { sourceLock.lock(); defer { sourceLock.unlock() }; openSource = newValue }
    }

    /// `decode` nil is the app's rule above (ImageIO for a file, the open
    /// source for an asset) and `render` is `Renderer.shared.render` over the
    /// cached base; tests inject ones that count, block or report what they
    /// saw.
    init(decode: Decoder? = nil,
         render: @escaping Render = { Renderer.shared.render(CIImage(cgImage: $0), recipe: $1)?.image }) {
        self.decode = decode
        self.render = render
    }

    private func produce(_ id: PhotoID, _ pixelSize: Int) -> NSImage? {
        if let decode { return decode(id, pixelSize) }
        if let url = id.fileURL { return ImageLoading.downsampled(url, maxPixelSize: pixelSize) }
        return source?.thumbnail(for: id, maxPixelSize: pixelSize)
    }

    func cached(_ key: Key) -> NSImage? { cache.object(forKey: CacheKey(key)) }

    /// Drops the photo's plain entry and the entry of each recipe given (a
    /// photo moved to the Trash, `Library.moveToTrash`): its cell is gone,
    /// and a file put back at that path decodes afresh.
    func forget(_ id: PhotoID, recipes: [Recipe] = []) {
        for recipe in [Recipe.neutral] + recipes { cache.removeObject(forKey: CacheKey(Key(id, recipe: recipe))) }
    }
    /// A photo renamed in place (`Library.rename`): its plain entry and the
    /// entry of each recipe given move to the new id, so the cell does not
    /// decode again.
    func rename(_ old: PhotoID, to new: PhotoID, recipes: [Recipe] = []) {
        for recipe in [Recipe.neutral] + recipes {
            let from = CacheKey(Key(old, recipe: recipe))
            guard let image = cache.object(forKey: from) else { continue }
            cache.setObject(image, forKey: CacheKey(Key(new, recipe: recipe)))
            cache.removeObject(forKey: from)
        }
    }
    func cached(_ id: PhotoID, recipe: Recipe = .neutral) -> NSImage? { cached(Key(id, recipe: recipe)) }
    func cached(_ url: URL) -> NSImage? { cached(.file(url)) }

    func thumbnail(for url: URL) async -> NSImage? { await thumbnail(for: .file(url)) }

    /// The thumbnail of `id` as `recipe` shows it: the plain decode for a
    /// neutral recipe, else that decode rendered through the chain. Nil when
    /// the request was cancelled or the photo cannot be decoded or rendered.
    func thumbnail(for id: PhotoID, recipe: Recipe = .neutral) async -> NSImage? {
        let key = Key(id, recipe: recipe)
        if let hit = cached(key) { return hit }
        guard let base = await plain(id) else { return nil }
        if key.isPlain { return base }
        let render = render
        let image = await detached { () -> NSImage? in
            guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let out = render(cg, key.recipe) else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: CacheKey(key))
        return image
    }

    /// What a cell should show for `key` after asking for it; the cells'
    /// one rule, kept out of the views so a decode that fails resolves.
    enum CellImage {
        /// A thumbnail to show.
        case image(NSImage)
        /// The photo cannot be decoded (or rendered): show the failed state.
        case failed
        /// Nothing new (the request was cancelled, or the plain image stays).
        case unchanged
    }

    /// The cell's load: the cached entry; else the plain decode (when the
    /// cell shows nothing yet), then the rendered one for an edited recipe.
    /// A nil decode that was not a cancellation is `.failed`, so a file that
    /// will not decode never leaves its cell spinning.
    func resolve(_ key: Key, showing current: NSImage?) async -> CellImage {
        if let hit = cached(key) { return .image(hit) }
        var shown = current
        if shown == nil {
            guard let plain = await thumbnail(for: key.id) else {
                return Task.isCancelled ? .unchanged : .failed
            }
            shown = plain
        }
        if !key.isPlain {
            if let rendered = await thumbnail(for: key.id, recipe: key.recipe) { return .image(rendered) }
        }
        if let shown, shown !== current { return .image(shown) }
        return .unchanged
    }

    /// The photo's plain entry: the cached decode, else one decode, cached.
    private func plain(_ id: PhotoID) async -> NSImage? {
        let key = Key(id)
        if let hit = cached(key) { return hit }
        let pixelSize = Thumbnails.pixelSize
        guard let image = await detached({ self.produce(id, pixelSize) }) else { return nil }
        cache.setObject(image, forKey: CacheKey(key))
        return image
    }

    /// Runs `work` on a detached task with the caller's cancellation
    /// forwarded into it, and drops a result that lands after a cancel.
    private func detached<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        // Already scrolled past before the work was queued: nothing to do.
        if Task.isCancelled { return nil }
        let handle = Task.detached(priority: .userInitiated) { () -> T? in
            // Cancelled while waiting for a core (forwarded below): skip the work.
            if Task.isCancelled { return nil }
            return work()
        }
        let value = await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
        guard let value, !Task.isCancelled else { return nil }
        return value
    }
}
