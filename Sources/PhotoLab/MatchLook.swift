import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Why a Match Look changed nothing.
enum MatchLookError: LocalizedError, Equatable {
    /// The reference file is not a readable image.
    case unreadable(String)
    /// An Auto, a detection or another match is running.
    case busy
    /// Cancelled while solving: nothing was applied.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” could not be read as an image. Nothing changed."
        case .busy: return "Another batch is running. Try again when it ends."
        case .cancelled: return "Match Look cancelled. Nothing changed."
        }
    }
}

/// What a Match Look did: how many photos changed, how many could not be
/// read, and the sliders it moved.
struct MatchLookOutcome {
    /// One slider the match moved on at least one photo.
    struct Row {
        let kind: AdjustmentKind
        /// How many photos it moved on.
        let photos: Int
        /// The mean of the new values over those photos.
        let value: Double
    }

    let changed: Int
    let skipped: Int
    let moved: [Row]

    /// The sliders `RecipeDiff.moved(from:to:)` finds over (before, after)
    /// pairs, in `AdjustmentKind.allCases` order.
    static func rows(_ pairs: [(before: Recipe, after: Recipe)]) -> [Row] {
        var sums: [AdjustmentKind: (n: Int, total: Double)] = [:]
        for pair in pairs {
            for (kind, value) in RecipeDiff.moved(from: pair.before, to: pair.after) {
                let old = sums[kind] ?? (0, 0)
                sums[kind] = (old.n + 1, old.total + value)
            }
        }
        return AdjustmentKind.allCases.compactMap { kind in
            sums[kind].map { Row(kind: kind, photos: $0.n, value: $0.total / Double($0.n)) }
        }
    }
}

/// The state of the Match Look sheet: the reference (one image, D-472 (a)),
/// its thumbnail, the run and what it did. The sheet is a thin view over it.
/// The reference is only read (`Library.matchLook`).
@MainActor
@Observable
final class MatchLookModel: Identifiable {
    /// The photos the match applies to (the batch targets when it opened).
    let targets: [Photo.ID]
    private(set) var reference: URL?
    private(set) var thumbnail: NSImage?
    /// Why there is no reference or why the match changed nothing.
    private(set) var error: String?
    private(set) var running = false
    private(set) var outcome: MatchLookOutcome?
    /// Set once the sheet is done.
    private(set) var finished = false

    private let library: Library

    init(library: Library, targets: [Photo.ID]) {
        self.library = library
        self.targets = targets
    }

    /// The long side of the sheet's thumbnail.
    static let thumbnailPixelSize = 320

    /// Takes `url` as the reference: its thumbnail is read now; a file that
    /// is not a readable image is refused with a message and no reference.
    func setReference(_ url: URL) {
        outcome = nil
        guard let cg = ImageLoading.downsampledCGImage(url, maxPixelSize: Self.thumbnailPixelSize) else {
            reference = nil
            thumbnail = nil
            error = MatchLookError.unreadable(url.lastPathComponent).localizedDescription
            return
        }
        reference = url
        thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        error = nil
    }

    /// The open panel for the reference image.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Match Look"
        panel.message = "Choose the photo whose look to match."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { setReference(url) }
    }

    var canMatch: Bool { reference != nil && !running && outcome == nil && !library.autoToning }

    /// Runs the match; the result (or the error) stays in the sheet.
    func match() async {
        guard let reference, !running else { return }
        running = true
        error = nil
        do {
            outcome = try await library.matchLook(reference: reference, to: targets)
        } catch {
            self.error = error.localizedDescription
        }
        running = false
    }

    /// Stops a running match: nothing is applied.
    func cancelRun() { library.cancelAuto() }

    func close() {
        guard !finished else { return }
        finished = true
        if library.matchLookRequest?.id == id { library.matchLookRequest = nil }
    }
}

extension Library {
    /// Opens the Match Look sheet on `ids` (the batch targets), with
    /// `reference` already chosen when a file was dropped on the loupe.
    /// False when there is nothing to match or a sheet is already up.
    @discardableResult
    func requestMatchLook(for ids: [Photo.ID], reference: URL? = nil) -> Bool {
        guard !ids.isEmpty, matchLookRequest == nil else { return false }
        let model = MatchLookModel(library: self, targets: ids)
        if let reference { model.setReference(reference) }
        matchLookRequest = model
        return true
    }
}

struct MatchLookSheet: View {
    @Bindable var model: MatchLookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match Look").font(.title3.weight(.semibold))
            Text("Brings the tone and colour of a reference photo to \(model.targets.count) photo\(model.targets.count == 1 ? "" : "s") as ordinary slider values. The reference is only read.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let thumbnail = model.thumbnail, let reference = model.reference {
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(reference.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.running {
                HStack { ProgressView().controlSize(.small); Text("Matching…").font(.callout) }
            }
            if let outcome = model.outcome {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outcome.changed == 0 ? "No photo needed a change"
                             : "Moved \(outcome.moved.count) slider\(outcome.moved.count == 1 ? "" : "s") on \(outcome.changed) photo\(outcome.changed == 1 ? "" : "s")")
                            .font(.callout.weight(.semibold))
                        ForEach(Array(outcome.moved.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.kind.label)
                                Spacer()
                                Text(row.kind.format(row.value)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if outcome.skipped > 0 {
                            Text("\(outcome.skipped) photo\(outcome.skipped == 1 ? "" : "s") could not be read, skipped")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                if model.reference == nil || model.outcome == nil {
                    Button("Choose Photo…") { model.choose() }.disabled(model.running)
                }
                Spacer()
                if model.outcome != nil {
                    Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        if model.running { model.cancelRun() } else { model.close() }
                    }.keyboardShortcut(.cancelAction)
                    Button("Match") { Task { await model.match() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canMatch)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
