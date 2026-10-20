import Foundation
import Observation

/// A named set of export options: the whole `ExportOptions` (format,
/// quality, size, suffix, collision, metadata and the watermark), picked
/// from the export sheet's Preset menu. The destination (a folder, or the
/// Photos library and its album) is NOT part of a preset: it stays the
/// sheet's own choice. Export presets are user-level files, one JSON per
/// preset, in `ExportPresetStore.defaultDirectory`, apart from the develop
/// presets (`PresetStore`). PhotoLab also ships `builtIn` presets, which
/// are never files.
struct ExportPreset: Codable, Hashable, Identifiable, Sendable {
    static let currentVersion = 1

    var version = ExportPreset.currentVersion
    var name: String
    var options: ExportOptions

    var id: String { name }

    init(name: String, options: ExportOptions) {
        self.name = name
        self.options = options
    }
}

extension ExportPreset {
    /// The presets PhotoLab ships: listed in the sheet's Preset menu above
    /// the saved ones and never stored, so never deleted; a saved preset of
    /// the same name replaces one in the menu.
    static let builtIn: [ExportPreset] = [web]

    /// "For Google Photos / web": a JPEG at quality 85, 2048 px on the long
    /// side, in sRGB with Standard output sharpening (D-475), named
    /// `<stem>-web`, keeping the dates and camera info (Google Photos files
    /// by the capture date) but not where it was taken.
    static let web = ExportPreset(name: "For Google Photos / web", options: ExportOptions(
        format: .jpeg, quality: 0.85, resize: .longSide(2048), keepMetadata: true,
        suffix: "-web", removeLocation: true, colorSpace: .sRGB, sharpening: .standard))
}

enum ExportPresetError: LocalizedError, Equatable {
    case notFound(String)
    case fileNameCollision(String, String)
    /// The file's `version` is above what this build reads.
    case unsupportedVersion(String, Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "There is no export preset named “\(n)”."
        case .fileNameCollision(let a, let b):
            return "“\(a)” and “\(b)” would share a file name; pick a name that differs in more than punctuation."
        case .unsupportedVersion(let n, let v):
            return "The export preset “\(n)” was saved by a newer version of PhotoLab (format \(v); this version reads up to \(ExportPreset.currentVersion))."
        }
    }
}

/// Reads and writes the export presets of one directory:
/// `<directory>/<name>.json`, on `PresetStore`'s rules: names validated by
/// `PresetStore.validated` (trimmed; not empty, hidden, too long or holding
/// a control character), `/` and `:` replaced by `-` in the file name, an
/// atomic write, and a file this build cannot decode (damaged, or a
/// `version` too new) moved aside by `UnreadableBackup` before a save of
/// that name, never overwritten, and listed by `loadAll` as unreadable. The
/// directory is injected so tests never touch the user's Application
/// Support folder.
struct ExportPresetStore {
    /// `~/Library/Application Support/PhotoLab/export-presets/`, beside the
    /// develop presets' `presets/` (`PresetStore.defaultDirectory`), never
    /// inside it.
    static let defaultDirectory: URL = {
        AppDirectories.applicationSupport.appendingPathComponent("PhotoLab/export-presets", isDirectory: true)
    }()
    static let fileExtension = "json"

    let directory: URL

    init(directory: URL = ExportPresetStore.defaultDirectory) {
        self.directory = directory
    }

    /// `<directory>/<name>.json`, with `/` and `:` replaced by `-`.
    func url(for name: String) -> URL {
        let safe = String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return directory.appendingPathComponent(safe, isDirectory: false)
            .appendingPathExtension(Self.fileExtension)
    }

    /// True when a file is stored under `name`, readable or not: the sheet
    /// asks before a save replaces it.
    func exists(_ name: String) -> Bool {
        guard let valid = try? PresetStore.validated(name) else { return false }
        return FileManager.default.fileExists(atPath: url(for: valid).path)
    }

    /// The preset saved under `name`, or nil when there is none. A file that
    /// cannot be decoded throws.
    func load(_ name: String) throws -> ExportPreset? {
        let file = url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Self.decode(try Data(contentsOf: file))
    }

    /// Writes `preset` (atomic: temp file + rename) under its validated
    /// name, replacing a preset of the same name; returns what was written.
    /// A different name that maps to the same file is refused. A file this
    /// build cannot decode is moved to `<name>.json.unreadable-<stamp>`
    /// first (`UnreadableBackup`), never replaced.
    @discardableResult
    func save(_ preset: ExportPreset, now: Date = Date()) throws -> ExportPreset {
        let name = try PresetStore.validated(preset.name)
        let file = url(for: name)
        if FileManager.default.fileExists(atPath: file.path) {
            if let other = try? load(name) {
                if other.name != name { throw ExportPresetError.fileNameCollision(name, other.name) }
            } else {
                try UnreadableBackup.moveAside(file, now: now)
            }
        }
        var doc = preset
        doc.name = name
        doc.version = ExportPreset.currentVersion
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(doc).write(to: file, options: .atomic)
        return doc
    }

    /// Deletes the one file stored under `name`.
    func remove(_ name: String) throws {
        let file = url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ExportPresetError.notFound(name) }
        try FileManager.default.removeItem(at: file)
    }

    /// Every readable preset, sorted by name, plus the `.json` files that
    /// exist but could not be decoded (left alone, never overwritten).
    func loadAll() -> (presets: [ExportPreset], unreadable: [URL]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        var presets: [ExportPreset] = []
        var unreadable: [URL] = []
        for file in entries where file.pathExtension == Self.fileExtension {
            do {
                presets.append(try Self.decode(try Data(contentsOf: file)))
            } catch {
                unreadable.append(file)
            }
        }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        unreadable.sort { $0.lastPathComponent < $1.lastPathComponent }
        return (presets, unreadable)
    }

    /// Decodes one file; a `version` above `ExportPreset.currentVersion` is
    /// refused rather than read with its unknown fields dropped.
    static func decode(_ data: Data) throws -> ExportPreset {
        let doc = try decoder.decode(ExportPreset.self, from: data)
        guard doc.version <= ExportPreset.currentVersion else {
            throw ExportPresetError.unsupportedVersion(doc.name, doc.version)
        }
        return doc
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder = JSONDecoder()
}

/// The export sheet's fields as one value: the options the controls edit
/// directly, the Size controls (`sizeMode`, `longSide`, `percent`) and the
/// Watermark section (`watermarkOn`, `watermark`), with `resolved` folding
/// them into the `ExportOptions` a run uses. A preset pick replaces every
/// field (`pick`); `presetLabel` names the picked preset, or
/// "<name> (edited)" once a field differs from it. The destination is not
/// here: it is the sheet's own state.
struct ExportForm: Equatable {
    enum SizeMode: Hashable { case original, longSide, percent }
    /// The File row's Name: the original's name plus `suffix`, or a
    /// `RenameTemplate`.
    enum NameMode: Hashable { case suffix, template }

    var options: ExportOptions
    var sizeMode: SizeMode
    var longSide: Int
    var percent: Int
    /// The Watermark section's toggle; its fields stay in `watermark` while
    /// it is off, and `resolved` drops them.
    var watermarkOn: Bool
    var watermark: Watermark
    /// The File row's Name choice; the template's fields stay in `template`
    /// while it is off, and `resolved` drops them.
    var nameMode: NameMode
    var template: RenameTemplate
    /// The preset last picked (or saved) in this sheet, as it was then.
    var picked: ExportPreset?

    init(options: ExportOptions, picked: ExportPreset? = nil) {
        self.options = options
        watermarkOn = options.watermark != nil
        watermark = options.watermark ?? Watermark()
        nameMode = options.nameTemplate == nil ? .suffix : .template
        template = options.nameTemplate ?? RenameTemplate()
        switch options.resize {
        case .longSide(let n): sizeMode = .longSide; longSide = n; percent = 50
        case .percent(let p): sizeMode = .percent; longSide = 2048; percent = p
        case nil: sizeMode = .original; longSide = 2048; percent = 50
        }
        self.picked = picked
    }

    /// `options` with the size controls folded into `resize`, the
    /// Watermark section into `watermark` (nil when off or blank) and the
    /// Name choice into `nameTemplate` (nil for original name + suffix).
    var resolved: ExportOptions {
        var o = options
        o.watermark = watermarkOn && !watermark.isBlank ? watermark : nil
        o.nameTemplate = nameMode == .template ? template : nil
        switch sizeMode {
        case .original: o.resize = nil
        case .longSide: o.resize = .longSide(max(1, longSide))
        case .percent: o.resize = .percent(min(100, max(1, percent)))
        }
        return o
    }

    /// Every field set from `preset`'s options (the watermark included,
    /// switched off when the preset has none), and `preset` remembered as
    /// the pick.
    mutating func pick(_ preset: ExportPreset) {
        self = ExportForm(options: preset.options, picked: preset)
    }

    /// True when a field has changed since the pick: the sheet would export
    /// something other than the preset.
    var isEdited: Bool {
        guard let picked else { return false }
        return resolved != ExportForm(options: picked.options).resolved
    }

    /// The first `limit` file names an export of `items` writes under
    /// `resolved`, in order and before any collision handling: a template's
    /// `{seq}` is padded for the whole batch, so the preview matches the run.
    func previewNames(for items: [ExportQueue.Item], limit: Int = 2) -> [String] {
        let o = resolved
        if let stems = o.templatedStems(for: items.map { ($0.source, $0.name, $0.captureDate) }) {
            return zip(stems, items).prefix(limit).map { o.fileName(stem: $0, copy: $1.copyNumber) }
        }
        return items.prefix(limit).map { o.fileName(for: $0.source, name: $0.name, copy: $0.copyNumber) }
    }

    /// The Preset menu's title: "None", the picked name, or
    /// "<name> (edited)".
    var presetLabel: String {
        guard let picked else { return "None" }
        return isEdited ? "\(picked.name) (edited)" : picked.name
    }
}

/// The export presets as the sheet sees them: the store's files read into
/// memory, re-read after every change, the last error for the sheet to
/// show. The last picked name is kept in `AppSettings.exportPreset`.
@MainActor
@Observable
final class ExportPresetLibrary {
    private(set) var presets: [ExportPreset] = []
    private(set) var unreadable: [URL] = []
    /// The last operation that failed, or the standing "could not read".
    var error: String?

    let store: ExportPresetStore

    init(store: ExportPresetStore = ExportPresetStore()) {
        self.store = store
        reload()
    }

    /// Re-reads the store. The standing "could not read" message is shown
    /// only when no operation has just failed.
    func reload() {
        let loaded = store.loadAll()
        presets = loaded.presets
        unreadable = loaded.unreadable
        if error == nil, let first = loaded.unreadable.first {
            error = "Could not read the export preset file \(first.lastPathComponent)"
        }
    }

    /// A saved preset of that name, else a built-in one.
    func preset(named name: String) -> ExportPreset? {
        presets.first { $0.name == name } ?? ExportPreset.builtIn.first { $0.name == name }
    }

    /// The built-in presets no saved preset of the same name replaces.
    var builtIns: [ExportPreset] {
        ExportPreset.builtIn.filter { !isSaved($0.name) }
    }

    /// True when `name` is a saved file (Delete Preset applies), not a built-in.
    func isSaved(_ name: String) -> Bool { presets.contains { $0.name == name } }

    /// True when a save of `name` would replace a file (the sheet asks first).
    func exists(_ name: String) -> Bool { store.exists(name) }

    /// Saves `options` under `name`, replacing a preset of that name;
    /// returns the preset as written, or nil (with `error` set).
    @discardableResult
    func save(_ options: ExportOptions, as name: String) -> ExportPreset? {
        run { try store.save(ExportPreset(name: name, options: options)) }
    }

    /// Deletes the one preset named `name`.
    @discardableResult
    func delete(_ name: String) -> Bool {
        run { try store.remove(name) } != nil
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
