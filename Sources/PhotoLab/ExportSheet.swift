import SwiftUI
import AppKit

/// Export…: the options for one run (format, quality, size, name, collision,
/// metadata, watermark) and the target (a folder, or the Photos library with an
/// album), offered as last time, then the run starts through
/// `ExportQueue.start(_:to:options:)`. For Photos the collision policy is
/// hidden (every export is a new asset) and the access status is shown,
/// with the Allow button as the only prompt. The Preset menu at the top
/// fills every option field from a named `ExportPreset` (never the
/// destination), saves the current fields as one, or deletes the picked one;
/// the fields live in one `ExportForm`.
struct ExportSheet: View {
    @Environment(ExportQueue.self) private var exports
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hasBundle) private var hasBundle
    let request: ExportQueue.Request

    /// Every option field (format to watermark) and the picked preset.
    @State private var form: ExportForm
    @State private var folder: URL?
    @State private var destination: Destination
    @State private var albumText: String
    @State private var photosStatus: PhotosAuthorization?
    @State private var presets: ExportPresetLibrary
    /// The Save Current as Preset… name prompt.
    @State private var naming = false
    @State private var newPresetName = ""
    /// A name the save would replace, while the sheet asks.
    @State private var replacing: String?
    /// The preset Delete Preset would remove, while the sheet asks.
    @State private var deleting: String?

    private typealias SizeMode = ExportForm.SizeMode
    private enum Destination: Hashable { case folder, photos }

    init(request: ExportQueue.Request, options: ExportOptions, folder: URL?,
         album: String? = ExportTarget.defaultAlbum, toPhotos: Bool = false,
         presetStore: ExportPresetStore = ExportPresetStore()) {
        self.request = request
        _form = State(initialValue: ExportForm(options: options))
        _folder = State(initialValue: folder)
        _destination = State(initialValue: toPhotos ? .photos : .folder)
        _albumText = State(initialValue: album ?? "")
        _presets = State(initialValue: ExportPresetLibrary(store: presetStore))
    }

    /// Without an app bundle the Photos library cannot be chosen: the folder
    /// is the destination whatever was asked for.
    private var shownDestination: Destination { hasBundle ? destination : .folder }

    private var count: Int { request.items.count }
    private var noun: String { count == 1 ? "Photo" : "Photos" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(count) \(noun)").font(.title3.weight(.semibold))
            presetRow
            Form {
                Section("Format") {
                    Picker("Format", selection: $form.options.format) {
                        ForEach(ExportOptions.Format.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if form.options.format.isLossy {
                        HStack {
                            Slider(value: $form.options.quality, in: ExportOptions.qualityRange, step: 0.05) { Text("Quality") }

                            Text("\(Int((form.options.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    } else {
                        Text("TIFF is lossless (LZW compressed).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Size") {
                    Picker("Size", selection: $form.sizeMode) {
                        Text("As edited").tag(SizeMode.original)
                        Text("Long side").tag(SizeMode.longSide)
                        Text("Percent").tag(SizeMode.percent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch form.sizeMode {
                    case .original:
                        Text("The full size after the crop; never upscaled.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .longSide:
                        HStack {
                            TextField("Pixels", value: $form.longSide, format: .number)
                                .frame(width: 80)
                            Text("px on the long side (smaller photos stay as they are)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .percent:
                        HStack {
                            TextField("Percent", value: $form.percent, format: .number)
                                .frame(width: 60)
                            Text("% of the edited size (100 keeps it)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("File") {
                    Picker("Name", selection: $form.nameMode) {
                        Text("Original name + suffix").tag(ExportForm.NameMode.suffix)
                        Text("Template").tag(ExportForm.NameMode.template)
                    }
                    switch form.nameMode {
                    case .suffix:
                        TextField("Suffix", text: $form.options.suffix, prompt: Text("e.g. -edit"))
                            .textFieldStyle(.roundedBorder)
                    case .template:
                        TextField("Template", text: $form.template.pattern, prompt: Text("e.g. {date}-{seq}"))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Start at", value: $form.template.start, format: .number)
                                .frame(width: 140)
                            Text("{name} original name · {date} capture date · {seq} number")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    LabeledContent("Preview") {
                        Text(namePreview)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if shownDestination == .folder {
                        Picker("If the file exists", selection: $form.options.collision) {
                            ForEach(ExportOptions.Collision.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Toggle("Keep camera info (EXIF, GPS, IPTC) from the original", isOn: $form.options.keepMetadata)
                }
                Section("Watermark") {
                    Toggle("Add a text watermark", isOn: $form.watermarkOn)
                    if form.watermarkOn {
                        TextField("Text", text: $form.watermark.text, prompt: Text("e.g. © Your Name"))
                            .textFieldStyle(.roundedBorder)
                        Picker("Position", selection: $form.watermark.position) {
                            ForEach(Watermark.Position.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        HStack {
                            Slider(value: $form.watermark.size, in: Watermark.sizeRange, step: 0.005) { Text("Size") }
                            Text(String(format: "%.1f%%", form.watermark.size * 100))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        HStack {
                            Slider(value: $form.watermark.opacity, in: Watermark.opacityRange, step: 0.05) { Text("Opacity") }
                            Text("\(Int((form.watermark.opacity * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        Text(form.watermark.isBlank
                             ? "Blank text adds no watermark."
                             : "White with a soft shadow; size is the text height as a share of the photo's short side.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Export to") {
                    Picker("Export to", selection: Binding(get: { shownDestination }, set: { destination = $0 })) {
                        Text("Folder").tag(Destination.folder)
                        Text("Photos library").tag(Destination.photos)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!hasBundle)
                    switch shownDestination {
                    case .folder:
                        HStack {
                            Text(folder?.path(percentEncoded: false) ?? "No folder chosen")
                                .foregroundStyle(folder == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") {
                                if let picked = ExportPanel.chooseFolder(count: count, format: form.options.format, from: folder) {
                                    folder = picked
                                }
                            }
                        }
                        if !hasBundle {
                            Text("Exporting to Photos needs the app bundle (scripts/bundle.sh).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .photos:
                        HStack {
                            Text("Album")
                            TextField("Album", text: $albumText, prompt: Text("none: the library only"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            Text(albumText.isEmpty ? "(the library only)" : "(created if missing)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Each export is a new photo in Photos. A photo opened from Photos comes back as a new photo beside its original, which is not changed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        photosAccessRow
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 420)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export \(count) \(noun)") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { photosStatus = exports.photos.authorizationStatus() }
    }

    private var canExport: Bool {
        switch shownDestination {
        case .folder: return folder != nil
        case .photos: return photosStatus?.canRead == true
        }
    }

    /// Nothing once access is allowed; otherwise what to do about it.
    @ViewBuilder private var photosAccessRow: some View {
        switch photosStatus {
        case .notDetermined?:
            HStack {
                Text("PhotoLab needs your permission to add photos.")
                    .font(.caption)
                Spacer()
                Button("Allow Access to Photos…") {
                    Task { photosStatus = await exports.photos.requestAuthorization() }
                }
            }
        case .denied?, .restricted?:
            HStack {
                Text("Photos access is not allowed.")
                    .font(.caption).foregroundStyle(.red)
                Spacer()
                if photosStatus == .denied {
                    Button("Open System Settings…") { NSWorkspace.shared.open(PhotosBrowser.settingsURL) }
                    Button("Check Again") { photosStatus = exports.photos.authorizationStatus() }
                }
            }
        case .authorized?, .limited?, nil:
            EmptyView()
        }
    }

    /// The first two names the run would write, before any collision
    /// handling (`ExportForm.previewNames`).
    private var namePreview: String {
        form.previewNames(for: request.items).joined(separator: ", ")
    }

    /// The options a run would use (`ExportForm.resolved`).
    private var resolved: ExportOptions { form.resolved }

    // MARK: Presets

    /// "Preset" and its menu: every readable preset (a check on the picked
    /// one), the unreadable files listed and disabled, then Save Current as
    /// Preset… and Delete Preset.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preset")
                Menu(form.presetLabel) {
                    if presets.presets.isEmpty {
                        Text("No presets yet")
                    }
                    ForEach(presets.presets) { preset in
                        Button {
                            pick(preset)
                        } label: {
                            if form.picked?.name == preset.name {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    ForEach(presets.unreadable, id: \.self) { file in
                        Text("\(file.lastPathComponent) (unreadable)")
                    }
                    Divider()
                    Button("Save Current as Preset…") {
                        newPresetName = form.picked?.name ?? ""
                        naming = true
                    }
                    Button("Delete Preset") { deleting = form.picked?.name }
                        .disabled(form.picked.map { presets.preset(named: $0.name) == nil } ?? true)
                }
                .fixedSize()
                Spacer()
            }
            if let error = presets.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Save Current as Preset", isPresented: $naming) {
            TextField("Name", text: $newPresetName)
            Button("Save") { requestSave(newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every option above, the watermark included. The destination is not saved.")
        }
        .confirmationDialog("Replace the export preset “\(replacing ?? "")”?",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace", role: .destructive) {
                if let name = replacing { save(name) }
                replacing = nil
            }
            Button("Cancel", role: .cancel) { replacing = nil }
        }
        .confirmationDialog("Delete the export preset “\(deleting ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = deleting { delete(name) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .onAppear { restorePick() }
    }

    /// The remembered pick (`AppSettings.exportPreset`) shown over the last
    /// run's options, "(edited)" when they differ; the fields are not changed.
    private func restorePick() {
        guard form.picked == nil, let name = exports.settings.exportPreset,
              let preset = presets.preset(named: name) else { return }
        form.picked = preset
    }

    private func pick(_ preset: ExportPreset) {
        form.pick(preset)
        exports.settings.exportPreset = preset.name
    }

    /// Saves at once, or asks first when a file of that name exists.
    private func requestSave(_ name: String) {
        if presets.exists(name) {
            replacing = name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            save(name)
        }
    }

    private func save(_ name: String) {
        guard let saved = presets.save(resolved, as: name) else { return }
        form.picked = saved
        exports.settings.exportPreset = saved.name
    }

    /// Removes the preset's one file; the fields stay as they are.
    private func delete(_ name: String) {
        guard presets.delete(name) else { return }
        if form.picked?.name == name { form.picked = nil }
        if exports.settings.exportPreset == name { exports.settings.exportPreset = nil }
    }

    private var target: ExportTarget? {
        switch shownDestination {
        case .folder: return folder.map { .folder($0) }
        case .photos: return .photosLibrary(album: ExportTarget.album(from: albumText))
        }
    }

    private func run() {
        guard canExport, let target else { return }
        let o = resolved
        exports.keep(target: target, options: o)
        exports.start(request.items, to: target, options: o)
        dismiss()
    }
}
