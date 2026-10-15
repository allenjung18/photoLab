import SwiftUI
import AppKit

/// Export…: the options for one run (format, quality, size, name, collision,
/// metadata) and the target (a folder, or the Photos library with an
/// album), offered as last time, then the run starts through
/// `ExportQueue.start(_:to:options:)`. For Photos the collision policy is
/// hidden (every export is a new asset) and the access status is shown,
/// with the Allow button as the only prompt.
struct ExportSheet: View {
    @Environment(ExportQueue.self) private var exports
    @Environment(\.dismiss) private var dismiss
    let request: ExportQueue.Request

    @State private var options: ExportOptions
    @State private var folder: URL?
    @State private var sizeMode: SizeMode
    @State private var longSide: Int
    @State private var percent: Int
    @State private var destination: Destination
    @State private var albumText: String
    @State private var photosStatus: PhotosAuthorization?

    private enum SizeMode: Hashable { case original, longSide, percent }
    private enum Destination: Hashable { case folder, photos }

    init(request: ExportQueue.Request, options: ExportOptions, folder: URL?,
         album: String? = ExportTarget.defaultAlbum, toPhotos: Bool = false) {
        self.request = request
        _options = State(initialValue: options)
        _folder = State(initialValue: folder)
        _destination = State(initialValue: toPhotos && PhotosAccess.hasBundle ? .photos : .folder)
        _albumText = State(initialValue: album ?? "")
        switch options.resize {
        case .longSide(let n):
            _sizeMode = State(initialValue: .longSide); _longSide = State(initialValue: n); _percent = State(initialValue: 50)
        case .percent(let p):
            _sizeMode = State(initialValue: .percent); _longSide = State(initialValue: 2048); _percent = State(initialValue: p)
        case nil:
            _sizeMode = State(initialValue: .original); _longSide = State(initialValue: 2048); _percent = State(initialValue: 50)
        }
    }

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
                        TextField("suffix, e.g. -edit", text: $options.suffix)
                            .frame(width: 140)
                        Text(namePreview)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if destination == .folder {
                        Picker("If the file exists", selection: $options.collision) {
                            ForEach(ExportOptions.Collision.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Toggle("Keep camera info (EXIF, GPS, IPTC) from the original", isOn: $options.keepMetadata)
                }
                Section("Export to") {
                    Picker("Export to", selection: $destination) {
                        Text("Folder").tag(Destination.folder)
                        Text("Photos library").tag(Destination.photos)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!PhotosAccess.hasBundle)
                    switch destination {
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
                        if !PhotosAccess.hasBundle {
                            Text("Exporting to Photos needs the app bundle (scripts/bundle.sh).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .photos:
                        HStack {
                            Text("Album")
                            TextField("none", text: $albumText)
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
        switch destination {
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
                Button("Allow Access…") {
                    Task { photosStatus = await exports.photos.requestAuthorization() }
                }
            }
        case .denied?, .restricted?:
            HStack {
                Text("Photos access is not allowed.")
                    .font(.caption).foregroundStyle(.red)
                Spacer()
                if photosStatus == .denied {
                    Button("Open System Settings") { NSWorkspace.shared.open(PhotosBrowser.settingsURL) }
                    Button("Check Again") { photosStatus = exports.photos.authorizationStatus() }
                }
            }
        case .authorized?, .limited?, nil:
            EmptyView()
        }
    }

    private var namePreview: String {
        guard let first = request.items.first else { return "" }
        return resolved.fileName(for: first.source)
    }

    /// `options` with the size controls folded into `resize`.
    private var resolved: ExportOptions {
        var o = options
        switch sizeMode {
        case .original: o.resize = nil
        case .longSide: o.resize = .longSide(max(1, longSide))
        case .percent: o.resize = .percent(min(100, max(1, percent)))
        }
        return o
    }

    private var target: ExportTarget? {
        switch destination {
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
