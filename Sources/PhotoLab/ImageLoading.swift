import Foundation
import AppKit
import ImageIO

/// Downsampled decodes through ImageIO: fast, honours EXIF orientation, and
/// reads everything Core Image will later render (JPEG, HEIC, RAW, ...).
/// Chunk 2 replaces the loupe path with the Core Image filter chain; the
/// thumbnail path stays.
enum ImageLoading {
    static func downsampled(_ url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// In-memory thumbnail cache. NSCache is thread-safe; decodes run off the main
/// thread and only visible grid cells ask, so no explicit concurrency cap.
final class Thumbnails {
    static let shared = Thumbnails()
    static let pixelSize = 480

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 3000
        return c
    }()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoading.downsampled(url, maxPixelSize: Thumbnails.pixelSize)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
