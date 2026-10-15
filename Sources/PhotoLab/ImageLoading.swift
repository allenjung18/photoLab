import Foundation
import AppKit
import ImageIO

/// Downsampled decodes through ImageIO: fast, honours EXIF orientation, and
/// reads everything Core Image will later render (JPEG, HEIC, RAW, ...).
/// Thumbnails use the NSImage form; the loupe's preview master is the CGImage
/// form wrapped as a CIImage (see `Renderer.previewMaster`).
enum ImageLoading {
    static func downsampledCGImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func downsampled(_ url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cg = downsampledCGImage(url, maxPixelSize: maxPixelSize) else { return nil }
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
