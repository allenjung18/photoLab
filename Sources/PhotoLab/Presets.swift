import Foundation
import Observation

/// A preset is a named recipe (README, Design). It carries every kind except
/// geometry, and never masks: a look is meant to travel between photos, a
/// crop, a rotation or a local adjustment pinned to one photo's pixels is
/// not, so saving a preset drops the geometry and the masks and applying one
/// keeps the photo's own. Presets are user-level files, one JSON per preset, in
/// `PresetStore.defaultDirectory`.
struct Preset: Codable, Hashable, Identifiable {
    static let currentVersion = 1

    var version = Preset.currentVersion
    var name: String
    var updated: Date
    var recipe: Recipe

    var id: String { name }

    /// A preset holding `recipe` with its geometry neutralized, every kind
    /// present in chain order (so two presets of the same look compare equal
    /// whatever order their sources listed the kinds in). `updated` is kept
    /// to the whole second, which is what the file holds (ISO 8601), so the
    /// preset `PresetLibrary.save` returns equals the one read back.
    init(name: String, from recipe: Recipe, updated: Date = Date()) {
        self.name = name
        self.updated = Date(timeIntervalSince1970: updated.timeIntervalSince1970.rounded(.down))
        var r = recipe.normalized
        for kind in AdjustmentKind.geometryKinds { r[kind] = Adjustment(kind: kind, value: kind.neutral) }
        r.masks = []
        self.recipe = r
    }

    /// The recipe `current` becomes when this preset is applied: the preset's
    /// look over the photo's own rotation, crop and masks.
    func apply(to current: Recipe) -> Recipe {
        var out = recipe.normalized
        for kind in AdjustmentKind.geometryKinds { out[kind] = current[kind] }
        out.masks = current.normalized.masks
        return out
    }

    /// True when `current` already shows this preset (its look over the
    /// photo's own geometry), for the strip's check mark.
    func matches(_ current: Recipe) -> Bool { apply(to: current) == current.normalized }

    // MARK: Starter set

    /// The looks a fresh install starts with. Data, not code: each is a list
    /// of slider values on the neutral recipe; `PresetStore.seedStarters`
    /// writes them as ordinary preset files the user can change or delete.
    static let starters: [Preset] = [
        look("Neutral", []),
        look("Warm Film", [
            (.temperature, 18), (.tint, 4), (.contrast, -8), (.highlights, -15), (.shadows, 15),
            (.curveBlacks, 6), (.vibrance, 8), (.satOrange, 10), (.grain, 20),
        ]),
        look("Cool Matte", [
            (.temperature, -15), (.contrast, -15), (.highlights, -10), (.curveBlacks, 12),
            (.curveWhites, -8), (.saturation, -12), (.vignette, -15),
        ]),
        look("High-Contrast B&W", [
            (.saturation, -100), (.contrast, 40), (.whites, 15), (.blacks, -20), (.clarity, 25), (.grain, 15),
        ]),
        look("Faded", [
            (.exposure, 0.2), (.contrast, -20), (.curveBlacks, 18), (.curveWhites, -12),
            (.saturation, -25), (.vignette, -10),
        ]),
        look("Punchy", [
            (.contrast, 25), (.whites, 10), (.blacks, -10), (.vibrance, 35), (.saturation, 10),
            (.clarity, 20), (.sharpening, 20),
        ]),
    ]

    private static func look(_ name: String, _ values: [(AdjustmentKind, Double)]) -> Preset {
        var r = Recipe.neutral
        for (kind, value) in values { r.set(kind, to: value) }
        // A fixed date so the starter files are byte-identical across installs.
        return Preset(name: name, from: r, updated: Date(timeIntervalSince1970: 0))
    }
}

enum PresetError: LocalizedError, Equatable {
    case emptyName
    case invalidName(String)
    case nameExists(String)
    case notFound(String)
    case fileNameCollision(String, String)
    /// The file's `version` is above what this build reads.
    case unsupportedVersion(String, Int)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "A preset needs a name."
        case .invalidName(let n): return "“\(n)” is not a valid preset name."
        case .nameExists(let n): return "A preset named “\(n)” already exists."
        case .notFound(let n): return "There is no preset named “\(n)”."
        case .fileNameCollision(let a, let b):
            return "“\(a)” and “\(b)” would share a file name; pick a name that differs in more than punctuation."
        case .unsupportedVersion(let n, let v):
            return "The preset “\(n)” was saved by a newer version of PhotoLab (format \(v); this version reads up to \(Preset.currentVersion))."
        }
    }
}

/// Reads and writes the presets of one directory: `<directory>/<name>.json`,
/// the file named after the preset with the characters a file name cannot
/// hold replaced. The directory is injected so tests never touch the user's
/// Application Support folder.
struct PresetStore {
    /// `~/Library/Application Support/PhotoLab/presets/`.
    static let defaultDirectory: URL = {
        AppDirectories.applicationSupport.appendingPathComponent("PhotoLab/presets", isDirectory: true)
    }()
    static let fileExtension = "json"
    static let maxNameLength = 80

    let directory: URL

    init(directory: URL = PresetStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Names

    /// The name as stored: trimmed. Throws when it is empty, hidden
    /// (leading dot), too long, or holds a control character.
    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetError.emptyName }
        guard !trimmed.hasPrefix("."), trimmed.count <= maxNameLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PresetError.invalidName(trimmed)
        }
        return trimmed
    }

    /// `<directory>/<name>.json`, with `/` and `:` (the two characters a
    /// macOS file name cannot carry) replaced by `-`.
    func url(for name: String) -> URL {
        let safe = String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return directory.appendingPathComponent(safe, isDirectory: false)
            .appendingPathExtension(Self.fileExtension)
    }

    /// True when a file is stored under `name`, whether or not this build
    /// can read it: an undecodable preset is still the user's, never an
    /// empty slot to write into.
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    // MARK: Files

    /// The preset saved under `name`, or nil when there is none. A file that
    /// cannot be decoded throws.
    func load(_ name: String) throws -> Preset? {
        let file = url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try Self.decode(data)
    }

    /// Writes `preset` (atomic: temp file + rename), replacing a preset of the
    /// same name. A different name that maps to the same file is refused. A
    /// file this build cannot decode (damaged, or a `version` too new) is
    /// moved to `<name>.json.unreadable-<yyyymmdd-hhmmss>` first
    /// (`UnreadableBackup`), never replaced.
    func save(_ preset: Preset, now: Date = Date()) throws {
        let name = try Self.validated(preset.name)
        let file = url(for: name)
        if FileManager.default.fileExists(atPath: file.path) {
            if let other = try? load(name) {
                if other.name != name { throw PresetError.fileNameCollision(name, other.name) }
            } else {
                try UnreadableBackup.moveAside(file, now: now)
            }
        }
        var doc = preset
        doc.name = name
        try write(doc, to: file)
    }

    /// The encode and the atomic write behind `save` and a case-only `rename`.
    private func write(_ preset: Preset, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(preset)
        try data.write(to: file, options: .atomic)
    }

    func remove(_ name: String) throws {
        let file = url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PresetError.notFound(name) }
        try FileManager.default.removeItem(at: file)
    }

    /// Renames a preset; the recipe is kept, the old file goes. Refused when
    /// `newName` is taken (a rename never silently replaces another preset).
    /// "Taken" is by file identity, not by path: on a case-insensitive volume
    /// `Mine` → `mine` names the preset's own file, and that rename is
    /// allowed (the entry is re-spelled and the file rewritten in place).
    func rename(_ name: String, to newName: String) throws {
        let target = try Self.validated(newName)
        guard var preset = try load(name) else { throw PresetError.notFound(name) }
        guard target != name else { return }
        let from = url(for: name), to = url(for: target)
        let sameFile = FileManager.default.fileExists(atPath: to.path)
            && ((try? to.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier?
                .isEqual(from.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)) ?? false)
        if FileManager.default.fileExists(atPath: to.path), !sameFile { throw PresetError.nameExists(target) }
        preset.name = target
        preset.updated = Date()
        if sameFile {
            guard Darwin.rename(from.path, to.path) == 0 else { throw PresetError.nameExists(target) }
            try write(preset, to: to)
        } else {
            try save(preset)
            try remove(name)
        }
    }

    /// Every readable preset, sorted by name, plus the files that exist but
    /// could not be decoded (left alone, never overwritten).
    func loadAll() -> (presets: [Preset], unreadable: [URL]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        var presets: [Preset] = []
        var unreadable: [URL] = []
        for file in entries where file.pathExtension == Self.fileExtension {
            do {
                let data = try Data(contentsOf: file)
                presets.append(try Self.decode(data))
            } catch {
                unreadable.append(file)
            }
        }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (presets, unreadable)
    }

    /// Writes the starter set when the directory does not exist yet (a fresh
    /// install). A starter the user deleted stays deleted: the directory is
    /// there, so nothing is seeded again. Returns true when it seeded.
    @discardableResult
    func seedStartersIfMissing() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return false }
        try writeStarters()
        return true
    }

    /// Writes (or rewrites) every starter preset.
    func writeStarters() throws {
        for preset in Preset.starters { try save(preset) }
    }

    /// Decodes one preset file; a `version` above `Preset.currentVersion`
    /// is refused (written by a newer PhotoLab) rather than read with its
    /// unknown fields dropped.
    static func decode(_ data: Data) throws -> Preset {
        let doc = try decoder.decode(Preset.self, from: data)
        guard doc.version <= Preset.currentVersion else {
            throw PresetError.unsupportedVersion(doc.name, doc.version)
        }
        return doc
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

/// The presets as the app sees them: the store's files read into memory,
/// re-read after every change, the last error for the panel to show.
@MainActor
@Observable
final class PresetLibrary {
    private(set) var presets: [Preset] = []
    private(set) var unreadable: [URL] = []
    /// The last operation that failed, for the panel to show.
    var error: String?
    /// Set by the Presets menu; the panel shows its Save sheet on it.
    var saveRequested = false
    /// The Lightroom presets picked and not yet saved or cancelled, one sheet
    /// each; the first is shown (`XMPImportSheet`).
    var xmpImports: [XMPImportModel] = []

    let store: PresetStore

    init(store: PresetStore = PresetStore()) {
        self.store = store
        do {
            try store.seedStartersIfMissing()
        } catch {
            self.error = "Could not create the presets folder: \(error.localizedDescription)"
        }
        reload()
    }

    /// Re-reads the store. The standing "could not read" message is shown
    /// only when no operation has just failed: `run` sets `error` before
    /// this reload, and a failed save or rename must not be masked by it.
    func reload() {
        let loaded = store.loadAll()
        presets = loaded.presets
        unreadable = loaded.unreadable
        if error == nil, let first = loaded.unreadable.first {
            error = "Could not read the preset file \(first.lastPathComponent)"
        }
    }

    func preset(named name: String) -> Preset? { presets.first { $0.name == name } }

    /// Saves `recipe` under `name` (replacing a preset of that name).
    @discardableResult
    func save(_ recipe: Recipe, as name: String) -> Preset? {
        run {
            let preset = Preset(name: try PresetStore.validated(name), from: recipe)
            try store.save(preset)
            return preset
        }
    }

    func delete(_ name: String) {
        run { try store.remove(name) }
    }

    func rename(_ name: String, to newName: String) {
        run { try store.rename(name, to: newName) }
    }

    /// Rewrites the starter set (a deleted or edited starter comes back).
    func restoreStarters() {
        run { try store.writeStarters() }
    }

    @discardableResult
    private func run<T>(_ body: () throws -> T) -> T? {
        defer { reload() }
        do {
            let out = try body()
            error = nil
            return out
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// What one recipe changes against another, as a list for a sheet to show.
/// Pure. Reused by the Lightroom import sheet (`XMPImportModel`) and the
/// look-match sheet.
enum RecipeDiff {
    /// Every kind whose applied value (`Recipe.effective`, neutral when
    /// disabled) in `to` differs from `from`, in `AdjustmentKind.allCases`
    /// order, with `to`'s value. Masks are not listed.
    static func moved(from: Recipe, to: Recipe) -> [(AdjustmentKind, Double)] {
        AdjustmentKind.allCases.compactMap { kind in
            let value = to.effective(kind)
            return value == from.effective(kind) ? nil : (kind, value)
        }
    }
}
