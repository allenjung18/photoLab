import SwiftUI

/// The rules for a photo's keywords: the one normal form the sidecar holds
/// (`Sidecar.keywords`), how the Keywords sheet's field is split, and how a
/// set of photos' keywords are counted for the sheet. Keywords are metadata
/// like `Marks`: written through `Library.persist`, never an undo step, never
/// in a `Recipe`, a `Preset` or a `SyncMask`, and a reset leaves them.
enum Keywords {
    /// One keyword as a comparison key: two spellings that differ only by
    /// case are the same keyword.
    static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive], locale: nil)
    }

    /// True when `a` and `b` are the same keyword (case-insensitive).
    static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// Trimmed of whitespace, empty ones dropped, de-duplicated
    /// case-insensitively (the first spelling is kept), sorted
    /// case-insensitively (ties by the plain string), so the same set of
    /// keywords is always the same array and the same JSON.
    static func normalized(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            out.append(trimmed)
        }
        return out.sorted(by: ordered)
    }

    /// The Keywords sheet's field: comma-separated keywords, normalized.
    static func parse(_ text: String) -> [String] {
        normalized(text.split(separator: ",").map(String.init))
    }

    /// One keyword over a set of photos: on how many of them it is.
    struct Tally: Equatable, Identifiable {
        /// The first spelling met.
        let keyword: String
        let count: Int
        var id: String { Keywords.key(keyword) }
    }

    /// Every keyword on any of `lists` (one list per photo) with the number
    /// of lists that hold it, in the `normalized` order.
    static func tally(_ lists: [[String]]) -> [Tally] {
        var spelling: [String: String] = [:]
        var counts: [String: Int] = [:]
        for list in lists {
            for word in Set(normalized(list).map(key)) { counts[word, default: 0] += 1 }
            for word in list where spelling[key(word)] == nil {
                spelling[key(word)] = word.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return counts.keys.compactMap { k in spelling[k].map { Tally(keyword: $0, count: counts[k]!) } }
            .sorted { ordered($0.keyword, $1.keyword) }
    }

    private static func ordered(_ a: String, _ b: String) -> Bool {
        switch a.caseInsensitiveCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a < b
        }
    }
}

/// What the Keywords sheet edits: the photos it was opened over (the batch
/// targets, or a context menu's).
struct KeywordsRequest: Identifiable {
    let id = UUID()
    let targets: [Photo.ID]
}

/// Keywords… (Photo menu, ⌘K; the batch bar; the grid's context menu): a
/// field that adds comma-separated keywords to every target, and each
/// keyword already on any target with "all" or "n of N" and a remove
/// button. The field lives in a sheet, so typing in it never reaches the
/// bare-key shortcuts (`HiddenShortcuts` sits in the main window). Every
/// change is written at once (`Library.addKeywords` / `removeKeyword`);
/// Done only closes.
struct KeywordsSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let request: KeywordsRequest
    @State private var text = ""

    private var count: Int { request.targets.count }

    /// "all" when every target has it, else "n of N".
    static func share(_ tally: Keywords.Tally, of total: Int) -> String {
        tally.count >= total ? "all" : "\(tally.count) of \(total)"
    }

    private func add() {
        library.addKeywords(Keywords.parse(text), to: request.targets)
        text = ""
    }

    var body: some View {
        let tallies = Keywords.tally(request.targets.map { library.keywords(for: $0) })
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? "Keywords for \(library.name(for: request.targets[0]))" : "Keywords for \(count) Photos")
                .font(.headline)
            HStack {
                TextField("Add keywords, separated by commas", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(Keywords.parse(text).isEmpty)
            }
            if tallies.isEmpty {
                Text(count == 1 ? "This photo has no keywords." : "None of these photos has a keyword.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(tallies) { tally in
                            GridRow {
                                Text(tally.keyword)
                                Text(Self.share(tally, of: count))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button {
                                    library.removeKeyword(tally.keyword, from: request.targets)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(tally.keyword)")
                                .help(count == 1 ? "Remove \(tally.keyword) from this photo"
                                                 : "Remove \(tally.keyword) from every one of these photos")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
