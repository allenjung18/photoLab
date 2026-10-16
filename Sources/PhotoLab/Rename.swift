import Foundation

/// A file-name template over a batch of photos: literal text with the
/// tokens `{name}` (the original's stem), `{date}` (its capture date,
/// `yyyy-MM-dd`, `undated` when it has none) and `{seq}` (its 1-based place
/// in the batch, counted from `start` and zero-padded to the widest number
/// the batch reaches: 9 photos `1`…`9`, 10 photos `01`…`10`). Anything a file
/// name cannot hold is removed (`clean`, the rule `ExportOptions.cleanSuffix`
/// uses), and a result with nothing left falls back to `{name}`. It makes a
/// stem only; the caller adds the extension. Export's name template
/// (`ExportOptions.nameTemplate`) is one use.
struct RenameTemplate: Codable, Hashable, Sendable {
    static let nameToken = "{name}"
    static let dateToken = "{date}"
    static let seqToken = "{seq}"
    static let tokens = [nameToken, dateToken, seqToken]
    /// What `{date}` becomes for a photo with no capture date.
    static let undated = "undated"

    var pattern: String = "{name}"
    /// The number `{seq}` gives the batch's first photo (never below 0).
    var start: Int = 1

    init(pattern: String = "{name}", start: Int = 1) {
        self.pattern = pattern
        self.start = start
    }

    /// Either field missing from a stored template takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}"
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
    }

    private enum CodingKeys: String, CodingKey { case pattern, start }

    var clampedStart: Int { max(0, start) }

    /// The digits `{seq}` is padded to over a batch of `count`: those of the
    /// largest number it reaches (`start + count - 1`).
    func seqWidth(count: Int) -> Int {
        String(clampedStart + max(count, 1) - 1).count
    }

    /// The stem for the photo at `index` (0-based) of a batch of `count`,
    /// whose original stem is `name` and capture date `date`.
    func stem(name: String, date: Date?, index: Int, count: Int) -> String {
        let n = String(clampedStart + index)
        let seq = String(repeating: "0", count: max(0, seqWidth(count: count) - n.count)) + n
        let expanded = pattern
            .replacingOccurrences(of: Self.nameToken, with: name)
            .replacingOccurrences(of: Self.dateToken, with: date.map(Self.dateString) ?? Self.undated)
            .replacingOccurrences(of: Self.seqToken, with: seq)
        let cleaned = Self.clean(expanded)
        if cleaned.trimmingCharacters(in: .whitespaces).isEmpty { return Self.clean(name) }
        return cleaned
    }

    /// One stem per photo, in order: the batch is `photos`.
    func stems(for photos: [(name: String, date: Date?)]) -> [String] {
        photos.enumerated().map { stem(name: $1.name, date: $1.date, index: $0, count: photos.count) }
    }

    /// `text` with the characters a file name cannot hold removed: `/`, `:`,
    /// `\`, NUL and line breaks.
    static func clean(_ text: String) -> String {
        String(text.filter { !"/:\\\u{0}".contains($0) && !$0.isNewline })
    }

    /// `yyyy-MM-dd` in the local calendar (the zone `CaptureDates` reads
    /// EXIF times in).
    static func dateString(_ date: Date) -> String {
        let d = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }
}

// MARK: Rename in place

/// What Photo › Rename… asks for: the photos it renames, in `batchTargets`
/// order (the order `{seq}` counts in).
struct RenameRequest: Identifiable, Equatable {
    let id = UUID()
    let targets: [Photo.ID]
}

/// One photo of a Rename… batch: its file and the name the template gives
/// it in the same directory, the original's extension kept as it was
/// spelled (`IMG_1.JPG` stays `.JPG`, a file without one gets none).
struct RenameEntry: Equatable, Sendable {
    let id: PhotoID
    let old: URL
    let new: URL

    /// False when the template gives the photo the name it has.
    var changes: Bool { old.lastPathComponent != new.lastPathComponent }
}

/// Why a Rename… batch is refused as a whole: nothing in it is renamed.
enum RenameRefusal: Equatable, Sendable {
    /// The template gives every photo the name it has.
    case nothingChanges
    /// Two photos of the batch would get this name (in one directory,
    /// compared without case, as the Mac's volumes do).
    case duplicate(String)
    /// A file not being renamed already has this name.
    case fileExists(String)
    /// The folder's `.photolab/` already holds an edit for this name (a
    /// file of that name was there once): it would be overwritten.
    case sidecarExists(String)
    /// The name starts with a dot: the file would be hidden, and the
    /// folder scan never lists it.
    case hidden(String)
    /// A photo of the batch is not a file of a folder or a collection, or
    /// is no longer listed.
    case notFiles

    var message: String {
        switch self {
        case .nothingChanges: return "Nothing would change: every photo already has that name."
        case .duplicate(let n): return "Two photos would both be named \(n)."
        case .fileExists(let n): return "A file named \(n) is already there."
        case .sidecarExists(let n): return "An edit for a file named \(n) is already saved in the folder's .photolab."
        case .hidden(let n): return "\(n) starts with a dot, so the file would be hidden."
        case .notFiles: return "Only photos of a folder or a collection can be renamed."
        }
    }
}

/// A Rename… batch worked out before anything moves (the sheet's preview):
/// one entry per photo, in batch order, and the refusal when there is one.
struct RenamePlan: Equatable, Sendable {
    let entries: [RenameEntry]
    let refusal: RenameRefusal?

    /// The entries whose name changes: what `Library.rename(_:)` moves.
    var changing: [RenameEntry] { entries.filter(\.changes) }

    /// The batch `photos` (file, capture date; in order) under `template`.
    /// `sidecarTaken` says whether an entry's new name already has a sidecar
    /// in its store (the library asks the photo's own store).
    static func make(_ template: RenameTemplate, photos: [(id: PhotoID, file: URL, date: Date?)],
                     sidecarTaken: (RenameEntry) -> Bool = { _ in false }) -> RenamePlan {
        let stems = template.stems(for: photos.map { (name: $0.file.deletingPathExtension().lastPathComponent, date: $0.date) })
        let entries = zip(photos, stems).map { photo, stem -> RenameEntry in
            let ext = photo.file.pathExtension
            let name = ext.isEmpty ? stem : stem + "." + ext
            return RenameEntry(id: photo.id, old: photo.file,
                               new: photo.file.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false))
        }
        return RenamePlan(entries: entries, refusal: refusal(for: entries, sidecarTaken: sidecarTaken))
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    private static func refusal(for entries: [RenameEntry], sidecarTaken: (RenameEntry) -> Bool) -> RenameRefusal? {
        let changing = entries.filter(\.changes)
        guard !changing.isEmpty else { return .nothingChanges }
        var seen = Set<String>()
        for e in entries {
            guard seen.insert(key(e.new)).inserted else { return .duplicate(e.new.lastPathComponent) }
        }
        for e in changing {
            let name = e.new.lastPathComponent
            if name.hasPrefix(".") { return .hidden(name) }
            // A case-only rename finds its own file there: that is not a clash.
            if key(e.new) != key(e.old), FileManager.default.fileExists(atPath: e.new.path) {
                return .fileExists(name)
            }
            if sidecarTaken(e) { return .sidecarExists(name) }
        }
        return nil
    }
}

/// One file renamed in place and its sidecars with it: the file moved in
/// its own directory (`FileManager.moveItem`, which never replaces a file),
/// its sidecar and every virtual copy's (`SidecarStore.copies(of:)`,
/// `<name>@copy<n>.json`) under the same store's `.photolab/` with each
/// `original` rewritten to the new name. `reversed` is the move back (Undo, and the
/// rollback of a batch that failed part-way).
struct RenameMove: Sendable {
    let old: URL
    let new: URL
    /// Every store holding an edit for the file (`Library.sidecarStores`):
    /// the open source's, and each other folder or collection root that
    /// keeps one, so no root is left with an edit under the old name.
    let stores: [SidecarStore]

    var oldID: PhotoID { .file(old) }
    var newID: PhotoID { .file(new) }
    var reversed: RenameMove { RenameMove(old: new, new: old, stores: stores) }

    /// Moves the file, then its sidecar when it has one, then each virtual
    /// copy's sidecar; anything that will not move puts back what moved
    /// before throwing, so a move is all or nothing.
    func apply() throws {
        var pairs: [(URL, URL)] = []
        for store in stores {
            let main = store.url(for: oldID)
            if FileManager.default.fileExists(atPath: main.path) { pairs.append((main, renamed(main))) }
            for copy in store.copies(of: [oldID]) {
                let from = store.url(for: copy)
                pairs.append((from, renamed(from)))
            }
        }
        try FileManager.default.moveItem(at: old, to: new)
        var done: [(URL, URL)] = []
        do {
            for (from, to) in pairs {
                try FileManager.default.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            for (from, to) in done.reversed() { try? FileManager.default.moveItem(at: to, to: from) }
            try? FileManager.default.moveItem(at: new, to: old)
            throw error
        }
        for (_, to) in done { Self.rewriteOriginal(at: to, name: new.lastPathComponent) }
    }

    /// The sidecar path `file` (the old name's, or a copy's) takes for the
    /// new name: the same directory, the old file name swapped for the new
    /// at its start. Worked from the old sidecar's own path rather than
    /// `SidecarStore.url(for:)`, which places a path that does not exist yet
    /// by `standardizedFileURL` (`/private/var` stays, `/var` is the folder's)
    /// and so could put it outside its subfolder.
    func renamed(_ file: URL) -> URL {
        Self.renamed(file, from: old.lastPathComponent, to: new.lastPathComponent)
    }

    static func renamed(_ file: URL, from oldName: String, to newName: String) -> URL {
        let name = file.lastPathComponent
        guard name.hasPrefix(oldName) else { return file }
        return file.deletingLastPathComponent()
            .appendingPathComponent(newName + name.dropFirst(oldName.count), isDirectory: false)
    }

    /// True when `store` already holds an edit for the new name: its own
    /// sidecar or a copy's (`<new>@copy<n>.json`) beside where the old
    /// name's would be. A case-only rename finds its own file: not taken.
    static func sidecarTaken(in store: SidecarStore, old: URL, new: URL) -> Bool {
        let from = store.url(for: .file(old))
        let to = renamed(from, from: old.lastPathComponent, to: new.lastPathComponent)
        guard from.path.lowercased() != to.path.lowercased() else { return false }
        if FileManager.default.fileExists(atPath: to.path) { return true }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: to.deletingLastPathComponent().path)) ?? []
        return files.contains { SidecarStore.parseCopy($0)?.base == new.lastPathComponent }
    }

    /// The sidecar's `original` set to `name`, everything else as it was. A
    /// sidecar this build cannot read is moved as it is and left unwritten.
    static func rewriteOriginal(at file: URL, name: String) {
        guard let data = try? Data(contentsOf: file), var doc = try? SidecarStore.decode(data),
              doc.original != name else { return }
        doc.original = name
        guard let out = try? SidecarStore.encode(doc) else { return }
        try? out.write(to: file, options: .atomic)
    }

    /// Every move in order; when one throws, the ones done are moved back
    /// (newest first) and the error names the photo that failed.
    static func perform(_ moves: [RenameMove]) throws {
        var done: [RenameMove] = []
        for m in moves {
            do {
                try m.apply()
            } catch {
                for d in done.reversed() { try? d.reversed.apply() }
                throw RenameError.failed(m.old.lastPathComponent, error.localizedDescription)
            }
            done.append(m)
        }
    }
}

enum RenameError: LocalizedError, Equatable {
    case failed(String, String)

    var errorDescription: String? {
        switch self {
        case .failed(let name, let why): return "Could not rename \(name): \(why)"
        }
    }
}

/// What Edit › Undo Rename and the banner's Undo take back: the last
/// Rename… batch's moves. Valid until the next `open` (or `closeSource`),
/// a move to the Trash, or another rename.
struct RenameUndo: Sendable {
    let moves: [RenameMove]

    var banner: String {
        moves.count == 1 ? "Renamed 1 photo" : "Renamed \(moves.count) photos"
    }
}

import SwiftUI

/// Photo › Rename…: a template over the request's photos, every old → new
/// name previewed (`Library.renamePlan`), and Rename refused while the
/// plan is (`RenamePlan.refusal`, said in red). The originals' files are
/// renamed in place (`Library.rename`); Edit › Undo Rename takes it back.
struct RenameSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest
    @State private var template = RenameTemplate(pattern: RenameSheet.defaultPattern)

    /// What the sheet opens with: the name kept, a number added.
    static let defaultPattern = "{name}-{seq}"

    var body: some View {
        let plan = library.renamePlan(template, for: request.targets)
        let count = request.targets.count
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? "Rename \(library.name(for: request.targets[0]))" : "Rename \(count) Photos")
                .font(.headline)
            Text("The files are renamed where they are; each keeps its extension and its edit.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Template", text: $template.pattern, prompt: Text("e.g. {date}-{seq}"))
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Start at", value: $template.start, format: .number)
                    .frame(width: 140)
                Text("{name} original name · {date} capture date · {seq} number")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(plan.entries, id: \.old) { e in
                        GridRow {
                            Text(e.old.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text("→").foregroundStyle(.secondary)
                            Text(e.new.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(e.changes ? .primary : .secondary)
                        }
                    }
                }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            if let refusal = plan.refusal {
                Text(refusal.message)
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.changing.count > 1 ? "Rename \(plan.changing.count) Photos" : "Rename") {
                    library.rename(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.refusal != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
