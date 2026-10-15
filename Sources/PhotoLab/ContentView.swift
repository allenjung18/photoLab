import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(ExportQueue.self) private var exports

    var body: some View {
        @Bindable var library = library
        Group {
            if library.folder == nil {
                WelcomeView()
            } else if library.loupe, let photo = library.selectedPhoto {
                LoupeView(photo: photo)
            } else {
                GridView()
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { library.chooseFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open a folder of photos (⌘O)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: viewBinding) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(false)
                    Label("Loupe", systemImage: "photo").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(library.photos.isEmpty)
                .help("Grid (G) or single photo (E)")
            }
        }
        .background(HiddenShortcuts())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if exports.state != .idle { ExportBar() }
        }
        .sheet(item: $library.syncRequest) { request in
            SyncSheet(request: request)
        }
    }

    private var viewBinding: Binding<Bool> {
        Binding(
            get: { library.loupe },
            set: { on in
                if on, library.selection == nil { library.selection = library.photos.first?.id }
                library.loupe = on && library.selection != nil
            })
    }

    private var title: String { library.folder?.lastPathComponent ?? "PhotoLab" }

    private var subtitle: String {
        guard library.folder != nil else { return "" }
        if library.loupe, let i = library.selectedIndex {
            return "\(i + 1) of \(library.photos.count)"
        }
        let n = library.selectedIDs.count
        return n > 1 ? "\(library.photos.count) photos · \(n) selected" : "\(library.photos.count) photos"
    }
}

/// Keyboard shortcuts that work whatever has focus: Lightroom's G / E, arrows
/// to move the selection, Escape back to the grid, Return into the loupe,
/// backslash to toggle before/after.
private struct HiddenShortcuts: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            Button("") { library.loupe = false }.keyboardShortcut("g", modifiers: [])
            Button("") { enterLoupe() }.keyboardShortcut("e", modifiers: [])
            Button("") { enterLoupe() }.keyboardShortcut(.return, modifiers: [])
            Button("") {
                if library.loupe { library.loupe = false } else { library.collapseSelection() }
            }.keyboardShortcut(.escape, modifiers: [])
            Button("") { library.select(offset: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { library.select(offset: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { library.showBefore.toggle() }.keyboardShortcut("\\", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func enterLoupe() {
        if library.selection == nil { library.selection = library.photos.first?.id }
        library.loupe = library.selection != nil
    }
}

struct WelcomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Open a folder of photos to begin")
                .font(.title2)
            Button("Open Folder…") { library.chooseFolder() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GridView: View {
    @Environment(Library.self) private var library
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 10)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if library.photos.isEmpty {
                    Text("No photos in this folder")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(library.photos) { photo in
                            ThumbnailCell(photo: photo, selected: library.selectedIDs.contains(photo.id),
                                          anchor: photo.id == library.selection,
                                          edited: library.isEdited(photo.id))
                                .id(photo.id)
                                .onTapGesture(count: 2) {
                                    library.selection = photo.id
                                    library.loupe = true
                                }
                                .onTapGesture {
                                    // ⌘ toggles, ⇧ extends from the anchor (Finder's rules).
                                    let flags = NSEvent.modifierFlags
                                    library.click(photo.id, extending: flags.contains(.shift),
                                                  toggling: flags.contains(.command))
                                }
                        }
                    }
                    .padding(12)
                }
            }
            .onChange(of: library.selection) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if library.selectedIDs.count > 1 { BatchBar() }
        }
    }
}

/// The bar under the grid while more than one photo is selected: sync the
/// anchor's settings onto the rest, apply a preset to all, export all.
private struct BatchBar: View {
    @Environment(Library.self) private var library
    @Environment(PresetLibrary.self) private var presets
    @Environment(ExportQueue.self) private var exports

    var body: some View {
        HStack(spacing: 10) {
            Text("\(library.selectedIDs.count) selected")
                .font(.callout.weight(.semibold))
            if let anchor = library.selectedPhoto {
                Text("· anchor \(anchor.name)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Sync Settings…") { library.requestSync() }
                .help("Copy the anchor's settings onto the other selected photos, with checkboxes for what to sync")
            Menu("Apply Preset") {
                ForEach(presets.presets) { preset in
                    Button(preset.name) { library.apply(preset, to: library.batchTargets) }
                }
            }
            .fixedSize()
            .disabled(presets.presets.isEmpty)
            .help("Apply a preset to every selected photo (one undo step)")
            Button("Export…") { exportSelection() }
                .disabled(exports.isRunning)
                .help("Render every selected photo to a full-size JPEG in a folder (⇧⌘E)")
            Button("Deselect") { library.collapseSelection() }
                .help("Back to the anchor alone (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func exportSelection() {
        let ids = library.batchTargets
        guard !ids.isEmpty, let folder = ExportPanel.chooseFolder(count: ids.count) else { return }
        exports.start(library.exportItems(for: ids), into: folder)
    }
}

/// Sync Settings / Paste Settings: the source recipe goes onto the targets
/// for the checked adjustments only; each photo keeps its own value for the
/// rest. The whole sync is one undo step.
struct SyncSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let request: SyncRequest
    @State private var mask: SyncMask
    @State private var expanded: Set<AdjustmentKind.Section> = []

    init(request: SyncRequest) {
        self.request = request
        _mask = State(initialValue: request.mask)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Settings").font(.title3.weight(.semibold))
            Text("From \(request.sourceName) onto \(request.targets.count) photo\(request.targets.count == 1 ? "" : "s"). Checked adjustments are copied; the rest keep each photo's own value.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Check:").foregroundStyle(.secondary)
                Button("All") { mask = .everything }
                Button("None") { mask = .nothing }
                Button("Look") { mask = .look }
                    .help("Everything but rotate and crop")
                Button("Grade") { mask = .grade }
                    .help("The look without exposure: each photo keeps its own brightness and framing")
            }
            .controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AdjustmentKind.Section.allCases, id: \.self) { section in
                        sectionRows(section)
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(minHeight: 260, maxHeight: 360)
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sync \(request.targets.count) Photo\(request.targets.count == 1 ? "" : "s")") {
                    library.lastSyncMask = mask
                    library.sync(request.source, mask: mask, to: request.targets)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mask.kinds.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// One section: a checkbox for the whole section, then (opened) one per
    /// adjustment; HSL shows its three channels rather than 24 bands.
    @ViewBuilder
    private func sectionRows(_ section: AdjustmentKind.Section) -> some View {
        let kinds = section.kinds
        DisclosureGroup(isExpanded: isExpanded(section)) {
            VStack(alignment: .leading, spacing: 2) {
                if section == .hsl {
                    ForEach(AdjustmentKind.HSLChannel.allCases, id: \.self) { channel in
                        let members = AdjustmentKind.HSLBand.allCases.map { AdjustmentKind.hsl(channel, $0) }
                        checkbox(channel.title, members)
                    }
                } else {
                    ForEach(kinds) { kind in checkbox(kind.label, [kind]) }
                }
            }
            .padding(.leading, 20)
            .padding(.bottom, 4)
        } label: {
            checkbox(section.title, kinds)
                .font(.callout.weight(.semibold))
        }
    }

    /// A checkbox over a list of kinds: on when all are in the mask; a mixed
    /// list shows as on with a dash.
    private func checkbox(_ title: String, _ kinds: [AdjustmentKind]) -> some View {
        let state = mask.state(of: kinds)
        return Toggle(isOn: Binding(get: { state != false }, set: { mask.set(kinds, $0) })) {
            HStack(spacing: 4) {
                Text(title)
                if state == nil {
                    Text("(some)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func isExpanded(_ section: AdjustmentKind.Section) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(section) },
            set: { on in if on { expanded.insert(section) } else { expanded.remove(section) } })
    }

    private var summary: String {
        let n = mask.kinds.count
        if mask == .look { return "Look: everything but rotate and crop" }
        if mask == .grade { return "Grade: the look without exposure" }
        if mask == .everything { return "Everything, framing included" }
        return "\(n) of \(AdjustmentKind.allCases.count) adjustments"
    }
}

/// The export progress at the bottom of the window: count done of total,
/// the file in flight, Cancel; then the result with Show in Finder.
private struct ExportBar: View {
    @Environment(ExportQueue.self) private var exports

    var body: some View {
        HStack(spacing: 12) {
            switch exports.state {
            case .running:
                ProgressView(value: Double(exports.completed), total: Double(max(1, exports.total)))
                    .frame(width: 160)
                Text("Exporting \(exports.completed + 1) of \(exports.total)")
                    .font(.callout.monospacedDigit())
                if let current = exports.current {
                    Text(current.lastPathComponent)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") { exports.cancel() }
                    .help("Stop after the file being written; what is written stays")
            case .finished, .cancelled:
                Image(systemName: exports.failures.isEmpty && exports.state == .finished
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(exports.failures.isEmpty && exports.state == .finished ? .green : .orange)
                Text(result)
                    .font(.callout)
                    .lineLimit(2)
                if let first = exports.failures.first {
                    Text(first.message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                if let folder = exports.folder {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(exports.exported.isEmpty ? [folder] : exports.exported)
                    }
                }
                Button("Done") { exports.dismiss() }
            case .idle:
                EmptyView()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var result: String {
        let folder = exports.folder?.lastPathComponent ?? ""
        var s = exports.state == .cancelled
            ? "Cancelled: \(exports.done) of \(exports.total) exported to \(folder)"
            : "Exported \(exports.done) of \(exports.total) to \(folder)"
        if !exports.failures.isEmpty { s += " · \(exports.failures.count) failed" }
        return s
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let selected: Bool
    /// The selection's anchor (the loupe photo), drawn heavier than the rest.
    var anchor = false
    /// Shows a small badge when the photo has a saved edit.
    var edited = false
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor.opacity(anchor ? 1 : 0.6) : .clear, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                if edited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(6)
                        .help("Edited")
                }
            }
            Text(photo.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: photo.url) {
            image = Thumbnails.shared.cached(photo.url)
            if image == nil { image = await Thumbnails.shared.thumbnail(for: photo.url) }
        }
    }
}

struct LoupeView: View {
    let photo: Photo
    @State private var preview = PreviewModel()

    var body: some View {
        HStack(spacing: 0) {
            PreviewCanvas(photo: photo, preview: preview)
            Divider()
            AdjustmentsPanel(photo: photo, preview: preview)
                .frame(width: 280)
        }
    }
}

/// The rendered frame, sized to the view. Every recipe or size change asks
/// the preview model for a new frame at the view's pixel size.
private struct PreviewCanvas: View {
    @Environment(Library.self) private var library
    @Environment(\.displayScale) private var displayScale
    let photo: Photo
    let preview: PreviewModel
    @State private var pixelSize = 0

    private var recipe: Recipe { library.showBefore ? .neutral : library.recipe(for: photo.id) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let cg = preview.image, preview.imageURL == photo.url {
                    Image(decorative: cg, scale: displayScale)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if let thumb = Thumbnails.shared.cached(photo.url) {
                    Image(nsImage: thumb).resizable().scaledToFit().padding(8)
                        .overlay(ProgressView().controlSize(.regular))
                } else {
                    ProgressView()
                }
                if library.showBefore {
                    Text("Before")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
            .onAppear { pixelSize = longestSide(geo.size) }
            .onChange(of: geo.size) { _, size in pixelSize = longestSide(size) }
        }
        .onTapGesture(count: 2) { library.loupe = false }
        .onChange(of: photo.url, initial: true) { _, url in
            preview.load(url)
            request()
        }
        .onChange(of: recipe) { request() }
        .onChange(of: pixelSize) { request() }
    }

    private func longestSide(_ size: CGSize) -> Int {
        Int((max(size.width, size.height) - 16) * displayScale)
    }

    private func request() {
        preview.request(url: photo.url, recipe: recipe, maxPixelSize: pixelSize)
    }
}

/// The preset strip, then the adjustment sliders in sections (Basic, Color,
/// Tone Curve, HSL, Detail, Effects, Crop & Rotate), each with an enable checkbox, plus a
/// hold-to-compare button, undo / redo / reset, and the live render time
/// of the last frame. The HSL section shows one channel (hue, saturation or
/// luminance) of the eight bands at a time, like Lightroom's panel.
struct AdjustmentsPanel: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let preview: PreviewModel
    @State private var expanded: Set<AdjustmentKind.Section> = [.basic]
    @State private var presetsExpanded = true
    @State private var hslChannel: AdjustmentKind.HSLChannel = .hue

    private var recipe: Binding<Recipe> {
        Binding(
            get: { library.recipe(for: photo.id) },
            set: { library.setRecipe($0, for: photo.id) })
    }

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    DisclosureGroup(isExpanded: $presetsExpanded) {
                        PresetStrip(photo: photo)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    } label: {
                        Text("Presets").font(.callout.weight(.semibold))
                    }
                    ForEach(AdjustmentKind.Section.allCases, id: \.self) { section in
                        DisclosureGroup(isExpanded: isExpanded(section)) {
                            VStack(alignment: .leading, spacing: 14) {
                                if section == .hsl {
                                    Picker("Channel", selection: $hslChannel) {
                                        ForEach(AdjustmentKind.HSLChannel.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    ForEach(AdjustmentKind.HSLBand.allCases, id: \.self) { band in
                                        row(.hsl(hslChannel, band))
                                    }
                                } else {
                                    ForEach(section.kinds) { kind in row(kind) }
                                }
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        } label: {
                            HStack {
                                Text(section.title).font(.callout.weight(.semibold))
                                if sectionEdited(section) {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                        .help("Has edits")
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 6) {
                BeforeButton(isPressed: $library.showBefore)
                    .fixedSize()
                Spacer(minLength: 4)
                Button { library.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!library.canUndo)
                    .help("Undo (⌘Z)")
                Button { library.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!library.canRedo)
                    .help("Redo (⇧⌘Z)")
                Button("Reset") { library.resetRecipe(for: photo.id) }
                    .disabled(recipe.wrappedValue.isNeutral)
                    .help("Back to the original; removes the sidecar (⇧⌘R)")
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Text(footer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, library.sidecarError == nil ? 10 : 4)
            if let error = library.sidecarError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ kind: AdjustmentKind) -> some View {
        AdjustmentRow(
            kind: kind, recipe: recipe,
            onEditingChanged: { editing in
                if editing { library.beginEdit(photo.id) } else { library.endEdit(photo.id) }
            })
    }

    private func isExpanded(_ section: AdjustmentKind.Section) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(section) },
            set: { on in if on { expanded.insert(section) } else { expanded.remove(section) } })
    }

    private func sectionEdited(_ section: AdjustmentKind.Section) -> Bool {
        let r = recipe.wrappedValue
        return section.kinds.contains { !r[$0].isNoop }
    }

    private var footer: String {
        guard preview.imageURL == photo.url, let cg = preview.image else { return "Loading…" }
        let master = preview.masterSize
        return String(format: "render %.1f ms · %d×%d px of %.0f×%.0f master",
                      preview.renderMilliseconds, cg.width, cg.height, master.width, master.height)
    }
}

private struct AdjustmentRow: View {
    let kind: AdjustmentKind
    @Binding var recipe: Recipe
    /// Slider mouse-down / mouse-up, so a whole drag is one undo step.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let enabled = recipe.isEnabled(kind)
        VStack(spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { recipe.isEnabled(kind) },
                    set: { recipe.setEnabled(kind, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Apply \(kind.label.lowercased())")
                Text(kind.label)
                    .onTapGesture(count: 2) { recipe.reset(kind) }
                    .help("Double-click to reset")
                Spacer()
                Text(kind.format(recipe.value(of: kind)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: Binding(
                get: { recipe.value(of: kind) },
                set: { recipe.set(kind, to: $0) }), in: kind.range,
                   onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

/// Press and hold to see the photo without its edits; `\` toggles it.
private struct BeforeButton: View {
    @Binding var isPressed: Bool

    var body: some View {
        Label("Before", systemImage: "eye")
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isPressed ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 1000,
                                perform: {}, onPressingChanged: { isPressed = $0 })
            .help("Hold to compare with the original (\\ toggles)")
    }
}
