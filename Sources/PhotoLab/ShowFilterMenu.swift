import SwiftUI

/// View › Show: the grid's filter (All · Picks · Unflagged · Rejected ·
/// ≥ 1…5 stars) as menu items, the same choice the bar above the grid makes.
enum ShowFilterChoices {
    /// Every filter, in the bar's order.
    static var all: [PhotoFilter] { PhotoFilter.allCases }

    /// Choosing an entry sets the library's filter.
    @MainActor static func choose(_ filter: PhotoFilter, in library: Library) {
        library.filter = filter
    }
}

struct ShowFilterMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        Menu("Show") {
            ForEach(ShowFilterChoices.all, id: \.self) { filter in
                Toggle(filter.label, isOn: Binding(
                    get: { library.filter == filter },
                    set: { _ in ShowFilterChoices.choose(filter, in: library) }))
            }
        }
        .disabled(library.photos.isEmpty)
    }
}
