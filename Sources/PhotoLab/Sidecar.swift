import Foundation

/// The on-disk form of one photo's edit: `<folder>/.photolab/<filename>.json`
/// for a photo in a folder (`SidecarStore.Naming.folder`), or
/// `<directory>/<id with / as _>.json` for a photo of a source without a
/// folder (`SidecarStore.Naming.flat`).
///
/// A folder's sidecars live in a hidden per-folder directory rather than
/// beside each original so a folder of photos stays uncluttered, the library
/// scan (which skips hidden entries) never sees them, and deleting
/// `.photolab/` wipes every edit in a folder. The file name keeps the
/// original's extension (`IMG_0001.JPG.json`, `IMG_0001.HEIC.json`), so two
/// originals that differ only by extension never share a sidecar. The
/// original is never written to.
struct Sidecar: Codable, Equatable {
    static let currentVersion = 1

    var version = Sidecar.currentVersion
    /// The original's file name, for a human reading the directory.
    var original: String
    var updated: Date
    var recipe: Recipe
    /// Culling marks, beside the recipe and never part of it. Both keys are
    /// optional and absent when unset, so a sidecar written before they
    /// existed decodes unchanged and an unmarked photo's file looks as it did.
    var flag: Marks.Flag?
    var rating: Int?

    var marks: Marks { Marks(flag: flag, rating: rating ?? 0) }
}

/// What culling leaves on a photo: a flag (pick / reject / none) and a star
/// rating 0–5. Marks sit beside the recipe in the sidecar; they are not an
/// edit, so they are not undo steps and never enter a recipe, a preset or a
/// sync mask (the types do not meet). A marked photo keeps its sidecar even
/// when its recipe is the default.
struct Marks: Hashable {
    enum Flag: String, Codable, CaseIterable {
        case pick, reject
    }

    static let maxRating = 5
    static let none = Marks()

    var flag: Flag?
    /// 0 is unrated; values are clamped to 0...5.
    var rating: Int {
        didSet { rating = min(max(rating, 0), Self.maxRating) }
    }

    init(flag: Flag? = nil, rating: Int = 0) {
        self.flag = flag
        self.rating = min(max(rating, 0), Self.maxRating)
    }

    /// No flag and no stars: nothing to keep a sidecar for.
    var isEmpty: Bool { flag == nil && rating == 0 }
}

/// Reads and writes the sidecars of one source: a directory and a naming
/// rule (`Naming`) from a photo's id to a file in it. A folder's store
/// (`init(folder:)`) is `<folder>/.photolab/` with the folder naming; a
/// source without a folder injects its own directory with the flat naming.
struct SidecarStore: Sendable {
    /// How a photo id maps to a file name under `directory`.
    enum Naming: Hashable, Sendable {
        /// `<path relative to the folder>.json` for a photo in the folder
        /// (`sub/a.jpg` maps to `sub/a.jpg.json`), its file name for one
        /// outside it; an asset id takes the flat form.
        case folder(URL)
        /// `<id with every / as _>.json` (`UUID/L0/001` maps to
        /// `UUID_L0_001.json`); a file's path, slashes replaced, likewise.
        case flat
    }

    static let directoryName = ".photolab"
    static let fileExtension = "json"

    let directory: URL
    let naming: Naming

    init(directory: URL, naming: Naming) {
        self.directory = directory
        self.naming = naming
    }

    /// The store of one folder: `<folder>/.photolab/` with the folder naming.
    init(folder: URL) {
        self.init(directory: folder.appendingPathComponent(Self.directoryName, isDirectory: true),
                  naming: .folder(folder))
    }

    /// The folder this store belongs to, when its naming is a folder's.
    var folder: URL? {
        if case .folder(let url) = naming { return url }
        return nil
    }

    /// The sidecar file for a photo: `<directory>/<name>.json` per `naming`.
    func url(for id: PhotoID) -> URL {
        directory.appendingPathComponent(relativeName(for: id) + "." + Self.fileExtension, isDirectory: false)
    }

    func exists(for id: PhotoID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// The recipe saved for the photo, or nil when there is no sidecar. A
    /// sidecar that cannot be decoded throws, so the caller can tell "no
    /// edit" from "an edit this build cannot read" and leave the file alone.
    func load(for id: PhotoID) throws -> Recipe? {
        try read(for: id)?.recipe
    }

    /// The whole sidecar saved for the photo (recipe and marks), or nil when
    /// there is none; throws when the file cannot be decoded.
    func read(for id: PhotoID) throws -> Sidecar? {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try Self.decode(data)
    }

    /// Writes the recipe for the photo, keeping whatever marks the sidecar
    /// already holds (a recipe-only caller never loses a flag or rating).
    func save(_ recipe: Recipe, for id: PhotoID, name: String? = nil, now: Date = Date()) throws {
        let kept = (try? read(for: id))?.marks ?? .none
        try save(recipe, marks: kept, for: id, name: name, now: now)
    }

    /// Writes the sidecar for the photo: the recipe and the marks. The file is
    /// removed instead when there is nothing to keep — the default recipe
    /// AND no marks — so a reset of an unmarked photo leaves no trace while
    /// a flag or rating on a default recipe keeps its file. A recipe that
    /// only differs by a disabled entry is still written (`Recipe.isDefault`,
    /// not `isNeutral`). Unset marks are omitted from the JSON, not written
    /// as null. The write is atomic (temp file + rename). `name` is the
    /// `original` the file records; the id's own name when not given.
    func save(_ recipe: Recipe, marks: Marks, for id: PhotoID, name: String? = nil, now: Date = Date()) throws {
        let file = url(for: id)
        try Self.backUpIfUnreadable(file, now: now)
        if recipe.isDefault && marks.isEmpty {
            try remove(for: id)
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = Sidecar(original: name ?? id.defaultName, updated: now, recipe: recipe,
                          flag: marks.flag, rating: marks.rating == 0 ? nil : marks.rating)
        let data = try Self.encode(doc)
        try data.write(to: file, options: .atomic)
    }

    /// One sidecar as its file's bytes: the form `save` writes and `decode`
    /// reads (pretty, sorted keys, ISO 8601 dates). The Photos adjustment
    /// data (`PhotosAdjustment`) is the same JSON.
    static func encode(_ doc: Sidecar) throws -> Data {
        try encoder.encode(doc)
    }

    func remove(for id: PhotoID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Every readable sidecar among `ids`: the non-default recipes and
    /// the non-empty marks, each keyed by photo id, plus the photos whose
    /// sidecar exists but could not be read.
    /// Under the flat naming the directory is listed once and only the ids
    /// with a file there are read, so a Photos Recents of thousands costs
    /// one listing, not a file check per photo.
    func loadAll(for ids: [PhotoID]) -> (recipes: [PhotoID: Recipe], marks: [PhotoID: Marks], unreadable: [PhotoID]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([:], [:], []) }
        var recipes: [PhotoID: Recipe] = [:]
        var marks: [PhotoID: Marks] = [:]
        var unreadable: [PhotoID] = []
        var candidates = ids
        if naming == .flat, let present = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let files = Set(present)
            candidates = ids.filter { files.contains(relativeName(for: $0) + "." + Self.fileExtension) }
        }
        for id in candidates {
            do {
                guard let doc = try read(for: id) else { continue }
                if !doc.recipe.isDefault { recipes[id] = doc.recipe }
                if !doc.marks.isEmpty { marks[id] = doc.marks }
            } catch {
                unreadable.append(id)
            }
        }
        return (recipes, marks, unreadable)
    }

    /// The file name (without the extension) for an id under `naming`.
    func relativeName(for id: PhotoID) -> String {
        switch (naming, id) {
        case (.folder(let base), .file(let url)): return Self.relativePath(of: url, under: base)
        case (.flat, .file(let url)): return Self.flatName(url.standardizedFileURL.path)
        case (_, .asset(let identifier)): return Self.flatName(identifier)
        }
    }

    /// Every `/` replaced by `_` (a leading one dropped), so an id with path
    /// separators is one file name.
    static func flatName(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "_")
    }

    private static func relativePath(of photo: URL, under folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = photo.standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return photo.lastPathComponent
    }

    /// Decodes one sidecar file. A `version` above `Sidecar.currentVersion`
    /// is refused: the file was written by a newer PhotoLab and may hold
    /// fields this build would silently drop and then write back without.
    static func decode(_ data: Data) throws -> Sidecar {
        let doc = try decoder.decode(Sidecar.self, from: data)
        guard doc.version <= Sidecar.currentVersion else {
            throw SidecarError.unsupportedVersion(doc.version)
        }
        return doc
    }

    /// Moves a sidecar this build cannot decode (damaged, or a `version`
    /// too new) to `<name>.json.unreadable-<yyyymmdd-hhmmss>` before
    /// anything is written or removed at its path, so the edit it holds is
    /// never lost. PhotoLab never deletes a backup. Called at the top of
    /// `save`; a missing file is nothing to do.
    static func backUpIfUnreadable(_ file: URL, now: Date) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            _ = try decode(try Data(contentsOf: file))
        } catch {
            try UnreadableBackup.moveAside(file, now: now)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// The same store addressed by a photo's file URL (a photo in a folder):
/// each form is `.file(url)` of the one above.
extension SidecarStore {
    func url(for photo: URL) -> URL { url(for: .file(photo)) }
    func exists(for photo: URL) -> Bool { exists(for: .file(photo)) }
    func load(for photo: URL) throws -> Recipe? { try load(for: .file(photo)) }
    func read(for photo: URL) throws -> Sidecar? { try read(for: .file(photo)) }
    func save(_ recipe: Recipe, for photo: URL, now: Date = Date()) throws {
        try save(recipe, for: .file(photo), now: now)
    }
    func save(_ recipe: Recipe, marks: Marks, for photo: URL, now: Date = Date()) throws {
        try save(recipe, marks: marks, for: .file(photo), now: now)
    }
    func remove(for photo: URL) throws { try remove(for: .file(photo)) }

    func loadAll(for photos: [URL]) -> (recipes: [URL: Recipe], marks: [URL: Marks], unreadable: [URL]) {
        let all = loadAll(for: photos.map { PhotoID.file($0) })
        var recipes: [URL: Recipe] = [:]
        var marks: [URL: Marks] = [:]
        for (id, r) in all.recipes { if let u = id.fileURL { recipes[u] = r } }
        for (id, m) in all.marks { if let u = id.fileURL { marks[u] = m } }
        return (recipes, marks, all.unreadable.compactMap(\.fileURL))
    }
}

enum SidecarError: LocalizedError, Equatable {
    /// The file's `version` is above what this build reads.
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "This edit was saved by a newer version of PhotoLab (format \(v); this version reads up to \(Sidecar.currentVersion))."
        }
    }
}

/// The one way an unreadable sidecar or preset file is moved aside:
/// `<file>.unreadable-<yyyymmdd-hhmmss>` beside it (`-2`, `-3`, … when that
/// second is taken). The copy keeps the original bytes and is never deleted
/// by PhotoLab; the user can inspect or restore it by hand. Neither store
/// lists these files (the extension is not `json`) and the folder scan never
/// sees them (`.photolab` is hidden).
enum UnreadableBackup {
    static let marker = "unreadable"

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// The backup path for `file` at `now`: the first one not yet taken.
    static func url(for file: URL, now: Date) -> URL {
        let base = file.path + "." + marker + "-" + stamp(now)
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return URL(fileURLWithPath: candidate, isDirectory: false)
    }

    /// Renames `file` to its backup path and returns that path.
    @discardableResult
    static func moveAside(_ file: URL, now: Date = Date()) throws -> URL {
        let target = url(for: file, now: now)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}
