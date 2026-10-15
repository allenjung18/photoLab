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
        let file = url(for: photo)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try Self.decoder.decode(Sidecar.self, from: data).recipe
    }

    /// Writes the sidecar for `photo`; the default recipe removes it instead,
    /// so a reset leaves no trace. A recipe that only differs by a disabled
    /// entry is still written (`Recipe.isDefault`, not `isNeutral`). The
    /// write is atomic (temp file + rename).
    func save(_ recipe: Recipe, for photo: URL, now: Date = Date()) throws {
        let file = url(for: photo)
        if recipe.isDefault {
            try remove(for: photo)
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = Sidecar(original: photo.lastPathComponent, updated: now, recipe: recipe)
        let data = try Self.encoder.encode(doc)
        try data.write(to: file, options: .atomic)
    }

    func remove(for photo: URL) throws {
        let file = url(for: photo)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Every readable sidecar among `photos`, keyed by photo URL, plus the
    /// photos whose sidecar exists but could not be read.
    func loadAll(for photos: [URL]) -> (recipes: [URL: Recipe], unreadable: [URL]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([:], []) }
        var recipes: [URL: Recipe] = [:]
        var unreadable: [URL] = []
        for photo in photos {
            do {
                if let recipe = try load(for: photo), !recipe.isDefault { recipes[photo] = recipe }
            } catch {
                unreadable.append(photo)
            }
        }
        return (recipes, unreadable)
    }

    private func relativePath(of photo: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = photo.standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return photo.lastPathComponent
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
