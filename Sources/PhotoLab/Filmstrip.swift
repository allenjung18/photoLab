import SwiftUI

/// One cell of the loupe's filmstrip: everything a grid cell shows for the
/// photo, resolved from the library, so the view holds no rules.
struct FilmstripItem: Identifiable, Equatable {
    let photo: Photo
    /// The thumbnail cache entry: the grid's own key (`Thumbnails.Key`), so
    /// a strip cell and a grid cell of one photo share one cache entry.
    let key: Thumbnails.Key
    let selected: Bool
    let anchor: Bool
    let edited: Bool
    let marks: Marks

    var id: Photo.ID { photo.id }
}

/// The filmstrip under the loupe canvas: its items and its click, testable
/// without a view. The strip walks `Library.visiblePhotos`, so a filter
/// (a rejected photo under Picks) shapes it exactly as it shapes the grid.
@MainActor
enum Filmstrip {
    /// UserDefaults key of the show/hide choice (`AppSettings.showFilmstrip`).
    static let showKey = AppSettings.Key.showFilmstrip

    static func items(for library: Library) -> [FilmstripItem] {
        library.visiblePhotos.map { photo in
            FilmstripItem(photo: photo,
                          key: Thumbnails.Key(photo.id, recipe: library.recipe(for: photo.id)),
                          selected: library.selectedIDs.contains(photo.id),
                          anchor: photo.id == library.selection,
                          edited: library.isEdited(photo.id),
                          marks: library.marks(for: photo.id))
        }
    }

    /// A click on a cell: the grid's rules (`Library.click`), the anchor
    /// moving to it, so the loupe shows that photo; ⇧ extends and ⌘ toggles.
    static func click(_ id: Photo.ID, in library: Library, extending: Bool = false, toggling: Bool = false) {
        library.click(id, extending: extending, toggling: toggling)
    }
}

/// The strip itself: a lazy horizontal row of small cells, the anchor ringed
/// and scrolled into view.
struct FilmstripView: View {
    @Environment(Library.self) private var library
    private let cell: CGFloat = 64

    var body: some View {
        let items = Filmstrip.items(for: library)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(items) { item in
                        FilmstripCell(item: item, side: cell)
                            .id(item.id)
                            .task(id: item.id) { if !item.photo.isNamed { await library.resolveName(item.id) } }
                            .contextMenu { PhotoContextMenu(photo: item.photo) }
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                Filmstrip.click(item.id, in: library,
                                                extending: flags.contains(.shift),
                                                toggling: flags.contains(.command))
                            }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .onChange(of: library.selection, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: cell + 16)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct FilmstripCell: View {
    let item: FilmstripItem
    let side: CGFloat
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(item.selected ? Color.accentColor : .clear, lineWidth: item.anchor ? 4 : 3))
        .overlay(alignment: .topTrailing) {
            if item.edited {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(3)
                    .background(.thinMaterial, in: Circle())
                    .padding(2)
                    .help("Edited")
            }
        }
        .overlay(alignment: .topLeading) {
            if let flag = item.marks.flag {
                Image(systemName: flag == .pick ? "flag.fill" : "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(flag == .pick ? Color.accentColor : Color.black.opacity(0.7), in: Circle())
                    .padding(2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item.marks.rating > 0 {
                HStack(spacing: 0) {
                    ForEach(1...Marks.maxRating, id: \.self) { n in
                        Image(systemName: n <= item.marks.rating ? "star.fill" : "star")
                            .font(.system(size: 5))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let n = item.photo.id.copyNumber { VirtualCopyBadge(number: n, size: 7).padding(2) }
        }
        .opacity(item.marks.flag == .reject ? 0.55 : 1)
        .contentShape(Rectangle())
        .help(failed ? "Can't open \(item.photo.caption)" : item.photo.caption)
        .task(id: item.key) {
            switch await Thumbnails.shared.resolve(item.key, showing: image) {
            case .image(let found): image = found; failed = false
            case .failed: failed = true
            case .unchanged: break
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.photo.caption)
        .accessibilityAddTraits(.isButton)
    }
}
