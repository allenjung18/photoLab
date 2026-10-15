import Foundation

/// The on-disk form of one photo's edit: `<folder>/.photolab/<filename>.json`.
///
/// Sidecars live in a hidden per-folder directory rather than beside each
/// original so a folder of photos stays uncluttered, the library scan (which
/// skips hidden entries) never sees them, and deleting `.photolab/` wipes
/// every edit in a folder. The file name keeps the original's extension
/// (`IMG_0001.JPG.json`, `IMG_0001.HEIC.json`), so two originals that differ
/// only by extension never share a sidecar. The original is never written to.
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

/// Reads and writes the sidecars of one folder.
struct SidecarStore {
    static let directoryName = ".photolab"
    static let fileExtension = "json"

    let folder: URL

    var directory: URL { folder.appendingPathComponent(Self.directoryName, isDirectory: true) }

    /// `<folder>/.photolab/<name>.json` for a photo in this folder. A photo in
    /// a subfolder keeps its relative path, so `sub/a.jpg` maps to
    /// `.photolab/sub/a.jpg.json`.
    func url(for photo: URL) -> URL {
        let rel = relativePath(of: photo)
        return directory.appendingPathComponent(rel + "." + Self.fileExtension, isDirectory: false)
    }

    func exists(for photo: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(for: photo).path)
    }

    /// The recipe saved for `photo`, or nil when there is no sidecar. A
    /// sidecar that cannot be decoded throws, so the caller can tell "no
    /// edit" from "an edit this build cannot read" and leave the file alone.
    func load(for photo: URL) throws -> Recipe? {
        try read(for: photo)?.recipe
    }

    /// The whole sidecar saved for `photo` (recipe and marks), or nil when
    /// there is none; throws when the file cannot be decoded.
    func read(for photo: URL) throws -> Sidecar? {
        let file = url(for: photo)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try Self.decode(data)
    }

    /// Writes the recipe for `photo`, keeping whatever marks the sidecar
    /// already holds (a recipe-only caller never loses a flag or rating).
    func save(_ recipe: Recipe, for photo: URL, now: Date = Date()) throws {
        let kept = (try? read(for: photo))?.marks ?? .none
        try save(recipe, marks: kept, for: photo, now: now)
    }

    /// Writes the sidecar for `photo`: the recipe and the marks. The file is
    /// removed instead when there is nothing to keep — the default recipe
    /// AND no marks — so a reset of an unmarked photo leaves no trace while
    /// a flag or rating on a default recipe keeps its file. A recipe that
    /// only differs by a disabled entry is still written (`Recipe.isDefault`,
    /// not `isNeutral`). Unset marks are omitted from the JSON, not written
    /// as null. The write is atomic (temp file + rename).
    func save(_ recipe: Recipe, marks: Marks, for photo: URL, now: Date = Date()) throws {
        let file = url(for: photo)
        try Self.backUpIfUnreadable(file, now: now)
        if recipe.isDefault && marks.isEmpty {
            try remove(for: photo)
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = Sidecar(original: photo.lastPathComponent, updated: now, recipe: recipe,
                          flag: marks.flag, rating: marks.rating == 0 ? nil : marks.rating)
        let data = try Self.encoder.encode(doc)
        try data.write(to: file, options: .atomic)
    }

    func remove(for photo: URL) throws {
        let file = url(for: photo)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Every readable sidecar among `photos`: the non-default recipes and
    /// the non-empty marks, each keyed by photo URL, plus the photos whose
    /// sidecar exists but could not be read.
    func loadAll(for photos: [URL]) -> (recipes: [URL: Recipe], marks: [URL: Marks], unreadable: [URL]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([:], [:], []) }
        var recipes: [URL: Recipe] = [:]
        var marks: [URL: Marks] = [:]
        var unreadable: [URL] = []
        for photo in photos {
            do {
                guard let doc = try read(for: photo) else { continue }
                if !doc.recipe.isDefault { recipes[photo] = doc.recipe }
                if !doc.marks.isEmpty { marks[photo] = doc.marks }
            } catch {
                unreadable.append(photo)
            }
        }
        return (recipes, marks, unreadable)
    }

    private func relativePath(of photo: URL) -> String {
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
