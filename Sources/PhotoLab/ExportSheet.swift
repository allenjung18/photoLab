import SwiftUI
import AppKit

/// Export…: the options for one run (format, quality, size, name, collision,
/// metadata) and the output folder, offered as last time, then the run
/// starts through `ExportQueue.start`.
struct ExportSheet: View {
    @Environment(ExportQueue.self) private var exports
    @Environment(\.dismiss) private var dismiss
    let request: ExportQueue.Request

    @State private var options: ExportOptions
    @State private var folder: URL?
    @State private var sizeMode: SizeMode
    @State private var longSide: Int
    @State private var percent: Int

    private enum SizeMode: Hashable { case original, longSide, percent }

    init(request: ExportQueue.Request, options: ExportOptions, folder: URL?) {
        self.request = request
        _options = State(initialValue: options)
        _folder = State(initialValue: folder)
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
                    Picker("If the file exists", selection: $options.collision) {
                        ForEach(ExportOptions.Collision.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Keep camera info (EXIF, GPS, IPTC) from the original", isOn: $options.keepMetadata)
                }
                Section("Folder") {
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
                    .disabled(folder == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
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

    private func run() {
        guard let folder else { return }
        let o = resolved
        exports.keep(folder: folder, options: o)
        exports.start(request.items, into: folder, options: o)
        dismiss()
    }
}
