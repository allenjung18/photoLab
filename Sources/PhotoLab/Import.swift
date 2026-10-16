import Foundation
import AppKit
import UniformTypeIdentifiers

// Import from a card (File › Import from Card…, ⇧⌘I): the photos on a
// memory card, a camera that mounts as a disk, or any folder, copied into a
// dated tree under one root (`<root>/YYYY/YYYY-MM-DD/<name>`). The source is
// only ever read: nothing on it is moved, renamed or deleted.

/// One mounted volume as the system lists it.
struct MountedVolume: Equatable, Sendable {
    let url: URL
    let name: String
    let isRemovable: Bool
    let isEjectable: Bool
}

/// Lists the mounted volumes: `LiveVolumeLister` in the app, a fake over
/// temporary folders in the tests, so no test reads a real volume.
protocol VolumeLister: Sendable {
    func volumes() -> [MountedVolume]
}

/// The mounted volumes from `FileManager.mountedVolumeURLs`, each with its
/// `volumeIsRemovable` / `volumeIsEjectable` and its localized name.
struct LiveVolumeLister: VolumeLister {
    func volumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return MountedVolume(url: url, name: v?.volumeLocalizedName ?? url.lastPathComponent,
                                 isRemovable: v?.volumeIsRemovable ?? false,
                                 isEjectable: v?.volumeIsEjectable ?? false)
        }
    }
}

/// A card: a removable or ejectable volume whose top level holds a `DCIM`
/// folder (the camera file system's photo folder). Its photos are imported
/// from `dcim`.
struct Card: Identifiable, Equatable, Sendable {
    var id: URL { volume }
    let volume: URL
    let name: String
    let dcim: URL
}

/// The cards among the mounted volumes (`list(_:)`).
enum CardVolumes {
    /// A removable or ejectable volume whose top level could not be read.
    struct Unreadable: Equatable, Sendable {
        let name: String
        let message: String
        /// Refused by macOS's privacy check (Files and Folders › Removable
        /// Volumes), which Open System Settings can grant.
        let isPermission: Bool
    }

    struct Listing: Equatable, Sendable {
        var cards: [Card] = []
        var unreadable: [Unreadable] = []
    }

    /// Every volume the lister names that is removable or ejectable and
    /// holds a top-level `DCIM` folder (any case), in the lister's order.
    /// Only the volume's top level is read here. A volume that cannot be
    /// read is listed in `unreadable`; the first read of a removable volume
    /// is when macOS asks the user once (TCC, Removable Volumes).
    static func list(_ lister: any VolumeLister) -> Listing {
        var listing = Listing()
        for volume in lister.volumes() where volume.isRemovable || volume.isEjectable {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: volume.url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            } catch {
                listing.unreadable.append(Unreadable(name: volume.name, message: error.localizedDescription,
                                                     isPermission: isPermissionError(error)))
                continue
            }
            guard let dcim = entries.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare("DCIM") == .orderedSame
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { continue }
            listing.cards.append(Card(volume: volume.url, name: volume.name, dcim: dcim))
        }
        return listing
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(under) }
        return false
    }
}

/// What an import copies, worked out before a byte is written: every
/// regular, non-hidden file under the source whose type conforms to
/// `public.image` (a RAW+JPEG pair is two files and both go), each to
/// `<root>/YYYY/YYYY-MM-DD/<name>` by its capture date (`CaptureDates.read`:
/// EXIF `DateTimeOriginal` in local time, else the file's creation date,
/// else its modification date; `Undated/` when none can be read). Videos and
/// every other file are skipped and counted.
///
/// A destination that already holds a file of the same name AND byte size
/// is that photo, already imported: skipped. Same name, another size: the
/// next free `<stem> 2.<ext>`, `<stem> 3.<ext>` … (each of those checked by
/// the same rule). Two files of this run that land on one name are numbered
/// the same way. Nothing is ever overwritten.
struct ImportPlan: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let source: URL
        let destination: URL
        let size: Int
        /// `YYYY-MM-DD`, nil when the file has no date (`Undated/`).
        let day: String?
    }

    let source: URL
    let root: URL
    /// Files to copy (new to the root).
    var copies: [Item] = []
    /// Files the root already holds (same name and size where they would go).
    var already: [Item] = []
    /// Files skipped as not photos (videos, sidecars, anything else).
    var otherFiles = 0

    /// The folder for undated files, under the root.
    static let undatedFolder = "Undated"

    /// Plans `source` into `root`. `captureDate` is injected so a test can
    /// set a fixture's date; the app passes `CaptureDates.read`.
    static func make(source: URL, root: URL,
                                 captureDate: (URL) -> Date? = CaptureDates.read) -> ImportPlan {
        var plan = ImportPlan(source: source, root: root)
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return plan }
        var files: [(URL, Int)] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            guard let type = v.contentType, type.conforms(to: .image) else {
                plan.otherFiles += 1
                continue
            }
            files.append((url, v.fileSize ?? 0))
        }
        files.sort { $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending }
        // Destinations this run has taken, so two files never share one.
        var taken = Set<String>()
        for (file, size) in files {
            let day = captureDate(file).map(dayFolder)
            let folder = day.map { root.appendingPathComponent(String($0.prefix(4)), isDirectory: true)
                                       .appendingPathComponent($0, isDirectory: true) }
                ?? root.appendingPathComponent(undatedFolder, isDirectory: true)
            var n = 1
            while true {
                let destination = folder.appendingPathComponent(numbered(file.lastPathComponent, n))
                defer { n += 1 }
                if taken.contains(destination.path) { continue }
                if let existing = sizeOnDisk(destination) {
                    if existing == size {
                        plan.already.append(Item(source: file, destination: destination, size: size, day: day))
                        break
                    }
                    continue
                }
                taken.insert(destination.path)
                plan.copies.append(Item(source: file, destination: destination, size: size, day: day))
                break
            }
        }
        return plan
    }

    /// `name` for 1, else `<stem> n.<ext>` (`<name> n` without an extension).
    static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    /// `YYYY-MM-DD` of `date` in the local time zone (Gregorian).
    static func dayFolder(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The byte size of a regular file at `url`; nil when nothing is there.
    static func sizeOnDisk(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// The folder Open shows after an import of `items` into `root`: their
    /// one day folder when they all share a day, else their one year folder
    /// when they all share a year, else the root (also for none, or any
    /// undated file among dated ones).
    static func commonFolder(of items: [Item], root: URL) -> URL {
        let days = Set(items.map(\.day))
        guard !items.isEmpty, !days.contains(nil) else {
            return days == [nil] ? root.appendingPathComponent(undatedFolder, isDirectory: true) : root
        }
        let dated = days.compactMap { $0 }
        let years = Set(dated.map { String($0.prefix(4)) })
        guard years.count == 1, let year = years.first else { return root }
        let yearFolder = root.appendingPathComponent(year, isDirectory: true)
        return dated.count == 1 ? yearFolder.appendingPathComponent(dated[0], isDirectory: true) : yearFolder
    }

    /// The folder Open shows for this whole plan (`commonFolder(of:root:)`).
    var commonFolder: URL { Self.commonFolder(of: copies + already, root: root) }
}

/// Where an import reads from: a card (its `DCIM` folder, and Eject when
/// done) or any folder chosen with Choose Folder….
enum ImportSource: Equatable, Sendable {
    case card(Card)
    case folder(URL)

    var url: URL {
        switch self {
        case .card(let card): return card.dcim
        case .folder(let url): return url
        }
    }

    var displayName: String {
        switch self {
        case .card(let card): return card.name
        case .folder(let url): return url.lastPathComponent
        }
    }

    var card: Card? {
        if case .card(let card) = self { return card }
        return nil
    }
}

/// The import: the sheet's state (the cards, the source, the root, the
/// plan) and the copy run, with progress the sheet shows and a Cancel that
/// stops after the file in flight (as `ExportQueue` does). One per app.
/// Each file is copied to a hidden `.<name>.partial` beside its destination
/// and moved into place (`copy(_:to:)`), so a cancelled or failed copy never
/// leaves a half file under its real name and a move never overwrites.
/// Eject is a button (`eject()`), never automatic.
@MainActor
@Observable
final class Importer {
    enum State: Equatable { case idle, running, finished, cancelled }

    struct Failure: Identifiable {
        let id = UUID()
        let source: URL
        let message: String
    }

    /// Copies one file (source, destination); the default is `copy(_:to:)`.
    typealias Copier = @Sendable (URL, URL) throws -> Void
    /// Unmounts and ejects a card's volume; the default is NSWorkspace's.
    typealias Ejector = @MainActor (URL) throws -> Void

    /// The sheet is up.
    var sheetShown = false
    private(set) var listing = CardVolumes.Listing()
    private(set) var listingDone = false
    private(set) var source: ImportSource?
    /// The destination root; a change is remembered (`AppSettings.importRoot`).
    private(set) var root: URL
    /// The plan for `source` into `root`; nil while it is being made.
    private(set) var plan: ImportPlan?
    private(set) var planning = false

    private(set) var state: State = .idle
    private(set) var total = 0
    private(set) var done = 0
    private(set) var failures: [Failure] = []
    /// The items written by this run.
    private(set) var copied: [ImportPlan.Item] = []
    /// The file being copied right now.
    private(set) var current: URL?
    /// The card was ejected after the run.
    private(set) var ejected = false
    private(set) var ejectError: String?

    let settings: AppSettings
    private let lister: any VolumeLister
    private let copier: Copier
    private let ejector: Ejector
    private let captureDate: @Sendable (URL) -> Date?
    private var task: Task<Void, Never>?
    private var planGeneration = 0

    /// `~/Pictures/PhotoLab`.
    nonisolated static var defaultRoot: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("PhotoLab", isDirectory: true)
    }

    init(settings: AppSettings = AppSettings(persistent: false),
         lister: any VolumeLister = LiveVolumeLister(),
         captureDate: @escaping @Sendable (URL) -> Date? = { CaptureDates.read($0) },
         ejector: @escaping Ejector = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) },
         copier: @escaping Copier = { try Importer.copy($0, to: $1) }) {
        self.settings = settings
        self.lister = lister
        self.captureDate = captureDate
        self.ejector = ejector
        self.copier = copier
        root = settings.importRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRoot
    }

    var isRunning: Bool { state == .running }
    /// Files finished: copied or failed.
    var completed: Int { done + failures.count }
    /// The folder Open shows: the common folder of what this run copied and
    /// what was already there.
    var openFolder: URL? {
        guard let plan, state == .finished || state == .cancelled else { return nil }
        let items = copied + plan.already
        guard !items.isEmpty else { return nil }
        return ImportPlan.commonFolder(of: items, root: root)
    }

    // MARK: The sheet

    /// Import from Card…: shows the sheet and lists the cards. Ignored while
    /// a run is going (the sheet is already up).
    func request() {
        guard !isRunning else { return }
        if state != .idle { reset() }
        sheetShown = true
        Task { await refresh() }
    }

    /// Lists the cards again (the sheet's Refresh); the first card is picked
    /// when nothing is.
    func refresh() async {
        let lister = self.lister
        listing = await Task.detached(priority: .userInitiated) { CardVolumes.list(lister) }.value
        listingDone = true
        if source == nil, let first = listing.cards.first {
            choose(.card(first))
        } else if let card = source?.card, !listing.cards.contains(card) {
            source = nil
            plan = nil
        }
    }

    /// Picks the source and plans it.
    func choose(_ newSource: ImportSource) {
        guard !isRunning else { return }
        source = newSource
        replan()
    }

    /// Sets the destination root, remembers it and plans again.
    func setRoot(_ url: URL) {
        guard !isRunning else { return }
        root = url
        settings.importRoot = url.path
        replan()
    }

    private func replan() {
        planGeneration += 1
        let generation = planGeneration
        plan = nil
        guard let source else { planning = false; return }
        planning = true
        let from = source.url, root = self.root, date = captureDate
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                ImportPlan.make(source: from, root: root, captureDate: date)
            }.value
            guard let self, generation == self.planGeneration else { return }
            self.plan = made
            self.planning = false
        }
    }

    /// Returns when the plan in the making is made (tests).
    func waitForPlan() async {
        while planning { await Task.yield() }
    }

    // MARK: The run

    /// Copies the plan's new files. Ignored while a run is going or with no
    /// plan.
    func start() {
        guard !isRunning, let plan, !plan.copies.isEmpty else { return }
        state = .running
        total = plan.copies.count
        done = 0
        failures = []
        copied = []
        current = nil
        ejected = false
        ejectError = nil
        let copier = self.copier
        task = Task { [weak self] in
            for item in plan.copies {
                if Task.isCancelled { break }
                self?.current = item.source
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try copier(item.source, item.destination) }
                }.value
                guard let self else { return }
                switch result {
                case .success:
                    self.done += 1
                    self.copied.append(item)
                case .failure(let error):
                    self.failures.append(Failure(source: item.source, message: error.localizedDescription))
                }
            }
            guard let self else { return }
            self.current = nil
            self.state = Task.isCancelled ? .cancelled : .finished
        }
    }

    /// Stops the run after the file in flight; what is copied stays.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    /// Returns when the run has ended (tests).
    func wait() async {
        await task?.value
    }

    /// Ejects the source card (the finished sheet's Eject). Never called by
    /// the run itself.
    func eject() {
        guard !isRunning, let card = source?.card, !ejected else { return }
        do {
            try ejector(card.volume)
            ejected = true
            ejectError = nil
            listing.cards.removeAll { $0 == card }
        } catch {
            ejectError = error.localizedDescription
        }
    }

    /// Opens the import's common folder in `library` (`Library.open`) and
    /// closes the sheet.
    func open(in library: Library) {
        guard let folder = openFolder else { return }
        library.open(folder)
        dismiss()
    }

    /// Closes the sheet; a finished run's result is cleared. Ignored while
    /// a run is going.
    func dismiss() {
        guard !isRunning else { return }
        sheetShown = false
        reset()
    }

    private func reset() {
        state = .idle
        total = 0
        done = 0
        failures = []
        copied = []
        ejected = false
        ejectError = nil
        if source != nil { replan() }
    }

    /// Copies `source` to a hidden `.<name>.partial` beside `destination`,
    /// then moves it to `destination`; the move fails rather than replace a
    /// file that is already there. On any failure the partial file is
    /// removed. The source is only read.
    nonisolated static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = partialURL(for: destination)
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: source, to: partial)
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `.<name>.partial` beside `destination`.
    nonisolated static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + ".partial")
    }
}

/// The folder pickers behind the import sheet's Choose Folder… and Change….
@MainActor
enum ImportPanel {
    static func chooseSource() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of photos to import"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseRoot(from current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = current
        panel.message = "Choose the folder imports go into (dated folders are made inside it)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// System Settings › Privacy & Security › Files and Folders, where the
    /// Removable Volumes access is granted.
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
