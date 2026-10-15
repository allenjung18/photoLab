import SwiftUI
import CoreImage

/// Live thumbnails for the preset strip: the current photo, decoded once at
/// a small size, rendered through the one `Renderer` with each preset
/// applied over the photo's own geometry. Requests coalesce (latest wins),
/// like `PreviewModel`.
@MainActor
@Observable
final class PresetThumbnails {
    nonisolated static let masterPixelSize = 480
    nonisolated static let cellPixelSize = 160

    struct Thumbnail: Identifiable {
        let name: String
        let image: CGImage
        let milliseconds: Double
        var id: String { name }
    }

    /// The latest strip and the photo it belongs to.
    private(set) var thumbnails: [String: Thumbnail] = [:]
    private(set) var url: URL?
    /// The photo whose master could not be decoded on the last request for
    /// it; the strip labels its cells instead of spinning. Cleared by the
    /// next decode that succeeds.
    private(set) var failed: URL?


    private var master: CIImage?
    private var masterURL: URL?
    private var pending: Job?
    private var rendering = false

    private struct Job {
        let url: URL
        let presets: [Preset]
        let base: Recipe
        let pixelSize: Int
    }

    func request(url: URL, presets: [Preset], base: Recipe, pixelSize: Int = PresetThumbnails.cellPixelSize) {
        pending = Job(url: url, presets: presets, base: base, pixelSize: pixelSize)
        pump()
    }

    private func pump() {
        guard !rendering, let job = pending else { return }
        pending = nil
        rendering = true
        let cached = masterURL == job.url ? master : nil
        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { () -> (CIImage?, [Thumbnail]) in
                guard let master = cached ?? Renderer.previewMaster(job.url, maxPixelSize: Self.masterPixelSize) else {
                    return (nil, [])
                }
                return (master, Self.render(master: master, presets: job.presets, base: job.base, pixelSize: job.pixelSize))
            }.value
            guard let self else { return }
            self.rendering = false
            if let master = out.0 {
                self.failed = nil
                self.master = master
                self.masterURL = job.url
                self.url = job.url
                self.thumbnails = Dictionary(uniqueKeysWithValues: out.1.map { ($0.name, $0) })
            } else {
                self.failed = job.url
            }
            self.pump()
        }
    }

    /// True while a request is decoding or rendering (tests).
    var isBusy: Bool { rendering || pending != nil }


    /// One thumbnail per preset, each `preset.apply(to: base)` rendered over
    /// `master` at `pixelSize`; the ms is the renderer's own whole-step time.
    nonisolated static func render(master: CIImage, presets: [Preset], base: Recipe, pixelSize: Int,
                                   renderer: Renderer = .shared) -> [Thumbnail] {
        presets.compactMap { preset in
            guard let r = renderer.render(master, recipe: preset.apply(to: base), maxPixelSize: pixelSize) else { return nil }
            return Thumbnail(name: preset.name, image: r.image, milliseconds: r.milliseconds)
        }
    }
}

/// The preset browser in the loupe's panel: a strip of live thumbnails
/// (click applies, right-click for rename / update / delete), a Save button
/// and the sheets behind it.
struct PresetStrip: View {
    @Environment(Library.self) private var library
    @Environment(PresetLibrary.self) private var presetLibrary
    let photo: Photo
    /// The photo's original file; nil until the source has it.
    let file: URL?
    @State private var thumbnails = PresetThumbnails()
    @State private var newName = ""
    @State private var renaming: Preset?
    @State private var renameTo = ""
    @State private var deleting: Preset?

    private var current: Recipe { library.recipe(for: photo.id) }
    /// What the thumbnails depend on besides the photo and the presets: only
    /// the geometry survives an apply, so only it re-renders the strip.
    private var geometryKey: [Adjustment] { AdjustmentKind.geometryKinds.map { current[$0] } }

    var body: some View {
        @Bindable var presetLibrary = presetLibrary
        VStack(alignment: .leading, spacing: 6) {
            if presetLibrary.presets.isEmpty {
                Text("No presets yet. Save the current look with Save….")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(presetLibrary.presets) { preset in cell(preset) }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("Save…") { presetLibrary.saveRequested = true }
                    .help("Save the current look as a preset (⇧⌘P)")
                Spacer()
                Menu {
                    Button("Restore Starter Presets") { presetLibrary.restoreStarters() }
                    Button("Show Presets Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([presetLibrary.store.directory])
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More")
            }
            .controlSize(.small)
            if let error = presetLibrary.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
            }
        }
        .onChange(of: file, initial: true) { request() }
        .onChange(of: presetLibrary.presets) { request() }
        .onChange(of: geometryKey) { request() }
        .alert("Save Preset", isPresented: $presetLibrary.saveRequested) {
            TextField("Name", text: $newName)
            Button("Save") { presetLibrary.save(current, as: newName); newName = "" }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Saves every slider except rotate and crop. A preset of the same name is replaced.")
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Rename") {
                if let renaming { presetLibrary.rename(renaming.name, to: renameTo) }
                renaming = nil
            }
            .disabled(renameTo.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { preset in
            Button("Delete", role: .destructive) { presetLibrary.delete(preset.name) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Photos the preset was applied to keep their edit.")
        }
    }

    private func cell(_ preset: Preset) -> some View {
        let active = preset.matches(current)
        return VStack(spacing: 3) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let file, thumbnails.url == file, let t = thumbnails.thumbnails[preset.name] {
                    Image(decorative: t.image, scale: 2).resizable().scaledToFit()
                } else if let file, thumbnails.failed == file {
                    Text("Could not open")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(4)
                } else {
                    ProgressView().controlSize(.mini)
                }

            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(active ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: active ? 2 : 1))
            Text(preset.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 72)
                .foregroundStyle(active ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { library.apply(preset, to: photo.id) }
        .help(helpText(preset))
        .contextMenu {
            Button("Apply") { library.apply(preset, to: photo.id) }
            Button("Update with Current Settings") { presetLibrary.save(current, as: preset.name) }
            Button("Rename…") { renameTo = preset.name; renaming = preset }
            Divider()
            Button("Delete…", role: .destructive) { deleting = preset }
        }
    }

    private func helpText(_ preset: Preset) -> String {
        if let t = thumbnails.thumbnails[preset.name], let file, thumbnails.url == file {
            return String(format: "%@ · thumbnail %.1f ms", preset.name, t.milliseconds)
        }
        return preset.name
    }

    private func request() {
        guard let file else { return }
        thumbnails.request(url: file, presets: presetLibrary.presets, base: current)
    }
}
