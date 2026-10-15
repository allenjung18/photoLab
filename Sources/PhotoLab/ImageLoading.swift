import Foundation
import AppKit
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

/// In-memory thumbnail cache. NSCache is thread-safe; decodes run off the main
/// thread and only visible grid cells ask, so no explicit concurrency cap.
///
/// A request is cancellable: `ThumbnailCell` asks from `.task(id:)`, which
/// SwiftUI cancels when the cell leaves the screen. `Task.detached` does not
/// inherit that cancellation, so it is forwarded by hand
/// (`withTaskCancellationHandler` cancels the detached handle) and the decode
/// body checks it at its start: a cell scrolled past before its decode got a
/// core costs nothing, and a decode that finishes for a cancelled request is
/// not cached.
final class Thumbnails {
    typealias Decoder = @Sendable (URL, Int) -> NSImage?

    static let shared = Thumbnails()
    static let pixelSize = 480

    private let decode: Decoder
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 3000
        return c
    }()

    /// `decode` is `ImageLoading.downsampled` in the app; tests inject one
    /// that counts, blocks or reports what it saw.
    init(decode: @escaping Decoder = { ImageLoading.downsampled($0, maxPixelSize: $1) }) {
        self.decode = decode
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        // Already scrolled past before the decode was queued: nothing to do.
        if Task.isCancelled { return nil }
        let decode = decode
        let pixelSize = Thumbnails.pixelSize
        let handle = Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Cancelled while waiting for a core (forwarded below): skip the decode.
            if Task.isCancelled { return nil }
            return decode(url, pixelSize)
        }
        let image = await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
        guard let image, !Task.isCancelled else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
