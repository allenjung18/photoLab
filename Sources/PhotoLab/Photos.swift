import Foundation
import SwiftUI
import AppKit
import Photos
import UniformTypeIdentifiers

// MARK: - The seam to PhotoKit

/// Photos access as the app sees it. `.limited` (the user picked some
/// photos) reads like `.authorized`; the two refusals differ only in what
/// the sheet says (System Settings for `.denied`, nothing to do for
/// `.restricted`).
enum PhotosAuthorization: Equatable, Sendable {
    case notDetermined, authorized, limited, denied, restricted

    /// True when albums and assets may be fetched.
    var canRead: Bool { self == .authorized || self == .limited }

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}

/// One album of the library: Recents (the user library smart album) or a
/// regular album, by its collection's `localIdentifier`.
struct PhotosAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Image assets in it (what the grid would show).
    let count: Int
    let isRecents: Bool
}

/// One image asset as listed: its `localIdentifier` (`UUID/L0/001`, the
/// `PhotoID.asset` form) and the file name of the original resource that
/// `PhotosSource.originalFile(for:)` writes out (the RAW of a RAW+JPEG
/// pair, else the photo itself).
struct PhotosAsset: Hashable, Sendable {
    let id: String
    let originalFilename: String
}

/// Everything `PhotosSource` asks of PhotoKit, so a test can stand in a
/// complete fake (`PhotosTests`) and nothing in the app touches a
/// `PHAsset` outside `PhotoKitLive`. Every call is synchronous but the
/// two that are not in PhotoKit either; `thumbnail` runs off the main
/// thread inside `Thumbnails` and may check `Task.isCancelled` first.
protocol PhotoKitClient: Sendable {
    /// The current status, never a prompt.
    func authorizationStatus() -> PhotosAuthorization
    /// Shows the system dialog: called only from the sheet's button (the
    /// user's click), never at launch and never from a test.
    func requestAuthorization() async -> PhotosAuthorization
    /// Recents first, then the regular albums by title.
    func albums() -> [PhotosAlbum]
    /// The album's images, oldest capture first.
    func assets(in album: PhotosAlbum) -> [PhotosAsset]
    /// A downsample of the UNADJUSTED asset (PhotoLab edits the original;
    /// an edit made in Photos is not shown), or nil.
    func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage?
    /// Writes the asset's original resource to `url` (iCloud originals are
    /// downloaded first). The file at `url` is complete when this returns.
    func writeOriginal(of assetID: String, to url: URL) async throws
    /// Whether Photos holds an edit of the asset, any app's
    /// (`PHAsset.hasAdjustments`). Cheap: no content-editing input.
    func hasAdjustments(_ assetID: String) -> Bool
    /// The adjustment data of the asset's current edit when it is
    /// PhotoLab's (any version: the caller refuses one too new), else nil.
    /// Asks a content-editing input whose `canHandleAdjustmentData` accepts
    /// PhotoLab's format identifier; another app's data never comes back
    /// from PhotoKit (a fake may hand it back, and `PhotosAdjustment.recipe()`
    /// ignores it).
    func adjustment(of assetID: String) async throws -> PhotosAdjustment?
    /// Writes an edit onto the asset, non-destructively: a content-editing
    /// input asked with `PhotosAdjustment.canHandle` (PhotoLab's data at a
    /// version this build reads), `render` writing the full-size JPEG to the
    /// URL it is handed (the output's rendered content), then ONE
    /// `performChanges` committing the output with `adjustment` as its data.
    /// Photos keeps the original (Revert to Original) and one edit per
    /// asset, so a second save replaces the first. Photos may ask the user
    /// to allow the change; that is the user's click.
    func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                  render: @escaping @Sendable (URL) throws -> Void) async throws
}

/// A PhotoLab edit as Photos stores it beside an asset (`PHAdjustmentData`):
/// format identifier `local.photolab.recipe`, format version
/// `Sidecar.currentVersion`, and as data the recipe-only sidecar JSON (no
/// flag or rating: marks are not an edit). Photos syncs it with the library
/// and hands it back on a content-editing input, which is how a photo whose
/// sidecar is gone gets its recipe back (`PhotosSource.recoverRecipe`).
struct PhotosAdjustment: Equatable, Sendable {
    static let formatIdentifier = "local.photolab.recipe"

    let formatIdentifier: String
    let formatVersion: String
    let data: Data

    init(formatIdentifier: String, formatVersion: String, data: Data) {
        self.formatIdentifier = formatIdentifier
        self.formatVersion = formatVersion
        self.data = data
    }

    /// PhotoLab's data for `recipe`; `name` is the sidecar's `original`.
    init(recipe: Recipe, name: String, now: Date = Date()) throws {
        let doc = Sidecar(original: name, updated: now, recipe: recipe)
        self.init(formatIdentifier: Self.formatIdentifier, formatVersion: String(Sidecar.currentVersion),
                  data: try SidecarStore.encode(doc))
    }

    /// The live client's `canHandleAdjustmentData` for a save: PhotoLab's
    /// identifier at a version this build reads.
    static func canHandle(identifier: String, version: String) -> Bool {
        guard identifier == formatIdentifier, let v = Int(version) else { return false }
        return v <= Sidecar.currentVersion
    }

    /// The recipe the data holds. Nil for another app's data (a different
    /// identifier: the photo shows its original). PhotoLab data of a version
    /// above `Sidecar.currentVersion` (the format version or the JSON's own)
    /// throws `SidecarError.unsupportedVersion`, like a sidecar a newer
    /// PhotoLab wrote; data that does not decode throws its decoding error.
    func recipe() throws -> Recipe? {
        guard formatIdentifier == Self.formatIdentifier else { return nil }
        if let v = Int(formatVersion), v > Sidecar.currentVersion { throw SidecarError.unsupportedVersion(v) }
        return try SidecarStore.decode(data).recipe
    }
}

enum PhotosError: LocalizedError, Equatable {
    /// Listing or fetching was asked before the user allowed access.
    case notAuthorized(PhotosAuthorization)
    /// The asset is no longer in the library.
    case assetMissing(String)
    /// The asset has no original resource to write out.
    case noOriginal(String)
    /// Photos did not create an asset from the exported file.
    case cannotImport(String)
    /// Photos gave no content-editing input for the asset.
    case cannotEdit(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(.notDetermined): return "Photos access has not been allowed yet."
        case .notAuthorized: return "Photos access is not allowed. Allow it in System Settings › Privacy & Security › Photos."
        case .assetMissing(let id): return "The photo \(id) is no longer in the library."
        case .noOriginal(let id): return "The photo \(id) has no original to open."
        case .cannotImport(let name): return "Photos could not import \(name)."
        case .cannotEdit(let id): return "Photos could not open the photo \(id) for editing."
        }
    }
}

// MARK: - The live client

/// The real PhotoKit. Needs an app bundle: TCC keys Photos access to a
/// bundle identifier and the NSPhotoLibraryUsageDescription string, both
/// written by scripts/bundle.sh into build/PhotoLab.app; under a bare
/// `swift run` (or the `xctest` host) nothing here fetches, and nothing
/// here ever prompts except `requestAuthorization`.
struct PhotoKitLive: PhotoKitClient {
    init() {}

    private var canRead: Bool { authorizationStatus().canRead }

    func authorizationStatus() -> PhotosAuthorization {
        PhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotosAuthorization {
        PhotosAuthorization(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func albums() -> [PhotosAlbum] {
        guard canRead else { return [] }
        var out: [PhotosAlbum] = []
        if let recents = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary,
                                                                 options: nil).firstObject {
            out.append(album(recents, isRecents: true))
        }
        let byTitle = PHFetchOptions()
        byTitle.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let regular = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: byTitle)
        regular.enumerateObjects { collection, _, _ in
            out.append(album(collection, isRecents: false))
        }
        return out
    }

    private func album(_ collection: PHAssetCollection, isRecents: Bool) -> PhotosAlbum {
        PhotosAlbum(id: collection.localIdentifier,
                    title: collection.localizedTitle ?? (isRecents ? "Recents" : "Untitled"),
                    count: PHAsset.fetchAssets(in: collection, options: Self.assetFetchOptions()).count,
                    isRecents: isRecents)
    }

    /// Images only, oldest capture first (Lightroom's capture-time order).
    static func assetFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    func assets(in album: PhotosAlbum) -> [PhotosAsset] {
        guard canRead,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id],
                                                                      options: nil).firstObject else { return [] }
        let fetched = PHAsset.fetchAssets(in: collection, options: Self.assetFetchOptions())
        var out: [PhotosAsset] = []
        out.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            let name = Self.originalResource(of: asset)?.originalFilename ?? asset.localIdentifier
            out.append(PhotosAsset(id: asset.localIdentifier, originalFilename: name))
        }
        return out
    }

    private func asset(_ id: String) -> PHAsset? {
        guard canRead else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The resource PhotoLab decodes: the RAW of a pair when there is one
    /// (`.alternatePhoto` or `.photo`, whichever conforms to
    /// `public.camera-raw-image`), else the photo itself.
    static func originalResource(of asset: PHAsset) -> PHAssetResource? {
        let originals = PHAssetResource.assetResources(for: asset).filter {
            $0.type == .photo || $0.type == .alternatePhoto
        }
        if let raw = originals.first(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) {
            return raw
        }
        return originals.first { $0.type == .photo } ?? originals.first
    }

    /// `PHImageManager`, synchronous (the caller is `Thumbnails`' detached
    /// decode): 480 px aspect-fit of the unadjusted asset, high quality,
    /// fast resize, iCloud allowed. A request already cancelled asks nothing.
    func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage? {
        guard !Task.isCancelled, let asset = asset(assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.version = .unadjusted
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        let result = Box<NSImage>()
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: maxPixelSize, height: maxPixelSize),
            contentMode: .aspectFit, options: options
        ) { image, _ in
            result.value = image
        }
        return result.value
    }

    /// `PHAssetResourceManager.writeData(for:toFile:options:)` of the
    /// original resource, iCloud allowed; the completion is the resume.
    func writeOriginal(of assetID: String, to url: URL) async throws {
        guard let asset = asset(assetID) else { throw PhotosError.assetMissing(assetID) }
        guard let resource = Self.originalResource(of: asset) else { throw PhotosError.noOriginal(assetID) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func hasAdjustments(_ assetID: String) -> Bool {
        asset(assetID)?.hasAdjustments ?? false
    }

    func adjustment(of assetID: String) async throws -> PhotosAdjustment? {
        guard let asset = asset(assetID) else { throw PhotosError.assetMissing(assetID) }
        guard asset.hasAdjustments else { return nil }
        let input = try await contentEditingInput(for: asset) {
            $0.formatIdentifier == PhotosAdjustment.formatIdentifier
        }
        guard let data = input.value?.adjustmentData else { return nil }
        return PhotosAdjustment(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion,
                                data: data.data)
    }

    func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                  render: @escaping @Sendable (URL) throws -> Void) async throws {
        let status = authorizationStatus()
        guard status.canRead else { throw PhotosError.notAuthorized(status) }
        guard let asset = asset(assetID) else { throw PhotosError.assetMissing(assetID) }
        let input = try await contentEditingInput(for: asset) {
            PhotosAdjustment.canHandle(identifier: $0.formatIdentifier, version: $0.formatVersion)
        }
        guard let editing = input.value else { throw PhotosError.cannotEdit(assetID) }
        let output = PHContentEditingOutput(contentEditingInput: editing)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: adjustment.formatIdentifier,
                                                 formatVersion: adjustment.formatVersion, data: adjustment.data)
        try render(try output.renderedContentURL(for: .jpeg))
        let edit = Box(output)
        try await PHPhotoLibrary.shared().performChanges {
            guard let target = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: target).contentEditingOutput = edit.value
        }
    }

    /// `requestContentEditingInput`, iCloud allowed, with `canHandle` as
    /// the options' `canHandleAdjustmentData`; the completion is the resume.
    /// When `canHandle` accepts the asset's data, the input carries it and
    /// its image is the unadjusted original (PhotoLab never reads that
    /// image: it renders from its cached original).
    private func contentEditingInput(for asset: PHAsset,
                                     canHandle: @escaping @Sendable (PHAdjustmentData) -> Bool) async throws
        -> Box<PHContentEditingInput> {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = canHandle
        let id = asset.localIdentifier
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Box<PHContentEditingInput>, Error>) in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: Box(input))
                } else if let error = info[PHContentEditingInputErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotosError.cannotEdit(id))
                }
            }
        }
    }

    /// A result slot for a synchronous callback, or a PhotoKit object
    /// carried across a concurrency boundary it is only read on.
    fileprivate final class Box<T>: @unchecked Sendable {
        var value: T?
        init(_ value: T? = nil) { self.value = value }
    }
}

// MARK: - Export back into Photos

/// What an export to the Photos library asks of PhotoKit: the status and
/// the user's Allow click (the export sheet's, never a test's), and the
/// import of one rendered file. `PhotoKitLive` is the real one; tests use a
/// fake (`ExportTests`).
protocol PhotosWriter: Sendable {
    /// The current status, never a prompt.
    func authorizationStatus() -> PhotosAuthorization
    /// Shows the system dialog: only from the export sheet's button.
    func requestAuthorization() async -> PhotosAuthorization
    /// Imports the image file at `url` as a NEW asset and, when `album` is
    /// given, adds it to the regular album of that title, created when there
    /// is none. Returns the new asset's `localIdentifier`. The file is read
    /// during the call; the caller removes it afterwards.
    func importImage(at url: URL, intoAlbum album: String?) async throws -> String
}

extension PhotoKitLive: PhotosWriter {
    /// One `performChanges`: `creationRequestForAssetFromImage(atFileURL:)`,
    /// then the placeholder added to the album (the existing one by title,
    /// or a `creationRequestForAssetCollection(withTitle:)`).
    func importImage(at url: URL, intoAlbum album: String?) async throws -> String {
        let status = authorizationStatus()
        guard status.canRead else { throw PhotosError.notAuthorized(status) }
        let existingID = album.flatMap(Self.regularAlbum(titled:))?.localIdentifier
        let created = Box<String>()
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url),
                  let placeholder = request.placeholderForCreatedAsset else { return }
            created.value = placeholder.localIdentifier
            guard let album else { return }
            let existing = existingID.flatMap {
                PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            let albumRequest = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            albumRequest.addAssets([placeholder] as NSArray)
        }
        guard let id = created.value else { throw PhotosError.cannotImport(url.lastPathComponent) }
        return id
    }

    /// The first regular album whose title is `title` (titles are not
    /// unique in Photos; the first wins, as in a Lightroom publish service).
    static func regularAlbum(titled title: String) -> PHAssetCollection? {
        let regular = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        regular.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title { found = collection; stop.pointee = true }
        }
        return found
    }
}

// MARK: - The source

/// The directories and the client a Photos album opens with: the live
/// ones in the app, a fake and two temp dirs in a test.
struct PhotosAccess: Sendable {
    let client: any PhotoKitClient
    /// Sidecars of Photos assets (flat naming: `UUID_L0_001.json`).
    let sidecarDirectory: URL
    /// Cached copies of the originals (`<safe-id>.<ext>`), removable.
    let originalsDirectory: URL

    /// Only an app bundle can be granted Photos access (TCC); a bare
    /// `swift run` has none, and the Welcome view says so.
    static let hasBundle = Bundle.main.bundleIdentifier != nil

    static var live: PhotosAccess {
        PhotosAccess(client: PhotoKitLive(), sidecarDirectory: defaultSidecarDirectory,
                     originalsDirectory: defaultOriginalsDirectory)
    }

    /// `~/Library/Application Support/PhotoLab/photos-sidecars/`.
    static var defaultSidecarDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoLab/photos-sidecars", isDirectory: true)
    }

    /// `~/Library/Caches/PhotoLab/originals/`.
    static var defaultOriginalsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoLab/originals", isDirectory: true)
    }

    func source(for album: PhotosAlbum) -> PhotosSource {
        PhotosSource(album: album, access: self)
    }
}

/// One Photos album as a `PhotoSource`. Listing needs authorization
/// (`photos()` throws `PhotosError.notAuthorized` before it, so `Library`
/// refuses the open and nothing is fetched); names are the originals'
/// file names; thumbnails come from Photos' own cache through the client;
/// an original is written ONCE into `originalsDirectory` and read from
/// there by the loupe master and the export (`OriginalsCache`). Sidecars
/// take the flat naming under `sidecarDirectory`.
struct PhotosSource: PhotoSource {
    let album: PhotosAlbum
    let client: any PhotoKitClient
    let sidecarDirectory: URL
    let originals: OriginalsCache

    init(album: PhotosAlbum, access: PhotosAccess) {
        self.album = album
        self.client = access.client
        self.sidecarDirectory = access.sidecarDirectory
        self.originals = OriginalsCache(directory: access.originalsDirectory)
    }

    var title: String { album.title }

    func photos() throws -> [Photo] {
        let status = client.authorizationStatus()
        guard status.canRead else { throw PhotosError.notAuthorized(status) }
        let assets = client.assets(in: album)
        originals.remember(assets)
        return assets.map { Photo(id: .asset($0.id), name: $0.originalFilename) }
    }

    var sidecars: SidecarStore { SidecarStore(directory: sidecarDirectory, naming: .flat) }

    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? {
        guard case .asset(let assetID) = id, client.authorizationStatus().canRead else { return nil }
        return client.thumbnail(for: assetID, maxPixelSize: maxPixelSize)
    }

    func originalFile(for id: PhotoID) async throws -> URL {
        guard case .asset(let assetID) = id else { throw PhotoSourceError.notInThisSource(id) }
        return try await originals.file(for: assetID, client: client)
    }

    /// How a Save to Photos renders: JPEG (PhotoKit's rendered content is
    /// JPEG, a RAW original's too), full size, the original's metadata.
    static let saveOptions = ExportOptions(format: .jpeg, quality: 0.9, resize: nil, keepMetadata: true)

    /// Save to Photos: writes `recipe` into the library as the asset's edit
    /// (`PhotoKitClient.saveEdit`), the data `PhotosAdjustment(recipe:)` and
    /// the rendered content the FULL-SIZE render of the cached original
    /// (`originalFile(for:)`) through `Exporter.write`, the one render path;
    /// never the input's own image, which for another app's edit is that
    /// app's render. The sidecar is untouched: it stays the primary record.
    func saveEdit(_ recipe: Recipe, for id: PhotoID, name: String, renderer: Renderer = .shared) async throws {
        guard case .asset(let assetID) = id else { throw PhotoSourceError.notInThisSource(id) }
        let original = try await originalFile(for: id)
        let adjustment = try PhotosAdjustment(recipe: recipe, name: name)
        try await client.saveEdit(adjustment, to: assetID) { url in
            try Exporter.write(original, recipe: recipe, to: url, options: Self.saveOptions, renderer: renderer)
        }
    }

    /// The recipe Photos holds for the asset as PhotoLab's adjustment data,
    /// for a photo with no sidecar (`Library.recoverRecipe`). Nil when
    /// access is not allowed, the asset has no edit (`hasAdjustments`; no
    /// content-editing input is asked then) or the edit is another app's.
    /// Throws `SidecarError.unsupportedVersion` for PhotoLab data a newer
    /// build wrote.
    func recoverRecipe(for id: PhotoID) async throws -> Recipe? {
        guard case .asset(let assetID) = id else { throw PhotoSourceError.notInThisSource(id) }
        guard client.authorizationStatus().canRead, client.hasAdjustments(assetID) else { return nil }
        return try await client.adjustment(of: assetID)?.recipe()
    }
}

/// The on-disk copies of Photos originals: `<directory>/<safe-id>.<ext>`
/// with `safe-id` the identifier's slashes as underscores
/// (`SidecarStore.flatName`) and `ext` the original file name's. A copy
/// that exists is returned at once; otherwise the client writes it to a
/// `.part` file that is moved into place when complete, so a copy on disk
/// is always whole, and two concurrent asks share one write. It is a
/// cache: deleting the directory costs a download, never an edit.
final class OriginalsCache: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The listing's names, which give each copy its extension.
    func remember(_ assets: [PhotosAsset]) {
        lock.lock(); defer { lock.unlock() }
        for asset in assets { names[asset.id] = asset.originalFilename }
    }

    /// Where the asset's copy lives (nil for an asset not listed).
    func url(for assetID: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return names[assetID].map { target(assetID, name: $0) }
    }

    private func target(_ assetID: String, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = SidecarStore.flatName(assetID)
        return directory.appendingPathComponent(ext.isEmpty ? base : base + "." + ext, isDirectory: false)
    }

    func file(for assetID: String, client: any PhotoKitClient) async throws -> URL {
        switch try claim(assetID, client: client) {
        case .onDisk(let url):
            return url
        case .running(let task):
            return try await task.value
        case .started(let task):
            defer { finished(assetID) }
            return try await task.value
        }
    }

    private enum Claim {
        case onDisk(URL), running(Task<URL, Error>), started(Task<URL, Error>)
    }

    /// The synchronous half, under the lock: the copy on disk, the write
    /// already running, or a new write registered as in flight.
    private func claim(_ assetID: String, client: any PhotoKitClient) throws -> Claim {
        lock.lock(); defer { lock.unlock() }
        guard let name = names[assetID] else { throw PhotoSourceError.notInThisSource(.asset(assetID)) }
        let target = target(assetID, name: name)
        if FileManager.default.fileExists(atPath: target.path) { return .onDisk(target) }
        if let running = inFlight[assetID] { return .running(running) }
        let directory = directory
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let part = target.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            do {
                try await client.writeOriginal(of: assetID, to: part)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: part, to: target)
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
            return target
        }
        inFlight[assetID] = task
        return .started(task)
    }

    private func finished(_ assetID: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[assetID] = nil
    }
}

// MARK: - The album sheet's model

/// What the Open Photos Library sheet shows: the status, and the albums
/// once reading is allowed. Albums are fetched only when `status.canRead`;
/// `requestAccess()` is the Allow button and the only call that prompts.
@MainActor
@Observable
final class PhotosBrowser {
    let access: PhotosAccess
    private(set) var status: PhotosAuthorization
    private(set) var albums: [PhotosAlbum] = []

    /// System Settings › Privacy & Security › Photos, for a `.denied` status.
    nonisolated static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    init(access: PhotosAccess) {
        self.access = access
        status = access.client.authorizationStatus()
        refresh()
    }

    /// Re-reads the albums when reading is allowed; otherwise clears them.
    func refresh() {
        albums = status.canRead ? access.client.albums() : []
    }

    /// The user's click: the system dialog, then the albums if allowed.
    func requestAccess() async {
        status = await access.client.requestAuthorization()
        refresh()
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}

// MARK: - The bundle seam

private struct HasBundleKey: EnvironmentKey {
    static let defaultValue = PhotosAccess.hasBundle
}

extension EnvironmentValues {
    /// Whether this process is an app bundle (the only kind that can be
    /// granted Photos access). The app reads the real value; a test sets it
    /// to host the Welcome view or the Export sheet in either variant.
    var hasBundle: Bool {
        get { self[HasBundleKey.self] }
        set { self[HasBundleKey.self] = newValue }
    }
}
