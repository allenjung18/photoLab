import Foundation

/// Photo › Remove Virtual Copy… asked for one copy: the window shows this
/// confirm (`ContentView`), and its Remove button runs
/// `Library.removeVirtualCopy`. Not an undo step, hence the confirm.
struct VirtualCopyRemoval: Identifiable, Equatable {
    /// The copy to remove.
    let id: Photo.ID
    /// Its master's name (the copy's own, `Library.name(for:)`).
    let name: String

    var title: String { "Remove \(name) Copy \(id.copyNumber ?? 0)?" }

    var message: String {
        "The copy's edit, marks and keywords are deleted; this cannot be undone. "
            + "The photo itself and its other copies are not touched."
    }
}

extension Library {
    /// The Save to Photos tooltip when the anchor is a virtual copy (the
    /// command is off: `canSaveToPhotos`).
    static let saveToPhotosCopyHelp =
        "A virtual copy can't be saved to Photos: Photos keeps one edit per photo, so it would replace the original's edit. Export it instead."
}

extension PhotoInfo {
    /// The Info section's Virtual Copy row: "Virtual copy 2 of IMG_0001.JPG"
    /// (`master` nil while the photo is unnamed: "Virtual copy 2").
    static func virtualCopy(_ number: Int, of master: String?) -> String {
        guard let master, !master.isEmpty else { return "Virtual copy \(number)" }
        return "Virtual copy \(number) of \(master)"
    }
}
