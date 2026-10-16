import SwiftUI
import AppKit

/// Export…: the options for one run (format, quality, size, name, collision,
/// metadata, watermark) and the target (a folder, or the Photos library with an
/// album), offered as last time, then the run starts through
/// `ExportQueue.start(_:to:options:)`. For Photos the collision policy is
/// hidden (every export is a new asset) and the access status is shown,
/// with the Allow button as the only prompt.
struct ExportSheet: View {
    @Environment(ExportQueue.self) private var exports
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hasBundle) private var hasBundle
    let request: ExportQueue.Request

    @State private var options: ExportOptions
    @State private var folder: URL?
    @State private var sizeMode: SizeMode
    @State private var longSide: Int
    @State private var percent: Int
    @State private var destination: Destination
    @State private var albumText: String
    @State private var photosStatus: PhotosAuthorization?
    /// The Watermark section's toggle; its fields stay in `watermark` while
    /// it is off, and `resolved` drops them.
    @State private var watermarkOn: Bool
    @State private var watermark: Watermark

    private enum SizeMode: Hashable { case original, longSide, percent }
    private enum Destination: Hashable { case folder, photos }

    init(request: ExportQueue.Request, options: ExportOptions, folder: URL?,
         album: String? = ExportTarget.defaultAlbum, toPhotos: Bool = false) {
        self.request = request
        _options = State(initialValue: options)
        _folder = State(initialValue: folder)
        _destination = State(initialValue: toPhotos ? .photos : .folder)
        _albumText = State(initialValue: album ?? "")
        _watermarkOn = State(initialValue: options.watermark != nil)
        _watermark = State(initialValue: options.watermark ?? Watermark())
        switch options.resize {
        case .longSide(let n):
            _sizeMode = State(initialValue: .longSide); _longSide = State(initialValue: n); _percent = State(initialValue: 50)
        case .percent(let p):
            _sizeMode = State(initialValue: .percent); _longSide = State(initialValue: 2048); _percent = State(initialValue: p)
        case nil:
            _sizeMode = State(initialValue: .original); _longSide = State(initialValue: 2048); _percent = State(initialValue: 50)
        }
    }

    /// Without an app bundle the Photos library cannot be chosen: the folder
    /// is the destination whatever was asked for.
    private var shownDestination: Destination { hasBundle ? destination : .folder }

    private var count: Int { request.items.count }
    private var noun: String { count == 1 ? "Photo" : "Photos" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(count) \(noun)").font(.title3.weight(.semibold))
            Form {
                Section("Format") {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportOptions.Format.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if options.format.isLossy {
                        HStack {
                            Slider(value: $options.quality, in: ExportOptions.qualityRange, step: 0.05) { Text("Quality") }

                            Text("\(Int((options.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    } else {
                        Text("TIFF is lossless (LZW compressed).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Size") {
                    Picker("Size", selection: $sizeMode) {
                        Text("As edited").tag(SizeMode.original)
                        Text("Long side").tag(SizeMode.longSide)
                        Text("Percent").tag(SizeMode.percent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch sizeMode {
                    case .original:
                        Text("The full size after the crop; never upscaled.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .longSide:
                        HStack {
                            TextField("Pixels", value: $longSide, format: .number)
                                .frame(width: 80)
                            Text("px on the long side (smaller photos stay as they are)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .percent:
                        HStack {
                            TextField("Percent", value: $percent, format: .number)
                                .frame(width: 60)
                            Text("% of the edited size (100 keeps it)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("File") {
                    HStack {
                        Text("Name")
                        TextField("Suffix", text: $options.suffix, prompt: Text("e.g. -edit"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text(namePreview)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if shownDestination == .folder {
                        Picker("If the file exists", selection: $options.collision) {
                            ForEach(ExportOptions.Collision.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Toggle("Keep camera info (EXIF, GPS, IPTC) from the original", isOn: $options.keepMetadata)
                }
                Section("Watermark") {
                    Toggle("Add a text watermark", isOn: $watermarkOn)
                    if watermarkOn {
                        TextField("Text", text: $watermark.text, prompt: Text("e.g. © Your Name"))
                            .textFieldStyle(.roundedBorder)
                        Picker("Position", selection: $watermark.position) {
                            ForEach(Watermark.Position.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        HStack {
                            Slider(value: $watermark.size, in: Watermark.sizeRange, step: 0.005) { Text("Size") }
                            Text(String(format: "%.1f%%", watermark.size * 100))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        HStack {
                            Slider(value: $watermark.opacity, in: Watermark.opacityRange, step: 0.05) { Text("Opacity") }
                            Text("\(Int((watermark.opacity * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        Text(watermark.isBlank
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
                                if let picked = ExportPanel.chooseFolder(count: count, format: options.format, from: folder) {
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

    private var namePreview: String {
        guard let first = request.items.first else { return "" }
        return resolved.fileName(for: first.source, name: first.name)
    }

    /// `options` with the size controls folded into `resize` and the
    /// Watermark section into `watermark` (nil when off or blank).
    private var resolved: ExportOptions {
        var o = options
        o.watermark = watermarkOn && !watermark.isBlank ? watermark : nil
        switch sizeMode {
        case .original: o.resize = nil
        case .longSide: o.resize = .longSide(max(1, longSide))
        case .percent: o.resize = .percent(min(100, max(1, percent)))
        }
        return o
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
