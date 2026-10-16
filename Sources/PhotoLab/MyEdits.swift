import SwiftUI
import AppKit

/// The habits in a set of recipes (View › My Edits): per slider kind, how many
/// photos use it and the median value, most-used first. Pure: it reads recipes
/// and writes nothing. A kind counts for a photo when its entry is enabled and
/// off neutral (`Adjustment.isNoop` is false), so a disabled entry is not a
/// habit.
struct EditSummary: Equatable {
    struct Habit: Equatable {
        let kind: AdjustmentKind
        /// How many photos use the kind.
        let photos: Int
        /// The median of their values (the mean of the middle two when even).
        let median: Double
    }

    /// Photos that carry at least one enabled non-neutral slider or mask.
    let editedPhotos: Int
    /// Most-used first; ties keep `AdjustmentKind.allCases` order.
    let habits: [Habit]

    init(recipes: [Recipe]) {
        var values: [AdjustmentKind: [Double]] = [:]
        var edited = 0
        for recipe in recipes {
            var any = recipe.masks.contains { !$0.isNoop }
            for entry in recipe.adjustments where !entry.isNoop {
                values[entry.kind, default: []].append(entry.value)
                any = true
            }
            if any { edited += 1 }
        }
        editedPhotos = edited
        let order = Dictionary(uniqueKeysWithValues: AdjustmentKind.allCases.enumerated().map { ($1, $0) })
        habits = values.map { kind, vs in
            let sorted = vs.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
            return Habit(kind: kind, photos: vs.count, median: median)
        }.sorted { a, b in
            a.photos != b.photos ? a.photos > b.photos : order[a.kind]! < order[b.kind]!
        }
    }
}

/// One row of the My Edits list: a photo (a virtual copy is its own) with the
/// sliders it has on, grouped by panel section, and its mask count.
struct MyEditsRow: Identifiable, Equatable {
    struct Group: Equatable {
        let section: AdjustmentKind.Section
        /// (kind, formatted value) in `AdjustmentKind.allCases` order.
        let entries: [(kind: AdjustmentKind, text: String)]

        static func == (a: Group, b: Group) -> Bool {
            a.section == b.section && a.entries.map(\.kind) == b.entries.map(\.kind)
                && a.entries.map(\.text) == b.entries.map(\.text)
        }
    }

    let photo: Photo
    let recipe: Recipe
    let groups: [Group]
    /// Enabled masks that change something.
    let masks: Int

    var id: Photo.ID { photo.id }
    var masksText: String? { masks == 0 ? nil : "\(masks) mask\(masks == 1 ? "" : "s")" }

    /// The rows for `photos` in their order: only photos with an enabled
    /// non-neutral slider or mask in `recipes`. Pure.
    static func rows(photos: [Photo], recipes: [Photo.ID: Recipe]) -> [MyEditsRow] {
        photos.compactMap { photo in
            guard let recipe = recipes[photo.id] else { return nil }
            let on = recipe.adjustments.filter { !$0.isNoop }
            let masks = recipe.masks.filter { !$0.isNoop }.count
            guard !on.isEmpty || masks > 0 else { return nil }
            let groups = AdjustmentKind.Section.allCases.compactMap { section -> Group? in
                let entries = on.filter { $0.kind.section == section }
                    .sorted { AdjustmentKind.allCases.firstIndex(of: $0.kind)! < AdjustmentKind.allCases.firstIndex(of: $1.kind)! }
                    .map { (kind: $0.kind, text: $0.kind.format($0.value)) }
                return entries.isEmpty ? nil : Group(section: section, entries: entries)
            }
            return MyEditsRow(photo: photo, recipe: recipe, groups: groups, masks: masks)
        }
    }
}

extension Library {
    /// The rows and habits of the open source's edited photos.
    var myEdits: (rows: [MyEditsRow], summary: EditSummary) {
        let rows = MyEditsRow.rows(photos: photos, recipes: recipes)
        return (rows, EditSummary(recipes: rows.map(\.recipe)))
    }

    /// A row was clicked: select the photo, open the loupe, close the sheet.
    func openFromMyEdits(_ id: Photo.ID) {
        selection = id
        loupe = selection != nil
        myEditsSheet = false
    }
}

struct MyEditsSheet: View {
    @Environment(Library.self) private var library

    var body: some View {
        let data = library.myEdits
        VStack(alignment: .leading, spacing: 12) {
            Text("My Edits").font(.title3.weight(.semibold))
            if data.rows.isEmpty {
                Text("No edited photos in this folder yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(data.rows.count) edited photo\(data.rows.count == 1 ? "" : "s"). Read only: click a row to open it in the loupe.")
                    .font(.callout).foregroundStyle(.secondary)
                if !data.summary.habits.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your habits").font(.callout.weight(.semibold))
                        ForEach(data.summary.habits.prefix(8), id: \.kind) { h in
                            HStack {
                                Text(h.kind.label)
                                Spacer()
                                Text("\(h.photos) photo\(h.photos == 1 ? "" : "s"), median \(h.kind.format(h.median))")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(data.rows) { row in
                            Button { library.openFromMyEdits(row.id) } label: { MyEditsRowView(row: row) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { library.myEditsSheet = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }
}

private struct MyEditsRowView: View {
    let row: MyEditsRow
    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .frame(width: 72, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.photo.caption).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                ForEach(row.groups, id: \.section) { g in
                    Text(g.section.title + ": " + g.entries.map { "\($0.kind.label) \($0.text)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let masks = row.masksText { Text(masks).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .task(id: row.id) {
            let key = Thumbnails.Key(row.photo.id, recipe: row.recipe)
            if case .image(let found) = await Thumbnails.shared.resolve(key, showing: image) { image = found }
        }
    }
}
