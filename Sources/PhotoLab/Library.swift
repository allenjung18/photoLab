import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

struct Photo: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The library is a folder. Originals are never written to.
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
    var selection: Photo.ID?
    /// Loupe (single photo) when true, grid otherwise.
    var loupe = false
    /// Edits per photo, in memory for now; chunk 3 moves them to sidecars.
    var recipes: [Photo.ID: Recipe] = [:]
    /// Before/after: true shows the unadjusted photo in the loupe.
    var showBefore = false

    private static let lastFolderKey = "lastFolder"

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Opens a folder; given a file, opens its folder with that photo in the loupe.
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        folder = dir
        selection = nil
        loupe = false
        showBefore = false
        photos = Self.scan(dir)
        UserDefaults.standard.set(dir.path, forKey: Self.lastFolderKey)
        if !isDir.boolValue, let hit = photos.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            selection = hit.id
            loupe = true
        }
    }

    func restoreLastFolder() {
        guard folder == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return photos.firstIndex { $0.id == selection }
    }

    var selectedPhoto: Photo? {
        selectedIndex.map { photos[$0] }
    }

    func recipe(for id: Photo.ID) -> Recipe { recipes[id] ?? .neutral }

    func setRecipe(_ recipe: Recipe, for id: Photo.ID) {
        if recipe == .neutral { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
    }

    func select(offset: Int) {
        guard !photos.isEmpty else { return }
        let i = selectedIndex ?? 0
        let j = min(max(i + offset, 0), photos.count - 1)
        selection = photos[j].id
    }

    /// Every regular file under `folder` whose type conforms to `public.image`:
    /// JPEG, HEIC, PNG, TIFF and every RAW format ImageIO knows.
    static func scan(_ folder: URL) -> [Photo] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Photo] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let type = v.contentType, type.conforms(to: .image) else { continue }
            out.append(Photo(url: url))
        }
        return out.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}
