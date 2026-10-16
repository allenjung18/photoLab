import Foundation

/// Moves a file to the Trash and back: the one way PhotoLab changes an
/// original (Photo › Move Rejected Photos to Trash…, `Library.moveToTrash`).
/// The app passes `LiveFileTrasher` (`Library(trasher:)`); every test passes
/// a fake that moves into a temporary directory, so no test ever reaches the
/// real Trash. A library made without one has the command off.
protocol FileTrasher: Sendable {
    /// Moves `url` to the Trash and returns where it landed there.
    func trash(_ url: URL) throws -> URL
    /// Moves a trashed file from `trashed` back to `original` (Undo Move to
    /// Trash). Never replaces a file: the library refuses a taken path first.
    func restore(_ trashed: URL, to original: URL) throws
}

extension FileTrasher {
    func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}

/// The macOS Trash: `FileManager.trashItem(at:resultingItemURL:)`, so the
/// Finder's Put Back knows where the file came from.
struct LiveFileTrasher: FileTrasher {
    func trash(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        guard let landed else { throw TrashError.noResultingURL(url.lastPathComponent) }
        return landed as URL
    }
}

enum TrashError: LocalizedError, Equatable {
    /// The Trash took the file but did not say where it put it.
    case noResultingURL(String)
    /// Undo found another file at the photo's old path.
    case pathTaken(String)

    var errorDescription: String? {
        switch self {
        case .noResultingURL(let name): return "The Trash did not say where \(name) went."
        case .pathTaken(let name): return "a file named \(name) is there now."
        }
    }
}

/// The confirm the window shows before a move: every rejected photo of the
/// open source (`Library.rejectedPhotos`), visible or not.
struct TrashRequest: Identifiable, Equatable {
    let id = UUID()
    let targets: [Photo.ID]
    /// The targets' names, in the same order.
    let names: [String]

    /// How many names the message spells out before "and n more".
    static let namedCount = 3

    var title: String {
        targets.count == 1 ? "Move 1 rejected photo to the Trash?"
            : "Move \(targets.count) rejected photos to the Trash?"
    }

    /// The first names, then the rest counted, and what happens to the edits.
    var message: String {
        let shown = names.prefix(Self.namedCount).joined(separator: ", ")
        let more = names.count - min(names.count, Self.namedCount)
        let list = more > 0 ? "\(shown) and \(more) more" : shown
        return "\(list) \(targets.count == 1 ? "goes" : "go") to the Trash. "
            + "Each edit and its marks stay in the folder's .photolab, so Put Back in the Finder restores them; "
            + "Edit › Undo Move to Trash brings the photos back until you open another source."
    }
}

/// One photo the last move put in the Trash: the photo as it was listed
/// and where the Trash put its file.
struct TrashedPhoto: Equatable {
    let photo: Photo
    let trashedURL: URL
}

/// What Edit › Undo Move to Trash and the banner's Undo take back: the last
/// move's photos. Valid until the next `open` (or `closeSource`).
struct TrashUndo: Equatable {
    let photos: [TrashedPhoto]

    var banner: String {
        photos.count == 1 ? "Moved 1 photo to the Trash" : "Moved \(photos.count) photos to the Trash"
    }
}
