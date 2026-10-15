import Foundation
import AppKit
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

// MARK: - Sync mask

/// Which adjustments a batch operation carries from the source onto each
/// target photo. A kind outside the mask keeps the target's own value, so
/// "sync only the grade" leaves every photo its exposure and its crop.
struct SyncMask: Hashable {
    var kinds: Set<AdjustmentKind>

    /// Every kind except rotate and crop: the look travels, the framing does
    /// not (what applying a preset does).
    static let look = SyncMask(kinds: Set(AdjustmentKind.allCases).subtracting(AdjustmentKind.geometryKinds))
    /// The look without exposure: each photo keeps its own brightness.
    static let grade = SyncMask(kinds: look.kinds.subtracting([.exposure]))
    static let everything = SyncMask(kinds: Set(AdjustmentKind.allCases))
    static let nothing = SyncMask(kinds: [])

    func contains(_ kind: AdjustmentKind) -> Bool { kinds.contains(kind) }

    mutating func set(_ kind: AdjustmentKind, _ on: Bool) {
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
    }

    mutating func set(_ list: [AdjustmentKind], _ on: Bool) {
        for kind in list { set(kind, on) }
    }

    /// True when every kind of `list` is in the mask, false when none is,
    /// nil when some are.
    func state(of list: [AdjustmentKind]) -> Bool? {
        let n = list.filter(contains).count
        return n == list.count ? true : (n == 0 ? false : nil)
    }
}

extension Recipe {
    /// `self` with every kind in `mask` taken from `source` (value and
    /// enabled flag alike); the other kinds are kept. The result is in
    /// canonical form (`normalized`).
    func syncing(_ mask: SyncMask, from source: Recipe) -> Recipe {
        var out = normalized
        for kind in AdjustmentKind.allCases where mask.contains(kind) { out[kind] = source[kind] }
        return out
    }
}

// MARK: - Export

/// One photo rendered at full size through the one `Renderer` and written
/// into an output folder as the format, quality, size and name
/// `ExportOptions` asks for, with the source's metadata carried over. The
/// original is read, never written: an overwrite that would land on the
/// source itself, or on another photo of the open library (`protected`), is
/// refused.
enum Exporter {
    enum Failure: LocalizedError {
        case cannotDecode(URL)
        case cannotRender(URL)
        case cannotWrite(URL)
        /// Overwrite would replace the photo's own file.
        case isTheOriginal(URL)
        /// Overwrite would replace the file of another photo of the open
        /// library (the URL is that file, the export's target).
        case isALibraryOriginal(URL)

        var errorDescription: String? {
            switch self {
            case .cannotDecode(let u): return "Could not decode \(u.lastPathComponent)."
            case .cannotRender(let u): return "Could not render \(u.lastPathComponent)."
            case .cannotWrite(let u): return "Could not write \(u.lastPathComponent)."
            case .isTheOriginal(let u): return "\(u.lastPathComponent) is the original; it is never overwritten."
            case .isALibraryOriginal(let u):
                return "\(u.lastPathComponent) is an original in the library; it is never overwritten."
            }
        }
    }

    /// What one export did.
    enum Outcome: Equatable, Sendable {
        case written(URL)
        /// The file existed and the collision policy is `.skip`.
        case skipped(URL)

        var url: URL {
            switch self {
            case .written(let u), .skipped(let u): return u
            }
        }
    }

    /// The file `source` is written to in `folder`: `<stem><suffix>.<ext>`;
    /// under `.number` (the default) the next free name when that one is
    /// taken (another export, or the original itself when exporting into
    /// its own folder): `<stem> 2.jpg`, `<stem> 3.jpg`, …. Under `.skip`
    /// and `.overwrite` it is the plain name whether or not it exists.
    static func destination(for source: URL, name: String? = nil, in folder: URL, options: ExportOptions = .default) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent(options.fileName(for: source, name: name, number: n), isDirectory: false)
            if options.collision != .number || !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// True when `a` and `b` name the same file: the same path once
    /// standardized and symlinks resolved, or the same file identity
    /// (`fileResourceIdentifier`), which also catches a case variant on a
    /// case-insensitive volume and a hard link. False when either is missing.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let ia = fileIdentity(a), let ib = fileIdentity(b) else { return false }
        return ia.isEqual(ib)
    }

    private static func fileIdentity(_ url: URL) -> (any NSObjectProtocol)? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    /// Renders `recipe` over the full-resolution decode of `source` and
    /// writes it per `options`. Synchronous; call off the main thread.
    /// The file is written beside its final name and moved into place, so a
    /// cancelled or failed export leaves no half file. Returns what happened.
    /// `protected` is every original of the open library (`Library.exportItems`):
    /// an Overwrite whose target is one of them, by file identity, is refused
    /// with `Failure.isALibraryOriginal` and nothing is written.
    @discardableResult
    static func export(_ source: URL, name: String? = nil, recipe: Recipe, into folder: URL, options: ExportOptions = .default,
                       protected: Set<URL> = [], renderer: Renderer = .shared) throws -> Outcome {
        let fm = FileManager.default
        let out = destination(for: source, name: name, in: folder, options: options)
        let exists = fm.fileExists(atPath: out.path)
        if exists {
            switch options.collision {
            case .skip: return .skipped(out)
            case .overwrite:
                if out.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL.resolvingSymlinksInPath() {
                    throw Failure.isTheOriginal(source)
                }
                if protected.contains(where: { isSameFile(out, $0) }) {
                    throw Failure.isALibraryOriginal(out)
                }
            case .number: break
            }
        }
        try write(source, recipe: recipe, to: out, options: options, renderer: renderer)
        return .written(out)
    }

    /// Renders `recipe` over the full-resolution decode of `source` and
    /// writes it to `out` in `options`' format, quality and size, with the
    /// source's metadata when `options.keepMetadata`; a file at `out` is
    /// replaced. The bytes go to a partial file beside `out`, moved into
    /// place when complete. `export` calls this after its collision rules;
    /// a Save to Photos calls it for the rendered JPEG PhotoKit asks for
    /// (`PhotosSource.saveEdit`), so both are the one render and write path.
    static func write(_ source: URL, recipe: Recipe, to out: URL, options: ExportOptions,
                      renderer: Renderer = .shared) throws {
        let fm = FileManager.default
        let folder = out.deletingLastPathComponent()
        guard let image = Renderer.fullResolution(source) else { throw Failure.cannotDecode(source) }
        guard let result = renderer.render(image, recipe: recipe, resize: options.resize) else {
            throw Failure.cannotRender(source)
        }
        var properties = options.keepMetadata
            ? ExportMetadata.properties(of: source, outputWidth: result.image.width, outputHeight: result.image.height)
            : [:]
        if options.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = options.clampedQuality
        }
        if options.format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(out.lastPathComponent).\(UUID().uuidString).partial", isDirectory: false)
        defer { try? fm.removeItem(at: partial) }
        guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
            throw Failure.cannotWrite(out)
        }
        // The renderer's frame is RGBA (premultiplied, alpha 1 everywhere).
        // JPEG and HEIC drop the channel; TIFF would keep it as a fourth
        // sample flagged as associated alpha, which some readers open as
        // transparency, so a TIFF is written from an opaque copy.
        let output = options.format == .tiff ? (opaque(result.image) ?? result.image) : result.image
        CGImageDestinationAddImage(dest, output, properties as CFDictionary)


        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(out) }
        do {
            if fm.fileExists(atPath: out.path) {
                _ = try fm.replaceItemAt(out, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: out)
            }
        } catch {
            throw Failure.cannotWrite(out)
        }
    }

    /// `image` redrawn, pixel for pixel, into a bitmap with no alpha channel
    /// (RGBX), so an image destination writes three samples per pixel.
    static func opaque(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}


/// The export queue: a list of (photo, recipe) pairs written one after the
/// other to one `ExportTarget` with one `ExportOptions`, with progress the
/// window shows and a Cancel that stops after the file in flight. A folder
/// target gets the files; a Photos target gets each file rendered into a
/// per-run staging directory, imported through the `PhotosWriter` as a new
/// asset and removed. One queue per app; a run cannot start while another
/// is going. It also keeps the options, the output folder and the Photos
/// album between runs (UserDefaults when `remember` is on; tests leave it
/// off).
@MainActor
@Observable
final class ExportQueue {
    struct Item: Identifiable {
        let id = UUID()
        let source: URL
        let recipe: Recipe
        /// The photo's own file name, when `source` is a cached copy of a
        /// Photos original under another name: the output is named from it.
        /// Nil for a folder photo (its file name is used).
        var name: String? = nil
        /// The open library's originals when the export was asked for: an
        /// Overwrite onto one of them is refused (`Exporter.export`).
        var protected: Set<URL> = []
    }

    struct Failure: Identifiable {
        let id = UUID()
        let source: URL
        let message: String
    }

    /// Export… was chosen for these items: the options sheet is up.
    struct Request: Identifiable {
        let id = UUID()
        let items: [Item]
    }

    enum State: Equatable { case idle, running, finished, cancelled }

    /// Exports one item (source, recipe, protected originals) into the
    /// folder per the options; the default is `Exporter.export`. Injected so
    /// a test can time or count jobs without rendering.
    typealias Worker = @Sendable (URL, Recipe, URL, ExportOptions, Set<URL>, String?) throws -> Exporter.Outcome

    private(set) var state: State = .idle
    private(set) var total = 0
    /// Files written so far in this run.
    private(set) var done = 0
    private(set) var failures: [Failure] = []
    private(set) var exported: [URL] = []
    /// New Photos assets (`localIdentifier`s) of a Photos run.
    private(set) var imported: [String] = []
    /// Files left alone because they existed (collision policy Skip).
    private(set) var skipped: [URL] = []
    /// The photo being written right now.
    private(set) var current: URL?
    /// The output folder: the last run's, and the remembered one the sheet
    /// offers first.
    private(set) var folder: URL?
    /// The options the sheet offers first (the last run's).
    private(set) var options: ExportOptions = .default
    /// The album the sheet offers first for a Photos export (nil = none).
    private(set) var album: String? = ExportTarget.defaultAlbum
    /// Whether the sheet opens on the Photos target (the last run's kind).
    private(set) var prefersPhotos = false
    /// The running or last run's target, which the export bar names.
    private(set) var target: ExportTarget?
    /// Set by `requestExport`; the window shows the options sheet for it.
    var request: Request?

    private var task: Task<Void, Never>?
    private let worker: Worker
    private let remember: Bool
    /// Imports a Photos run's files; the live PhotoKit in the app.
    let photos: any PhotosWriter
    /// Where a Photos run renders its files before the import; each run
    /// uses its own subdirectory and removes it at the end.
    let stagingDirectory: URL

    private static let folderKey = "exportFolder"
    private static let optionsKey = "exportOptions"
    private static let albumKey = "exportPhotosAlbum"
    private static let targetKey = "exportTarget"

    /// `<tmp>/PhotoLab-export/`.
    nonisolated static var defaultStagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotoLab-export", isDirectory: true)
    }

    init(remember: Bool = false,
         photos: any PhotosWriter = PhotoKitLive(),
         stagingDirectory: URL = ExportQueue.defaultStagingDirectory,
         worker: @escaping Worker = { try Exporter.export($0, name: $5, recipe: $1, into: $2, options: $3, protected: $4) }) {
        self.worker = worker
        self.remember = remember
        self.photos = photos
        self.stagingDirectory = stagingDirectory
        guard remember else { return }
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.folderKey), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if defaults.object(forKey: Self.albumKey) != nil {
            album = ExportTarget.album(from: defaults.string(forKey: Self.albumKey) ?? "")
        }
        prefersPhotos = defaults.string(forKey: Self.targetKey) == "photos"
        if let data = defaults.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(ExportOptions.self, from: data) {
            options = saved
        }
    }

    var isRunning: Bool { state == .running }
    /// Items finished: written, skipped or failed.
    var completed: Int { done + skipped.count + failures.count }

    /// Opens the options sheet for `items`. Ignored while a run is going.
    func requestExport(_ items: [Item]) {
        guard !isRunning, !items.isEmpty else { return }
        request = Request(items: items)
    }

    /// Opens the options sheet for the library's batch targets, each item's
    /// file resolved through the open source (`Library.exportItems(for:)`;
    /// a folder photo's file is its own, at once).
    func requestExport(from library: Library) {
        let ids = library.batchTargets
        Task { @MainActor [weak self] in
            guard let items = try? await library.exportItems(for: ids) else { return }
            self?.requestExport(items)
        }
    }

    /// Keeps `folder` and `options` for the next run (and across launches
    /// when `remember` is on).
    func keep(folder: URL, options: ExportOptions) {
        keep(target: .folder(folder), options: options)
    }

    /// Keeps the target (its folder, or its album and that Photos was
    /// chosen) and `options` for the next run (and across launches when
    /// `remember` is on). A Photos run leaves the remembered folder as it is.
    func keep(target: ExportTarget, options: ExportOptions) {
        self.options = options
        switch target {
        case .folder(let folder):
            self.folder = folder
            prefersPhotos = false
        case .photosLibrary(let album):
            self.album = album
            prefersPhotos = true
        }
        guard remember else { return }
        let defaults = UserDefaults.standard
        if let folder = target.folder { defaults.set(folder.path, forKey: Self.folderKey) }
        if case .photosLibrary(let album) = target { defaults.set(album ?? "", forKey: Self.albumKey) }
        defaults.set(target.isPhotosLibrary ? "photos" : "folder", forKey: Self.targetKey)
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.optionsKey) }
    }

    /// Starts writing `items` into `folder` per `options`. Ignored while a
    /// run is going.
    func start(_ items: [Item], into folder: URL, options: ExportOptions = .default) {
        start(items, to: .folder(folder), options: options)
    }

    /// What one item came to.
    private enum Done: Sendable {
        case written(URL), skipped(URL), imported(String)
    }

    /// Starts sending `items` to `target` per `options`. Ignored while a run
    /// is going. A Photos target numbers names in its staging directory
    /// whatever the collision policy (every import is a new asset).
    func start(_ items: [Item], to target: ExportTarget, options: ExportOptions = .default) {
        guard !isRunning, !items.isEmpty else { return }
        state = .running
        total = items.count
        done = 0
        failures = []
        exported = []
        imported = []
        skipped = []
        current = nil
        self.target = target
        if let folder = target.folder { self.folder = folder }
        var options = options
        if target.isPhotosLibrary { options.collision = .number }
        let runOptions = options
        let worker = self.worker
        let photos = self.photos
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        task = Task { [weak self] in
            defer {
                if target.isPhotosLibrary { try? FileManager.default.removeItem(at: staging) }
            }
            for item in items {
                if Task.isCancelled { break }
                self?.current = item.source
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Done, Error> in
                    switch target {
                    case .folder(let folder):
                        return Result {
                            switch try worker(item.source, item.recipe, folder, runOptions, item.protected, item.name) {
                            case .written(let url): return .written(url)
                            case .skipped(let url): return .skipped(url)
                            }
                        }
                    case .photosLibrary(let album):
                        return await Self.importIntoPhotos(item.source, name: item.name, recipe: item.recipe, staging: staging,
                                                           protected: item.protected, album: album, options: runOptions,
                                                           worker: worker, photos: photos)
                    }
                }.value
                guard let self else { return }
                switch outcome {
                case .success(.written(let url)):
                    self.done += 1
                    self.exported.append(url)
                case .success(.imported(let id)):
                    self.done += 1
                    self.imported.append(id)
                case .success(.skipped(let url)):
                    self.skipped.append(url)
                case .failure(let error):
                    self.failures.append(Failure(source: item.source, message: error.localizedDescription))
                }
            }
            guard let self else { return }
            self.current = nil
            self.state = Task.isCancelled ? .cancelled : .finished
        }
    }

    /// One item of a Photos run: rendered by the worker (`Exporter.export`,
    /// the one path for format, quality, size and metadata) into `staging`,
    /// imported, and the staged file removed whether or not the import
    /// worked.
    nonisolated private static func importIntoPhotos(_ source: URL, name: String?, recipe: Recipe, staging: URL,
                                                     protected: Set<URL>, album: String?,
                                                     options: ExportOptions, worker: Worker,
                                                     photos: any PhotosWriter) async -> Result<Done, Error> {
        do {
            let outcome = try worker(source, recipe, staging, options, protected, name)
            guard case .written(let file) = outcome else { return .success(.skipped(outcome.url)) }
            defer { try? FileManager.default.removeItem(at: file) }
            return .success(.imported(try await photos.importImage(at: file, intoAlbum: album)))
        } catch {
            return .failure(error)
        }
    }

    /// Stops the run after the file in flight; what is written stays.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    /// Clears a finished or cancelled run from the window.
    func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    /// Returns when the run has ended (tests).
    func wait() async {
        await task?.value
    }
}

/// The folder picker behind the export sheet's Choose….
@MainActor
enum ExportPanel {
    static func chooseFolder(count: Int, format: ExportOptions.Format, from current: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = current
        panel.message = count == 1 ? "Choose a folder for the \(format.label)" : "Choose a folder for \(count) \(format.label)s"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
