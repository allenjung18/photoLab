import SwiftUI

/// One row of the loupe panel's History section (`Library.historyEntries`):
/// a state of the photo's recipe, by its place in the undo history.
/// `position` 0 is the Original (the recipe the photo opened with, or the
/// oldest step kept once the history passes `Library.maxUndoDepth`); step
/// `n` is the recipe after the n-th edit. Rows past the current one are the
/// undone steps redo would bring back.
struct HistoryEntry: Identifiable, Equatable {
    let position: Int
    let label: String
    /// The row the photo shows now.
    let isCurrent: Bool
    /// A step undone and not yet redone (greyed; an edit drops it).
    let isUndone: Bool

    var id: Int { position }
    var isOriginal: Bool { position == 0 }

    static let originalLabel = "Original"
}

/// A history step's label, DERIVED from the two recipes it lies between and
/// never stored, so a kind added later labels itself with no call-site
/// change:
/// - to the default recipe: "Reset";
/// - one kind changed: its name and new value ("Exposure +0.50"), or "on" /
///   "off" when only its switch moved;
/// - any crop edge or rotate counts as the one name "Crop";
/// - two names: both ("Exposure, Contrast"); more: the first two in chain
///   order and a count ("Exposure, Contrast +2 more");
/// - nothing in the adjustments changed (a field outside them): "Edit";
/// - a step taken in a batch (`Library.sync`: Sync Settings, a preset on
///   many photos, Auto) is prefixed "Sync: ".
enum HistoryLabel {
    static let reset = "Reset"
    static let crop = "Crop"
    static let edit = "Edit"
    static let syncPrefix = "Sync: "

    static func describe(from old: Recipe, to new: Recipe, batch: UUID?) -> String {
        (batch == nil ? "" : syncPrefix) + body(from: old, to: new)
    }

    private static func body(from old: Recipe, to new: Recipe) -> String {
        if new.isDefault && !old.isDefault { return reset }
        let changed = AdjustmentKind.allCases.filter { old[$0] != new[$0] }
        var names: [String] = []
        for kind in changed {
            let name = kind.section == .geometry ? crop : AccessibleName.adjustment(kind)
            if !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0:
            return edit
        case 1:
            guard names[0] != crop, let kind = changed.first else { return names[0] }
            let before = old[kind], after = new[kind]
            if before.value == after.value, before.enabled != after.enabled {
                return names[0] + (after.enabled ? " on" : " off")
            }
            return names[0] + " " + kind.format(after.value)
        case 2:
            return names.joined(separator: ", ")
        default:
            return "\(names[0]), \(names[1]) +\(names.count - 2) more"
        }
    }
}

/// The loupe panel's History section: the selected photo's steps, newest on
/// top, the undone ones greyed above the current row, the Original at the
/// bottom. A click jumps there (`Library.jumpToHistory`), stepping through
/// undo or redo, so a batch step takes its batch with it as ⌘Z does.
struct HistoryList: View {
    @Environment(Library.self) private var library
    let photo: Photo

    var body: some View {
        let entries = library.historyEntries(for: photo.id)
        if entries.isEmpty {
            Text("No edits since this photo opened")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entries.reversed()) { entry in
                    Button {
                        library.jumpToHistory(entry.position, for: photo.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(entry.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(entry.isCurrent ? Color.accentColor.opacity(0.2) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.isUndone ? HierarchicalShapeStyle.tertiary : .primary)
                    .help(entry.isCurrent ? "The photo's current state"
                          : entry.isUndone ? "Redo to this step" : "Undo back to this step")
                    .accessibilityAddTraits(entry.isCurrent ? .isSelected : [])
                }
            }
        }
    }
}
