import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The state of the Import Lightroom Preset sheet for one `.xmp` file: the
/// parse (`XMPPreset.parse`), the name the preset will be saved under, what
/// moves, and the name-taken question. The sheet is a thin view over it, so
/// every path (save, replace, keep both, cancel, a parse error) runs without
/// the app. It writes only through `PresetLibrary.save(_:as:)`, i.e. the
/// presets folder, and only on Save / Replace / Keep Both.
@MainActor
@Observable
final class XMPImportModel: Identifiable {
    /// The file's name, for the title.
    let fileName: String
    /// The parse; nil when the file could not be read or parsed.
    private(set) var parsed: XMPImport?
    /// Why there is no parse: shown in the sheet, never thrown.
    private(set) var error: String?
    /// The name the preset is saved under; starts as the file's own name.
    var name: String
    /// The name is taken: the sheet asks Replace / Keep Both / Cancel.
    private(set) var askingReplace = false
    /// Why the last save failed (the store's message), shown in the sheet:
    /// the library's own error line sits behind the modal.
    private(set) var saveError: String?
    /// Set once the sheet is done (saved or cancelled).
    private(set) var finished = false
    /// Called once when the sheet is done; the queue moves to the next file.
    var onFinish: (() -> Void)?

    private let library: PresetLibrary

    init(fileName: String, library: PresetLibrary, load: () throws -> Data) {
        self.fileName = fileName
        self.library = library
        self.name = (fileName as NSString).deletingPathExtension
        do {
            let result = try XMPPreset.parse(try load(), fileName: fileName)
            parsed = result
            name = result.name
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The sliders the preset moves from neutral, with their values.
    var moved: [(AdjustmentKind, Double)] {
        guard let parsed else { return [] }
        return RecipeDiff.moved(from: .neutral, to: parsed.recipe)
    }

    /// The sheet's "No equivalent in PhotoLab" list: each unsupported
    /// setting's plain label.
    var unsupportedLabels: [String] { parsed?.unsupported.map(\.label) ?? [] }

    /// "Moves N sliders".
    var movesTitle: String {
        let n = moved.count
        return "Moves \(n) slider\(n == 1 ? "" : "s")"
    }

    /// The name after `PresetStore.validated`, nil when it is not valid.
    var validName: String? { try? PresetStore.validated(name) }

    /// A message for the name field, nil when the name is usable.
    var nameProblem: String? {
        do { _ = try PresetStore.validated(name); return nil } catch { return error.localizedDescription }
    }

    var canSave: Bool { parsed != nil && validName != nil }

    /// Save: a free name writes the preset; a taken one asks first.
    func save() {
        guard let parsed, let valid = validName else { return }
        if library.store.exists(valid) {
            askingReplace = true
            return
        }
        write(parsed.recipe, as: valid)
    }

    /// Replace the preset of that name.
    func replace() {
        guard let parsed, let valid = validName else { return }
        askingReplace = false
        write(parsed.recipe, as: valid)
    }

    /// Keep both: save under the first free "name 2", "name 3", ….
    func keepBoth() {
        guard let parsed, let valid = validName else { return }
        askingReplace = false
        write(parsed.recipe, as: freeName(after: valid))
    }

    /// Back to the name field.
    func declineReplace() { askingReplace = false }

    /// Cancel writes nothing.
    func cancel() { finish() }

    /// "name 2", the first of "name 2", "name 3", … that is free and valid.
    func freeName(after base: String) -> String {
        var n = 2
        while true {
            // The suffix must fit inside the name limit: the base is cut, not the number.
            let suffix = " \(n)"
            let candidate = String(base.prefix(PresetStore.maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            if (try? PresetStore.validated(candidate)) != nil, !library.store.exists(candidate) { return candidate }
            n += 1
            if n > 10_000 { return candidate }
        }
    }

    private func write(_ recipe: Recipe, as name: String) {
        if library.save(recipe, as: name) != nil {
            saveError = nil
            finish()
        } else {
            // A failed write leaves the sheet up and says why.
            saveError = library.error ?? "The preset could not be saved."
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?()
    }
}

/// The files picked for import, one sheet at a time (`PresetLibrary.xmpImports`).
extension PresetLibrary {
    /// Queues one sheet per file; each reads its file when built.
    func queueXMPImports(_ files: [URL]) {
        for url in files {
            let model = XMPImportModel(fileName: url.lastPathComponent, library: self) {
                try Data(contentsOf: url)
            }
            model.onFinish = { [weak self, weak model] in
                guard let self, let model else { return }
                self.xmpImports.removeAll { $0.id == model.id }
            }
            xmpImports.append(model)
        }
    }

    /// Presets › Import Lightroom Preset…: the open panel (`.xmp`, several at once).
    func chooseLightroomPresets() {
        let panel = NSOpenPanel()
        panel.title = "Import Lightroom Preset"
        panel.message = "Choose one or more Lightroom .xmp presets."
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { queueXMPImports(panel.urls) }
    }
}

struct XMPImportSheet: View {
    @Bindable var model: XMPImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Lightroom Preset").font(.title3.weight(.semibold))
            Text(model.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.cancel() }.keyboardShortcut(.defaultAction)
                }
            } else if let parsed = model.parsed {
                TextField("Name", text: $model.name)
                if let problem = model.nameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                if let failure = model.saveError {
                    Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        section(model.movesTitle) {
                            ForEach(Array(model.moved.enumerated()), id: \.offset) { _, row in
                                HStack {
                                    Text(row.0.label)
                                    Spacer()
                                    Text(row.0.format(row.1)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        if !parsed.approximated.isEmpty || !parsed.clamped.isEmpty {
                            section("Approximated and clamped") {
                                ForEach(parsed.approximated, id: \.self) { Text("\($0), approximated").font(.callout) }
                                ForEach(parsed.clamped, id: \.self) { Text("\($0), clamped into range").font(.callout) }
                            }
                        }
                        if !model.unsupportedLabels.isEmpty {
                            section("No equivalent in PhotoLab") {
                                ForEach(Array(model.unsupportedLabels.enumerated()), id: \.offset) { _, label in
                                    Text(label).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 320)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                    Button("Save") { model.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSave)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog("A preset named “\(model.validName ?? model.name)” already exists.",
                            isPresented: Binding(get: { model.askingReplace }, set: { if !$0 { model.declineReplace() } })) {
            Button("Replace", role: .destructive) { model.replace() }
            Button("Keep Both") { model.keepBoth() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
    }
}
