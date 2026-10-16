import Foundation
import AppKit

/// A photo's identity: the file it is, or the library asset it is. Every
/// `Library` map (recipes, marks, history, the selection) is keyed by it,
/// so where a photo's pixels and its name come from is the source's
/// business (`PhotoSource`), never the library's. A folder photo is its
/// file URL; a Photos asset is its `localIdentifier` (`UUID/L0/001`).
enum PhotoID: Hashable, Codable, Sendable {
    case file(URL)
    case asset(String)

    /// The file when the identity is one; nil for an asset, whose file is
    /// asked of its source (`PhotoSource.originalFile(for:)`).
    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    /// The name a photo has when its source gives none: the file name, or
    /// the asset identifier itself.
    var defaultName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .asset(let id): return id
        }
    }

    /// A stable string for cache keys: the two cases never collide.
    var cacheKey: String {
        switch self {
        case .file(let url): return "file:" + url.absoluteString
        case .asset(let id): return "asset:" + id
        }
    }
}

/// One photo of the open source: its identity and its display name, plus
/// the file when the identity is one (`fileURL`, a shortcut for `.file`
/// ids; nil for an asset until the source materialises its original), and
/// the capture date when the listing carries one (a Photos asset's
/// `creationDate`; nil for a file, whose date `CaptureDates` reads on
/// demand).
///
/// A listing may leave a photo unnamed (a Photos album: reading an asset's
/// original file name is a resource read per asset, so it is asked per
/// visible cell instead, `Library.resolveName(_:)`). Such a photo has
/// `isNamed` false and `name` the id's own name until the source names it.
struct Photo: Identifiable, Hashable, Sendable {
    let id: PhotoID
    /// The source's name for the photo; `id.defaultName` while `isNamed` is false.
    private(set) var name: String
    /// False while the source has not named the photo yet.
    private(set) var isNamed: Bool
    let fileURL: URL?
    let captureDate: Date?

    /// `name` nil: the listing did not name the photo (`isNamed` false).
    init(id: PhotoID, name: String?, captureDate: Date? = nil) {
        self.id = id
        self.name = name ?? id.defaultName
        self.isNamed = name != nil
        self.fileURL = id.fileURL
        self.captureDate = captureDate
    }

    /// What a cell's caption and tooltip show: the name, or nothing while
    /// the photo is unnamed (never the asset identifier).
    var caption: String { isNamed ? name : "" }

    /// The photo with the name its source resolved.
    func named(_ name: String) -> Photo {
        var p = self
        p.name = name
        p.isNamed = true
        return p
    }

    /// A photo in a folder: identity, name and file are all the URL.
    init(url: URL) {
        self.init(id: .file(url), name: url.lastPathComponent)
    }
}

/// Where a `Library`'s photos come from: a folder today, a Photos album
/// next. The library lists `photos()` once at `open`, keeps every edit in
/// `sidecars`, and asks the source for pixels: a grid thumbnail
/// (`thumbnail(for:maxPixelSize:)`, synchronous, called off the main thread
/// by `Thumbnails`) and the one original file the loupe master and the
/// export decode (`originalFile(for:)`, which a source may have to fetch
/// first). Originals are read, never written.
protocol PhotoSource: Sendable {
    /// What the window title shows for this source.
    var title: String { get }
    /// The photos, in any order: the library sorts them (`PhotoSort`).
    func photos() throws -> [Photo]
    /// The store this source's edits persist to.
    var sidecars: SidecarStore { get }
    /// A downsampled image of the unadjusted original, or nil when it
    /// cannot be produced.
    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage?
    /// The file holding the photo's original pixels, for the one decode
    /// path (`Renderer.previewMaster`, `Renderer.fullResolution`).
    func originalFile(for id: PhotoID) async throws -> URL
    /// The name of a photo `photos()` listed unnamed (`Photo.isNamed`
    /// false), or nil. Synchronous: `Library.resolveName(_:)` calls it off
    /// the main thread, one visible cell at a time, and it may check
    /// `Task.isCancelled` first.
    func name(for id: PhotoID) -> String?
}

extension PhotoSource {
    /// A source whose listing names every photo is never asked.
    func name(for id: PhotoID) -> String? { nil }
}

/// A folder of photos: `Library.scan` lists it, `SidecarStore(folder:)`
/// keeps the edits in `<folder>/.photolab/`, ImageIO downsamples the
/// thumbnails, and a photo's original is its own file.
struct FolderSource: PhotoSource {
    let folder: URL

    init(_ folder: URL) {
        self.folder = folder
    }

    var title: String { folder.lastPathComponent }

    func photos() throws -> [Photo] { Library.scan(folder) }

    var sidecars: SidecarStore { SidecarStore(folder: folder) }

    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? {
        ImageLoading.downsampled(id, maxPixelSize: maxPixelSize)
    }

    func originalFile(for id: PhotoID) async throws -> URL {
        guard let url = id.fileURL else { throw PhotoSourceError.notInThisSource(id) }
        return url
    }
}

enum PhotoSourceError: LocalizedError, Equatable {
    /// The id is not one this source can produce a file for.
    case notInThisSource(PhotoID)

    var errorDescription: String? {
        switch self {
        case .notInThisSource(let id): return "\(id.defaultName) is not in the open library."
        }
    }
}
