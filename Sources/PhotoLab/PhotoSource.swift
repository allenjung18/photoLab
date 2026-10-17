import Foundation
import AppKit

/// A photo's identity: the file it is, or the library asset it is. Every
/// `Library` map (recipes, marks, history, the selection) is keyed by it,
/// so where a photo's pixels and its name come from is the source's
/// business (`PhotoSource`), never the library's. A folder photo is its
/// file URL; a Photos asset is its `localIdentifier` (`UUID/L0/001`).
///
/// A virtual copy (`copy`) is a second identity of one file or asset: its
/// master's id plus a copy number from 2 (`Library.createVirtualCopy`). It
/// has its own recipe, marks and sidecar (`SidecarStore.relativeName`), and
/// reads its master's pixels: `fileURL` is the master's file, and every
/// source maps a copy to its master before reading. A copy's master is
/// never itself a copy (`copy(of:number:)` flattens).
enum PhotoID: Hashable, Codable, Sendable {
    case file(URL)
    case asset(String)
    indirect case copy(PhotoID, Int)

    /// The first copy number: the master is copy 1, implicitly.
    static let firstCopyNumber = 2

    /// Copy `number` of `master`'s master (a copy of a copy is a copy of
    /// the same master).
    static func copy(of master: PhotoID, number: Int) -> PhotoID {
        .copy(master.master, number)
    }

    /// The photo whose file or asset this id reads: itself for a master,
    /// the master for a virtual copy.
    var master: PhotoID {
        if case .copy(let m, _) = self { return m.master }
        return self
    }

    /// The copy number of a virtual copy (2, 3, …); nil for a master.
    var copyNumber: Int? {
        if case .copy(_, let n) = self { return n }
        return nil
    }

    var isCopy: Bool { copyNumber != nil }

    /// The file when the identity is one (a copy: its master's file); nil
    /// for an asset, whose file is asked of its source
    /// (`PhotoSource.originalFile(for:)`).
    var fileURL: URL? {
        switch self {
        case .file(let url): return url
        case .asset: return nil
        case .copy(let m, _): return m.fileURL
        }
    }

    /// The name a photo has when its source gives none: the file name, or
    /// the asset identifier itself; a copy's is its master's (one file).
    var defaultName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .asset(let id): return id
        case .copy(let m, _): return m.defaultName
        }
    }

    /// A stable string for cache keys: no two ids share one, so a copy's
    /// thumbnail is its own, never its master's.
    var cacheKey: String {
        switch self {
        case .file(let url): return "file:" + url.absoluteString
        case .asset(let id): return "asset:" + id
        case .copy(let m, let n): return m.cacheKey + "#copy" + String(n)
        }
    }
}

/// One photo of the open source: its identity and its display name, plus
/// the file when the identity is one (`fileURL`, a shortcut for `.file`
/// ids; nil for an asset until the source materialises its original), and
/// the capture date when the listing carries one (a Photos asset's
/// `creationDate`; nil for a file, whose date `CaptureDates` reads on
/// demand), and the GPS position when the listing carries one (a Photos
/// asset's `PHAsset.location`; nil for a file, whose position the map reads
/// from its header through `PhotoInfoStore`).
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
    /// The listing's GPS position (`PhotosAsset.location`); nil for a file.
    let location: GeoPoint?
    /// A folder RAW's paired JPEG or HEIC (same folder, same name; D-474):
    /// one photo per shot, the RAW decoded, edited and exported, the
    /// companion moved with it by Trash and Rename. nil for anything else
    /// (`Library.pairRawAndJPEG`).
    private(set) var companion: URL?

    /// `name` nil: the listing did not name the photo (`isNamed` false).
    init(id: PhotoID, name: String?, captureDate: Date? = nil, location: GeoPoint? = nil) {
        self.id = id
        self.name = name ?? id.defaultName
        self.isNamed = name != nil
        self.fileURL = id.fileURL
        self.captureDate = captureDate
        self.location = location
        self.companion = nil
    }

    /// "RAW+JPG" (or "RAW+HEIC") for a paired RAW, from the companion's
    /// extension (JPEG and JPE read as JPG); nil when unpaired.
    var pairLabel: String? {
        guard let ext = companion?.pathExtension.uppercased(), !ext.isEmpty else { return nil }
        return "RAW+" + (["JPEG", "JPE"].contains(ext) ? "JPG" : ext)
    }

    /// This photo with `companion` paired to it (nil unpairs).
    func paired(with companion: URL?) -> Photo {
        var p = self
        p.companion = companion
        return p
    }

    /// What a cell's caption and tooltip show: the name, or nothing while
    /// the photo is unnamed (never the asset identifier); a virtual copy's
    /// is its master's name plus `copyLabel` ("IMG_0001.JPG Copy 2"; the
    /// label alone while unnamed).
    var caption: String {
        guard let copyLabel else { return isNamed ? name : "" }
        return isNamed ? name + " " + copyLabel : copyLabel
    }

    /// "Copy 2" for virtual copy 2; nil for a master.
    var copyLabel: String? { id.copyNumber.map { "Copy \($0)" } }

    /// Virtual copy `number` of this photo: the same name, capture date and
    /// position (one file), its own id (`PhotoID.copy(of:number:)`).
    func virtualCopy(number: Int) -> Photo {
        Photo(id: .copy(of: id, number: number), name: isNamed ? name : nil,
              captureDate: captureDate, location: location)
    }

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

/// Where a `Library`'s photos come from: a folder (`FolderSource`), a
/// Photos album (`PhotosSource`) or a saved collection (`CollectionSource`).
/// The library lists `photos()` once at `open`, keeps every edit in
/// `sidecars(for:)`, and asks the source for pixels: a grid thumbnail
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
    /// The store one photo's edit persists to: `sidecars` for a folder and
    /// an album; a collection member's own root (`CollectionSource`), so
    /// the edit is the file that member's folder reads. `Library.persist`
    /// writes through it.
    func sidecars(for id: PhotoID) -> SidecarStore
    /// Every listed photo's sidecar, read at `open` (`sidecars.loadAll` for
    /// one store; a collection reads each root's store for its members).
    func loadSidecars(for ids: [PhotoID]) -> SidecarStore.Loaded
    /// A downsampled image of the unadjusted original, or nil when it
    /// cannot be produced.
    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage?
    /// The file holding the photo's original pixels, for the one decode
    /// path (`Renderer.previewMaster`, `Renderer.fullResolution`).
    func originalFile(for id: PhotoID) async throws -> URL
    /// The virtual copies whose sidecar sits beside one of `ids`'s
    /// (`SidecarStore.copies(of:)`): read at `open`, each listed after its
    /// master. A copy file whose master is not among `ids` is not returned
    /// (and left on disk).
    func virtualCopies(of ids: [PhotoID]) -> [PhotoID]
    /// The name of a photo `photos()` listed unnamed (`Photo.isNamed`
    /// false), or nil. Synchronous: `Library.resolveName(_:)` calls it off
    /// the main thread, one visible cell at a time, and it may check
    /// `Task.isCancelled` first.
    func name(for id: PhotoID) -> String?
}

extension PhotoSource {
    /// A source whose listing names every photo is never asked.
    func name(for id: PhotoID) -> String? { nil }

    /// One store for every photo.
    func sidecars(for id: PhotoID) -> SidecarStore { sidecars }

    func loadSidecars(for ids: [PhotoID]) -> SidecarStore.Loaded { sidecars.loadAll(for: ids) }

    /// Each photo's own store (`sidecars(for:)`) listed once for the
    /// copies of the photos it holds.
    func virtualCopies(of ids: [PhotoID]) -> [PhotoID] {
        var byStore: [URL: [PhotoID]] = [:]
        var order: [URL] = []
        for id in ids where !id.isCopy {
            let dir = sidecars(for: id).directory
            if byStore[dir] == nil { order.append(dir) }
            byStore[dir, default: []].append(id)
        }
        return order.flatMap { dir -> [PhotoID] in
            let group = byStore[dir]!
            return sidecars(for: group[0]).copies(of: group)
        }
    }
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

    /// Every image under the folder, a RAW+JPEG shot as one photo
    /// (`Library.pairRawAndJPEG`) unless the JPEG carries its own edit,
    /// marks, keywords or virtual copy in this folder's store or in the
    /// store of any folder above the file (a parent opened once keeps
    /// `sub/a.jpg.json`; D-474 (a)).
    func photos() throws -> [Photo] {
        Library.pairRawAndJPEG(Library.scan(folder)) { id in
            guard let file = id.fileURL else { return false }
            var dir = file.deletingLastPathComponent().standardizedFileURL
            while true {
                let store = SidecarStore(folder: dir)
                if store.exists(for: id) || !store.copies(of: [id]).isEmpty { return true }
                let up = dir.deletingLastPathComponent().standardizedFileURL
                if up.path == dir.path { return false }
                dir = up
            }
        }
    }

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
