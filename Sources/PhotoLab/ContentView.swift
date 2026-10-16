import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(ExportQueue.self) private var exports
    @Environment(\.hasBundle) private var hasBundle

    var body: some View {
        @Bindable var library = library
        @Bindable var exports = exports
        Group {
            if library.source == nil {
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
                Button { library.choosePhotosAlbum() } label: {
                    Label("Open Photos Library", systemImage: "photo.on.rectangle")
                }
                .disabled(!hasBundle)
                .help(hasBundle
                      ? "Open a Photos album (⇧⌘O)"
                      : "The Photos library opens from the app bundle (scripts/bundle.sh)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if library.source != nil {
                    Picker("View", selection: viewBinding) {
                        Label("Grid", systemImage: "square.grid.3x3").tag(false)
                        Label("Loupe", systemImage: "photo").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(library.photos.isEmpty)
                    .help("Grid (G) or single photo (E)")
                    Toggle(isOn: compareBinding) {
                        Label("Before / After", systemImage: "rectangle.split.2x1")
                    }
                    .disabled(library.photos.isEmpty)
                    .help("Before and After side by side (Y)")
                }
                if library.loupe, library.source is PhotosSource {
                    Button { Task { await library.saveToPhotos() } } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(!library.canSaveToPhotos)
                    .help("Write this edit into Photos: it shows there and Revert to Original undoes it")
                }
            }
        }
        .background(HiddenShortcuts())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if exports.state != .idle { ExportBar() }
        }
        .sheet(item: $library.syncRequest) { request in
            SyncSheet(request: request)
        }
        .sheet(item: $library.keywordsRequest) { request in
            KeywordsSheet(request: request)
        }
        .sheet(item: $exports.request) { request in
            ExportSheet(request: request, options: exports.options, folder: exports.folder,
                        album: exports.album, toPhotos: exports.prefersPhotos)
        }
        .sheet(isPresented: $library.photosSheet) {
            PhotosAlbumSheet()
        }
    }

    private var viewBinding: Binding<Bool> {
        Binding(
            get: { library.loupe },
            set: { on in
                if on, library.selection == nil { library.selection = library.visiblePhotos.first?.id }
                library.loupe = on && library.selection != nil
            })
    }

    /// Turning compare on from the grid opens the loupe on the selection.
    private var compareBinding: Binding<Bool> {
        Binding(
            get: { library.compare && library.loupe },
            set: { on in
                library.compare = on
                if on, !library.loupe {
                    if library.selection == nil { library.selection = library.visiblePhotos.first?.id }
                    library.loupe = library.selection != nil
                }
            })
    }

    private var title: String { library.source?.title ?? "PhotoLab" }

    /// Grid: "N photos", or "n of N shown" under a filter or a search, plus the selection
    /// count. Loupe: the anchor's place among the visible photos and its marks.
    private var subtitle: String {
        guard library.source != nil else { return "" }
        let total = library.photos.count
        let shown = library.visiblePhotos.count
        if library.loupe, let i = library.visibleIndex {
            var s = !library.isNarrowed ? "\(i + 1) of \(total)" : "\(i + 1) of \(shown) shown"
            let marks = library.marks(for: library.selection!)
            if let flag = marks.flag { s += flag == .pick ? " · Pick" : " · Rejected" }
            if marks.rating > 0 { s += " · " + String(repeating: "★", count: marks.rating) }
            return s
        }
        var s = !library.isNarrowed ? "\(total) photos" : "\(shown) of \(total) shown"
        let n = library.selectedIDs.count
        if n > 1 { s += " · \(n) selected" }
        return s
    }
}

struct WelcomeView: View {
    @Environment(\.hasBundle) private var hasBundle
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Open a folder of photos, or a Photos album, to begin")
                .font(.title2)
            if let error = library.openError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 12) {
                Button("Open Folder…") { library.chooseFolder() }
                    .keyboardShortcut(.defaultAction)
                Button("Open Photos Library…") { library.choosePhotosAlbum() }
                    .disabled(!hasBundle)
            }
            RecentList()
            if !hasBundle {
                // Photos access is granted to an app bundle, never to a bare
                // `swift run` binary.
                Text("The Photos library opens from the app bundle: run scripts/bundle.sh --open and use build/PhotoLab.app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GridView: View {
    @Environment(Library.self) private var library

    /// The grid's columns: cells at least `AppSettings.gridThumbnailSize`
    /// points wide (the slider under the grid, Settings › Thumbnail size) and
    /// at most 1.45 times that, as many as fit.
    static func columns(for settings: AppSettings) -> [GridItem] {
        let size = settings.gridThumbnailSize
        return [GridItem(.adaptive(minimum: size, maximum: (size * 1.45).rounded()), spacing: 10)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if library.photos.isEmpty {
                    Text("No photos in this folder")
                        .foregroundStyle(.secondary)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if library.visiblePhotos.isEmpty {
                    VStack(spacing: 12) {
                        Text(library.search.isEmpty ? "No photos match the filter"
                             : library.filter == .all ? "No photos match the search"
                             : "No photos match the filter and the search")
                            .foregroundStyle(.secondary)
                        Button("Show All") {
                            library.filter = .all
                            library.searchText = ""
                        }
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: Self.columns(for: library.settings), spacing: 10) {
                        ForEach(library.visiblePhotos) { photo in
                            ThumbnailCell(photo: photo, selected: library.selectedIDs.contains(photo.id),
                                          anchor: photo.id == library.selection,
                                          edited: library.isEdited(photo.id),
                                          marks: library.marks(for: photo.id),
                                          recipe: library.recipe(for: photo.id))
                                .id(photo.id)
                                // Only a cell on screen names its photo; scrolling away cancels it.
                                .task(id: photo.id) { if !photo.isNamed { await library.resolveName(photo.id) } }
                                .contextMenu { PhotoContextMenu(photo: photo) }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !library.photos.isEmpty { FilterBar() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if library.selectedIDs.count > 1 { BatchBar() }
                if !library.photos.isEmpty { ThumbnailSizeBar() }
            }
        }
    }
}

/// The strip under the grid: how many photos it shows and the thumbnail
/// size slider, bound to `AppSettings.gridThumbnailSize` like the Settings
/// window's.
private struct ThumbnailSizeBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var settings = library.settings
        HStack(spacing: 8) {
            Text(library.visiblePhotos.count == 1 ? "1 photo" : "\(library.visiblePhotos.count) photos")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.secondary)
            Slider(value: $settings.gridThumbnailSize, in: AppSettings.thumbnailSizes)
                .frame(width: 140)
                .labelsHidden()
                .help("Thumbnail size (also in Settings, ⌘,)")
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The bar above the grid: the search field (name and keywords, ⌘F), then
/// Lightroom's filter choices (All · Picks · Unflagged · Rejected · ≥ 1…5
/// stars), the Keywords menu and the Sort menu. The grid, Select All, the
/// batch actions and the loupe arrows all walk the filtered list.
private struct FilterBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 10) {
            SearchField()
            FilterChoices()
            Spacer()
            KeywordsMenu()
            Menu {
                CommandItems(placement: .sort, context: CommandContext(library: library))
            } label: {
                Label("Sort: \(library.sort.key.label)",
                      systemImage: library.sort.ascending ? "arrow.up" : "arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The grid's order (View › Sort By); the filmstrip and the arrow keys follow it")
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The grid's search: `Library.searchText`, every whitespace-separated term
/// matched against a photo's name and keywords (`PhotoSearch`). Its focus is
/// mirrored into `Library.textEntryActive`, which disables every bare-key
/// command while the user types. ⌘F (Search Photos) focuses it; Esc clears
/// it and gives the focus back; Return gives the focus back.
private struct SearchField: View {
    @Environment(Library.self) private var library
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var library = library
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $library.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand {
                    library.searchText = ""
                    focused = false
                }
                .onSubmit { focused = false }
            if !library.searchText.isEmpty {
                Button {
                    library.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        .frame(width: 180)
        .help("Search by name and keyword; every word must match (⌘F, Esc clears)")
        .onChange(of: focused) { _, now in library.textEntryActive = now }
        .onChange(of: library.searchFocusRequested) { _, asked in if asked { takeFocus() } }
        .onAppear {
            if library.searchFocusRequested {
                takeFocus()
            } else {
                // The window may give its first text field the focus on its
                // own; only ⌘F or a click should, or the bare keys go dead.
                DispatchQueue.main.async { focused = false }
            }
        }
        .onDisappear {
            focused = false
            library.textEntryActive = false
        }
    }

    private func takeFocus() {
        library.searchFocusRequested = false
        DispatchQueue.main.async { focused = true }
    }
}

/// The open source's keywords with how many photos hold each
/// (`Library.keywordTally`); picking one sets the search to it.
private struct KeywordsMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        let tally = library.keywordTally
        Menu {
            ForEach(tally) { entry in
                Button("\(entry.keyword) (\(entry.count))") { library.searchText = entry.keyword }
            }
        } label: {
            Label("Keywords", systemImage: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tally.isEmpty)
        .help("Search for one of this source's keywords (Photo › Keywords…, ⌘K, adds them)")
    }
}

/// The filter's segmented choices.
private struct FilterChoices: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        HStack(spacing: 10) {
            Text("Show")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Filter", selection: $library.filter) {
                ForEach(PhotoFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Which photos the grid shows; P / X / U flag, 0–5 rate the selection")
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
            FlagStarControl(targets: library.batchTargets)
            Spacer()
            Button("Sync Settings…") { library.requestSync() }
                .help(library.selectedPhoto.map { "Copy \($0.name)'s settings onto the other selected photos, with checkboxes for what to sync" }
                      ?? "Copy the settings of the photo you clicked first onto the others, with checkboxes for what to sync")
            Menu("Apply Preset") {
                ForEach(presets.presets) { preset in
                    Button(preset.name) { library.apply(preset, to: library.batchTargets) }
                }
            }
            .fixedSize()
            .disabled(presets.presets.isEmpty)
            .help("Apply a preset to every selected photo (one undo step)")
            Button("Keywords…") { library.requestKeywords() }
                .help("Add or remove keywords on every selected photo (⌘K)")
            Button("Export…") { exports.requestExport(from: library) }
                .disabled(exports.isRunning)
                .help("Render every selected photo into a folder: format, quality, size and name in the sheet (⇧⌘E)")
            Button("Deselect") { library.collapseSelection() }
                .help("Back to the anchor alone (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
/// the file in flight, Cancel; then the result with Show in Finder (a
/// folder run) or Open Photos (a Photos run).
private struct ExportBar: View {
    @Environment(ExportQueue.self) private var exports
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 12) {
            switch exports.state {
            case .running:
                ProgressView(value: Double(exports.completed), total: Double(max(1, exports.total)))
                    .frame(width: 160)
                Text("Exporting \(min(exports.completed + 1, exports.total)) of \(exports.total)")
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
                if !exports.detailLines.isEmpty {
                    Button("Details…") { showDetails = true }
                        .popover(isPresented: $showDetails, arrowEdge: .top) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(exports.detailLines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.caption).textSelection(.enabled)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 420, height: min(260, CGFloat(exports.detailLines.count) * 22 + 28))
                        }
                        .help("Every photo that failed or was skipped, with the reason")
                }
                Spacer()
                switch exports.target {
                case .folder(let folder)?:
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(exports.exported.isEmpty ? [folder] : exports.exported)
                    }
                case .photosLibrary?:
                    Button("Open Photos") {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                case nil:
                    EmptyView()
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
        let folder = exports.target?.displayName ?? ""
        var s = exports.state == .cancelled
            ? "Cancelled: \(exports.done) of \(exports.total) exported to \(folder)"
            : "Exported \(exports.done) of \(exports.total) to \(folder)"
        if !exports.skipped.isEmpty { s += " · \(exports.skipped.count) skipped (file exists)" }
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
    /// The flag corner (top-left) and the stars (bottom-left) over the image.
    var marks = Marks.none
    /// The photo's recipe: the cell shows the edit (rendered from the cached
    /// plain thumbnail), so a change to it re-keys the cell's task.
    var recipe = Recipe.neutral
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("Can't open \(photo.caption)")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: anchor ? 4 : 3))
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
            .overlay(alignment: .topLeading) {
                if let flag = marks.flag {
                    Image(systemName: flag == .pick ? "flag.fill" : "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(flag == .pick ? Color.white : Color.white.opacity(0.9))
                        .padding(4)
                        .background(flag == .pick ? Color.accentColor : Color.black.opacity(0.7), in: Circle())
                        .padding(6)
                        .help(flag == .pick ? "Pick (P)" : "Rejected (X)")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if marks.rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(1...Marks.maxRating, id: \.self) { n in
                            Image(systemName: n <= marks.rating ? "star.fill" : "star")
                                .font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
                    .help("\(marks.rating) star\(marks.rating == 1 ? "" : "s") (0–5)")
                }
            }
            .opacity(marks.flag == .reject ? 0.55 : 1)
            Text(photo.caption)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .help(photo.caption)
        .task(id: Thumbnails.Key(photo.id, recipe: recipe)) {
            // The entry for this photo and recipe when it is there; else the
            // plain thumbnail first (or whatever the cell already shows, the
            // previous recipe's image, stays up) and the rendered one when it
            // lands. A neutral recipe needs no second step.
            let key = Thumbnails.Key(photo.id, recipe: recipe)
            switch await Thumbnails.shared.resolve(key, showing: image) {
            case .image(let found): image = found; failed = false
            case .failed: failed = true
            case .unchanged: break
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Where the loupe stands with a photo whose file its source has to
/// produce (a Photos asset): being fetched (an iCloud original downloads
/// here), or failed with the source's reason (offline, asset gone).
enum OriginalFetch: Equatable {
    case none, fetching, failed(String)

    /// Fetches a source-held original and says where that left the loupe:
    /// the file and `.none`, or no file and `.failed` with the reason. A
    /// cancelled fetch is `nil`: the caller drops it.
    @MainActor static func load(_ id: Photo.ID,
                     using fetch: (Photo.ID) async throws -> URL) async -> (file: URL?, state: OriginalFetch)? {
        do {
            let url = try await fetch(id)
            if Task.isCancelled { return nil }
            return (url, .none)
        } catch {
            if Task.isCancelled { return nil }
            return (nil, .failed(error.localizedDescription))
        }
    }

    /// What the panel's footer and the preset strip say while there is no
    /// original to show, instead of "Loading…" and spinners that would never
    /// end; nil while the fetch is not failed.
    var unavailableNote: String? {
        if case .failed = self { return "Original not available" }
        return nil
    }
}

/// The accessible names of the loupe's icon-only controls, one place so each
/// reads distinctly (five stars are five names, not five "star"s).
enum AccessibleName {
    static let undo = "Undo"
    static let redo = "Redo"
    static let pick = "Pick"
    static let reject = "Reject"
    static let unflag = "Unflag"
    static let moreActions = "More preset actions"
    static func stars(_ n: Int) -> String { "\(n) star\(n == 1 ? "" : "s")" }
    /// The adjustment's own name; the tone curve's and the HSL's say which
    /// group they belong to, as their plain labels repeat the tone rows'.
    static func adjustment(_ kind: AdjustmentKind) -> String {
        if let (channel, band) = kind.hsl { return "\(channel.title) \(band.label)" }
        if kind.section == .curve { return "\(kind.label) (tone curve)" }
        return kind.label
    }
    static func applyAdjustment(_ kind: AdjustmentKind) -> String { "Apply \(adjustment(kind).lowercased())" }
}

/// The loupe: the canvas and the panel, both fed the photo's original file
/// from the open source (`Library.originalFile(for:)`). A folder photo's
/// file is known at once (`Photo.fileURL`); another source's is fetched
/// here, and the canvas shows the thumbnail with a Downloading state until
/// it arrives, or why it did not.
struct LoupeView: View {
    @Environment(Library.self) private var library
    let photo: Photo
    @State private var preview = PreviewModel()
    @State private var file: URL?
    @State private var fetch = OriginalFetch.none

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewCanvas(photo: photo, file: resolvedFile, fetch: fetch, preview: preview)
                if library.showFilmstrip {
                    Divider()
                    FilmstripView()
                }
            }
            Divider()
            AdjustmentsPanel(photo: photo, file: resolvedFile, fetch: fetch, preview: preview)
                .frame(width: 280)
                .clipped()
        }
        .task(id: photo.id) {
            guard photo.fileURL == nil else { fetch = .none; return }
            file = nil
            fetch = .fetching
            guard let result = await OriginalFetch.load(photo.id, using: { try await library.originalFile(for: $0) })
            else { return }
            file = result.file
            fetch = result.state
        }
        // A Photos asset with no sidecar may carry PhotoLab's edit in its
        // adjustment data (saved from another Mac, or the sidecar deleted).
        .task(id: photo.id) {
            await library.recoverRecipe(for: photo.id)
        }
    }

    private var resolvedFile: URL? { photo.fileURL ?? file }
}

/// The rendered frame, sized to the view. Every recipe or size change asks
/// the preview model for a new frame at the view's pixel size. In compare
/// mode (`Library.compare`, Y) the canvas is two equal halves, Before (the
/// model's neutral frame) and After (the recipe), each at one half's size.
///
/// Zoom (`Library.loupeZoom`): Z, or a click on the photo, shows it at 1:1
/// (one image pixel per screen pixel) around the middle or the point
/// clicked; a drag pans, the window held inside the frame; a click at 1:1
/// goes back to fit. In compare mode both halves show the same region and
/// either half takes the click and the drag. The arithmetic is `ZoomMath`.
///
/// Crop mode (`Library.cropMode`, R): the canvas renders the recipe without
/// its crop (the rotated frame whole) and `CropOverlay` draws the crop over
/// it; the zoom click and the pan are off while it is on.
private struct PreviewCanvas: View {
    @Environment(Library.self) private var library
    @Environment(\.displayScale) private var displayScale
    let photo: Photo
    /// The photo's original file; nil until the source has it.
    let file: URL?
    /// How the file is coming along while it is nil.
    let fetch: OriginalFetch
    let preview: PreviewModel
    @State private var viewSize: CGSize = .zero
    /// The 1:1 centre a pan started from (clamped), while a drag is panning.
    @State private var panStart: CGPoint?

    private var recipe: Recipe {
        if library.showBefore { return .neutral }
        let r = library.recipe(for: photo.id)
        return library.cropMode ? CropMath.uncropped(r) : r
    }

    /// One pane in points: the whole canvas, or one half of it side by side.
    private var pane: CGSize {
        library.compare ? CGSize(width: max(0, viewSize.width - 1) / 2, height: viewSize.height) : viewSize
    }

    /// One pane's longest side in pixels, times Settings › Preview quality
    /// (`PreviewQuality.pixelSize`). Both halves are rendered at this size;
    /// the frame is drawn scaled to fit, and the 1:1 window is not scaled.
    private var pixelSize: Int { library.settings.previewQuality.pixelSize(longestSide(pane)) }

    /// The 1:1 window: one pane in pixels.
    private var window: CGSize { ZoomMath.window(pane: pane, displayScale: displayScale) }

    private var zoomed: Bool { library.loupeZoom != .fit }

    /// The 1:1 window for this photo, once it has landed.
    private var zoomWindow: CGImage? {
        guard zoomed, let file, preview.zoomURL == file else { return nil }
        return preview.zoomImage
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if library.compare {
                    HStack(spacing: 0) {
                        zoomable(beforeFrame, fitFrame: preview.beforeImage)
                            .overlay(alignment: .topLeading) { badge("Before") }
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1)
                        zoomable(afterFrame, fitFrame: preview.image)
                            .overlay(alignment: .topLeading) { badge(library.showBefore ? "Before" : "After") }
                    }
                } else {
                    zoomable(afterFrame, fitFrame: preview.image)
                        .overlay { cropOverlay }
                        .overlay(alignment: .topLeading) { if library.showBefore { badge("Before") } }
                        .overlay(alignment: .top) { whiteBalanceHint }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            // The canvas is black in both appearances, so its text and
            // spinners resolve their colours as in dark mode.
            .environment(\.colorScheme, .dark)
            .overlay(alignment: .topTrailing) { zoomBadge }
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { _, size in viewSize = size }
        }
        .onChange(of: file, initial: true) { _, url in
            guard let url else { return }
            // A new photo is at fit before its master loads, so it never
            // starts a full-resolution decode it will not use.
            preview.setZoom(library.loupeZoom)
            preview.load(url)
            request()
        }
        .onChange(of: recipe) { request() }
        .onChange(of: pixelSize) { request() }
        .onChange(of: window) { request() }
        .onChange(of: library.loupeZoom, initial: true) { _, zoom in preview.setZoom(zoom) }
        // A photo whose frame fits the view whole goes back to fit by itself
        // (`PreviewModel.setZoom`); the menu's checkmark follows.
        .onChange(of: preview.zoom) { _, zoom in
            if zoom == .fit, library.loupeZoom != .fit { library.loupeZoom = .fit }
        }
        .onChange(of: library.compare, initial: true) { _, on in
            // The half-size request first, so the Before that compare mode
            // asks for is already the half-size one.
            request()
            preview.setCompare(on)
        }
        .onChange(of: library.showClipping, initial: true) { _, on in preview.setClipping(on) }
        // The eyedropper's crosshair goes with the tool.
        .onChange(of: library.whiteBalancePicking) { _, on in if !on { NSCursor.arrow.set() } }
    }

    /// The recipe's frame (or, while it is coming, why not); at 1:1 the
    /// window, unscaled, once it has landed (the fit frame until then).
    @ViewBuilder private var afterFrame: some View {
        ZStack {
            Color.black
            if let cg = zoomWindow {
                Image(decorative: cg, scale: displayScale)
            } else if let cg = preview.image, let file, preview.imageURL == file {
                Image(decorative: cg, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if let file, preview.failed == file {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Could not open \(photo.name)")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            } else if case .failed(let why) = fetch {
                VStack(spacing: 6) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text("Original not available for \(photo.name)")
                        .font(.callout)
                    Text(why)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            } else if let thumb = Thumbnails.shared.cached(photo.id, recipe: recipe) ?? Thumbnails.shared.cached(photo.id) {
                Image(nsImage: thumb).resizable().scaledToFit().padding(8)
                    .overlay(fetchOverlay)
            } else {
                fetchOverlay
            }
        }
    }

    /// Compare mode's neutral frame; the plain thumbnail until it lands. At
    /// 1:1 the neutral window at the After window's region.
    @ViewBuilder private var beforeFrame: some View {
        ZStack {
            Color.black
            if zoomWindow != nil, let cg = preview.zoomBeforeImage {
                Image(decorative: cg, scale: displayScale)
            } else if let cg = preview.beforeImage, let file, preview.beforeURL == file {
                Image(decorative: cg, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if let file, preview.failed == file {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if let thumb = Thumbnails.shared.cached(photo.id) {
                Image(nsImage: thumb).resizable().scaledToFit().padding(8)
            } else {
                ProgressView().controlSize(.regular)
            }
        }
    }

    /// A pane that takes the zoom click and the pan drag. `fitFrame` is the
    /// frame shown at fit in this pane, which a click is mapped through.
    private func zoomable(_ content: some View, fitFrame: CGImage?) -> some View {
        content
            .contentShape(Rectangle())
            // A crosshair while the white-balance eyedropper is armed.
            .onContinuousHover { phase in
                guard library.whiteBalancePicking else { return }
                switch phase {
                case .active: NSCursor.crosshair.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in pan(g.translation) }
                    .onEnded { g in
                        defer { panStart = nil }
                        guard panStart == nil, !isDrag(g.translation) else { return }
                        click(at: g.startLocation, fitFrame: fitFrame)
                    })
    }

    /// Under 3 points of movement a press is a click, not a pan.
    private func isDrag(_ t: CGSize) -> Bool { hypot(t.width, t.height) >= 3 }

    /// At 1:1 a drag moves the window with the pointer, from the centre
    /// it started at (clamped first, so a centre clicked near an edge pans
    /// at once). At fit, or before the window has landed, it does nothing.
    private func pan(_ translation: CGSize) {
        guard !library.cropMode, case .actual(let center) = library.loupeZoom, zoomWindow != nil,
              panStart != nil || isDrag(translation) else { return }
        let frame = preview.zoomFrameSize
        let start = panStart ?? ZoomMath.clamp(center, window: window, frame: frame)
        panStart = start
        library.loupeZoom = .actual(center: ZoomMath.pan(start, by: translation, displayScale: displayScale,
                                                         window: window, frame: frame))
    }

    /// At fit, 1:1 at the point clicked (a click on the black around the
    /// photo does nothing); at 1:1, back to fit. While the white-balance
    /// eyedropper is armed the click samples instead (`pickWhiteBalance`)
    /// and the zoom stays.
    private func click(at point: CGPoint, fitFrame: CGImage?) {
        guard !library.cropMode else { return }
        if library.whiteBalancePicking { pickWhiteBalance(at: point, fitFrame: fitFrame); return }
        if zoomed { library.loupeZoom = .fit; return }
        guard let fitFrame,
              let center = ZoomMath.center(forClick: point,
                                           frame: CGSize(width: fitFrame.width, height: fitFrame.height),
                                           pane: pane) else { return }
        library.loupeZoom = .actual(center: center)
    }

    /// The eyedropper's click mapped to a point normalised in the shown
    /// frame: through the 1:1 window once it has landed, else through the
    /// fit frame. Off the photo, or while Show Original shows a different
    /// frame, nothing happens and the tool stays armed.
    private func pickWhiteBalance(at point: CGPoint, fitFrame: CGImage?) {
        guard !library.showBefore else { return }
        let normalised: CGPoint?
        if zoomed {
            guard zoomWindow != nil, let region = preview.zoomRegion else { return }
            normalised = ZoomMath.point(forClick: point, region: region, frame: preview.zoomFrameSize,
                                        pane: pane, displayScale: displayScale)
        } else {
            guard let fitFrame else { return }
            normalised = ZoomMath.center(forClick: point, frame: CGSize(width: fitFrame.width, height: fitFrame.height),
                                         pane: pane)
        }
        guard let normalised else { return }
        let id = photo.id
        Task { await library.pickWhiteBalance(at: normalised, for: id) }
    }

    /// While the eyedropper is armed: what a click does, or why the last
    /// one changed nothing.
    @ViewBuilder private var whiteBalanceHint: some View {
        if library.whiteBalancePicking {
            HStack(spacing: 6) {
                if library.whiteBalanceReading { ProgressView().controlSize(.small) }
                Text(library.whiteBalanceNote ?? "Click something that should be neutral grey or white; Esc to cancel")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(12)
            .allowsHitTesting(false)
        }
    }

    /// Crop mode's rectangle and handles, over the fit frame once the frame
    /// shown is the uncropped one (`CropMath.isCropFrame`); not at 1:1 and
    /// not while Show Original is held.
    @ViewBuilder private var cropOverlay: some View {
        let current = library.recipe(for: photo.id)
        if library.cropMode, !zoomed, !library.showBefore, let file, preview.imageURL == file,
           let cg = preview.image, let shown = preview.imageRecipe,
           CropMath.isCropFrame(shown, for: current) {
            let fit = ZoomMath.fitRect(frame: CGSize(width: cg.width, height: cg.height), pane: pane)
            CropOverlay(fit: fit, crop: CropMath.crop(of: current), locked: library.cropAspect.isLocked,
                        straightening: library.straightening,
                        drag: { handle, t in library.dragCrop(handle, by: t, fit: fit.size, for: photo.id) },
                        end: { library.endCropDrag(photo.id) },
                        straighten: { a, b in library.straighten(from: a, to: b, for: photo.id) })
        }
    }

    /// "1:1" while zoomed, with a spinner until the first window lands.
    @ViewBuilder private var zoomBadge: some View {
        if zoomed {
            HStack(spacing: 6) {
                if zoomWindow == nil { ProgressView().controlSize(.small) }
                Text("1:1")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(12)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(12)
    }

    /// A spinner, labelled while the source downloads the original.
    @ViewBuilder private var fetchOverlay: some View {
        if fetch == .fetching {
            VStack(spacing: 8) {
                ProgressView().controlSize(.regular)
                Text("Downloading original…")
                    .font(.caption.weight(.semibold))
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            ProgressView().controlSize(.regular)
        }
    }

    private func longestSide(_ size: CGSize) -> Int {
        Int((max(size.width, size.height) - 16) * displayScale)
    }

    private func request() {
        guard let file else { return }
        preview.request(url: file, recipe: recipe, maxPixelSize: pixelSize, viewPixelSize: window)
    }
}

/// The crop rectangle over the fit frame `fit` (view points): the area cut
/// away dimmed, the kept area outlined with its thirds, and the four edge
/// and four corner handles (the corners alone under an aspect lock,
/// `CropMath.handles(locked:)`). A handle's drag is measured in the overlay's
/// own coordinate space from where it started (`drag` gets the
/// translation; `end` the mouse-up), so the handle moving under the pointer
/// does not feed back into the drag. The arithmetic is `CropMath`.
///
/// While the straighten tool is armed the handles go and a drag anywhere on
/// the frame draws a line; its mouse-up hands both ends to `straighten`
/// (`StraightenMath` turns them into a rotate value).
struct CropOverlay: View {
    let fit: CGRect
    let crop: CropMath.Crop
    let locked: Bool
    let straightening: Bool
    let drag: (CropMath.Handle, CGSize) -> Void
    let end: () -> Void
    let straighten: (CGPoint, CGPoint) -> Void
    /// The straighten line while it is being drawn.
    @State private var line: (start: CGPoint, end: CGPoint)?

    private static let space = "cropOverlay"
    /// A handle's hit area, larger than what is drawn.
    private static let hitSize: CGFloat = 22

    var body: some View {
        let r = CropMath.rect(crop, in: fit)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(fit)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            Path { $0.addRect(r) }.stroke(Color.white, lineWidth: 1)
            if straightening {
                straightenLayer
            } else {
                handles(r)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onChange(of: straightening) { line = nil }
    }

    /// The eight handles, or the four corners under an aspect lock.
    @ViewBuilder private func handles(_ r: CGRect) -> some View {
            ForEach(CropMath.handles(locked: locked)) { handle in
                handleMark(handle)
                    .frame(width: Self.hitSize, height: Self.hitSize)
                    .contentShape(Rectangle())
                    .position(handle.point(in: r))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                            .onChanged { drag(handle, $0.translation) }
                            .onEnded { _ in end() })
                    .accessibilityLabel("Crop \(handle.label)")
            }
    }

    /// The straighten tool: the whole frame takes the drag, the line is
    /// drawn from where it started to the pointer, and a hint says what to do.
    @ViewBuilder private var straightenLayer: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: fit.width, height: fit.height)
            .position(x: fit.midX, y: fit.midY)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { line = ($0.startLocation, $0.location) }
                    .onEnded { g in
                        line = nil
                        straighten(g.startLocation, g.location)
                    })
            .accessibilityLabel("Straighten: drag along a line that should be level")
        if let line {
            Path { p in
                p.move(to: line.start)
                p.addLine(to: line.end)
            }
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        } else {
            Text("Drag along a horizon or an upright to straighten")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .position(x: fit.midX, y: fit.minY + 20)
                .allowsHitTesting(false)
        }
    }

    /// A white square at a corner, a short bar along an edge.
    private func handleMark(_ handle: CropMath.Handle) -> some View {
        let horizontalBar = handle == .top || handle == .bottom
        let size: CGSize = handle.isCorner ? CGSize(width: 9, height: 9)
            : horizontalBar ? CGSize(width: 18, height: 5) : CGSize(width: 5, height: 18)
        return Rectangle()
            .fill(Color.white)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.6), radius: 1)
    }
}

/// The histogram, the preset strip, then the adjustment sliders in sections (Basic, Color,
/// Tone Curve, HSL, Color Grading, Detail, Effects, Crop & Rotate), each with an enable checkbox, plus a
/// hold-to-compare button, undo / redo / reset, and the live render time
/// of the last frame. The HSL section shows one channel (hue, saturation or
/// luminance) of the eight bands at a time, like Lightroom's panel.
/// Which sections the adjustments panel opens expanded, and the HSL channel
/// it opens on. Unset in the app (Basic open, Hue); a test sets it to host
/// the panel in a given state.
struct PanelStart: Equatable {
    var sections: Set<AdjustmentKind.Section>
    var hslChannel: AdjustmentKind.HSLChannel = .hue
}

private struct PanelStartKey: EnvironmentKey {
    static let defaultValue: PanelStart? = nil
}

extension EnvironmentValues {
    var panelStart: PanelStart? {
        get { self[PanelStartKey.self] }
        set { self[PanelStartKey.self] = newValue }
    }
}

struct AdjustmentsPanel: View {
    @Environment(Library.self) private var library
    let photo: Photo
    /// The photo's original file; nil until the source has it.
    let file: URL?
    /// How the file is coming along while it is nil.
    var fetch = OriginalFetch.none
    let preview: PreviewModel
    @State private var expanded: Set<AdjustmentKind.Section> = [.basic]
    @State private var presetsExpanded = true
    @State private var hslChannel: AdjustmentKind.HSLChannel = .hue
    @Environment(\.panelStart) private var panelStart

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
                    HistogramView(histogram: file != nil && preview.imageURL == file ? preview.histogram : nil,
                                  showClipping: $library.showClipping)
                        .padding(.bottom, 6)
                    DisclosureGroup(isExpanded: $library.showInfo) {
                        InfoSection(photo: photo, file: file)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    } label: {
                        Text("Info").font(.callout.weight(.semibold))
                    }
                    DisclosureGroup(isExpanded: $library.showHistory) {
                        HistoryList(photo: photo)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    } label: {
                        Text("History").font(.callout.weight(.semibold))
                    }
                    DisclosureGroup(isExpanded: $presetsExpanded) {
                        PresetStrip(photo: photo, file: file, unavailable: fetch.unavailableNote != nil)
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
                                    if section == .geometry {
                                        cropButton
                                        aspectRow
                                    }
                                    if section == .basic { autoButton }
                                    if section == .color { whiteBalanceButton }
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
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    FlagStarControl(targets: [photo.id])
                    Spacer(minLength: 4)
                }
                HStack(spacing: 6) {
                    BeforeButton(isPressed: $library.showBefore)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Button { library.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel(AccessibleName.undo)
                        .disabled(!library.canUndo)
                        .help("Undo (⌘Z)")
                    Button { library.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .accessibilityLabel(AccessibleName.redo)
                        .disabled(!library.canRedo)
                        .help("Redo (⇧⌘Z)")
                    Button("Reset") { library.resetRecipe(for: photo.id) }
                        .disabled(recipe.wrappedValue.isDefault)
                        .help("Back to the original; removes the sidecar (⇧⌘R)")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 10)
            if let footer {
                Text(footer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, library.sidecarError == nil ? 10 : 4)
            }
            if let error = library.sidecarError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let save = photosSaveLine {
                Text(save.text)
                    .font(.caption2)
                    .foregroundStyle(save.failed ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            if let start = panelStart {
                expanded = start.sections
                hslChannel = start.hslChannel
            }
        }
    }

    /// Auto, at the head of Basic: the same command as Photo › Auto Tone
    /// and its key, on this photo.
    private var autoButton: some View {
        let command = AppCommand.command(.autoTone)
        let context = CommandContext(library: library, targetIDs: [photo.id], subjectID: photo.id)
        return HStack(spacing: 6) {
            Button {
                command.perform(context)
            } label: {
                Label("Auto", systemImage: "wand.and.stars")
            }
            .disabled(!command.isEnabled(context) || file == nil)
            .help("Set exposure, contrast, highlights, shadows, whites and blacks from the photo's histogram (⌘U)")
            if library.autoToning { ProgressView().controlSize(.mini) }
        }
        .controlSize(.small)
    }

    /// The white-balance eyedropper, at the head of Color beside Temperature
    /// and Tint: the same command as Photo › White Balance Picker and its
    /// key. The last refusal is shown under it.
    private var whiteBalanceButton: some View {
        let command = AppCommand.command(.whiteBalance)
        let key = command.key.map(AppCommand.label(for:)) ?? ""
        let context = CommandContext(library: library)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { library.whiteBalancePicking },
                                 set: { if $0 != library.whiteBalancePicking { command.perform(context) } })) {
                Label("White Balance", systemImage: "eyedropper")
            }
            .toggleStyle(.button)
            .disabled(!command.isEnabled(context) || file == nil)
            .help("Click a spot on the photo that should be neutral to set temperature and tint (\(key)); Esc to cancel")
            if let note = library.whiteBalanceNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    /// Crop mode on and off, beside the crop sliders: the same command as
    /// Photo › Crop and its key.
    private var cropButton: some View {
        let command = AppCommand.command(.crop)
        let key = command.key.map(AppCommand.label(for:)) ?? ""
        return Button {
            command.perform(CommandContext(library: library))
        } label: {
            Label(library.cropMode ? "Done Cropping" : "Crop on Photo", systemImage: "crop")
        }
        .controlSize(.small)
        .disabled(!command.isEnabled(CommandContext(library: library)))
        .help("Drag the crop's edges and corners on the photo (\(key)); Esc to finish")
    }

    /// The crop's aspect lock and the straighten tool, under the crop
    /// button. Picking a ratio (or swapping it) refits the crop at once
    /// (`Library.setCropAspect`, one undo step); the frame's aspect is the
    /// decoded master's, which rotate keeps.
    private var aspectRow: some View {
        let aspect = library.cropAspect
        let frame = preview.masterSize
        return HStack(spacing: 6) {
            Picker("Aspect", selection: Binding(
                get: { aspect.preset },
                set: { preset in
                    var a = aspect
                    a.preset = preset
                    library.setCropAspect(a, frame: frame, for: photo.id)
                })) {
                ForEach(CropMath.Aspect.Preset.allCases) { Text(aspect.title(of: $0)).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Lock the crop's corners to a ratio; picking one refits the crop")
            Button {
                library.swapCropAspect(frame: frame, for: photo.id)
            } label: {
                Image(systemName: "rectangle.portrait.rotate")
            }
            .disabled(!aspect.canSwap)
            .help("Swap portrait and landscape")
            .accessibilityLabel("Swap portrait and landscape")
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { library.straightening }, set: { library.straightening = $0 })) {
                Label("Straighten", systemImage: "level")
            }
            .toggleStyle(.button)
            .disabled(!library.loupe)
            .help("Drag a line along a horizon on the photo to level it; Esc to cancel")
        }
        .controlSize(.small)
        .disabled(frame == .zero)
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

    /// The last Save to Photos of this photo, when there was one.
    private var photosSaveLine: (text: String, failed: Bool)? {
        switch library.photosSave {
        case .saving(photo.id): return ("Saving to Photos…", false)
        case .saved(photo.id): return ("Saved to Photos", false)
        case .failed(photo.id, let reason): return ("Could not save to Photos: \(reason)", true)
        default: return nil
        }
    }

    /// The panel's status line: Loading… / Could not open / the fetch note,
    /// and, only with the `showTimings` default on, the render timing.
    private var footer: String? {
        if let note = fetch.unavailableNote { return note }
        guard let file, preview.imageURL == file, let cg = preview.image else {
            return file != nil && preview.failed == file ? "Could not open" : "Loading…"
        }
        guard DeveloperInfo.showTimings else { return nil }
        if preview.imageIsFirstFrame {
            return String(format: "render %.1f ms · %d×%d px of the embedded preview",
                          preview.renderMilliseconds, cg.width, cg.height)
        }
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
                    .accessibilityLabel(AccessibleName.applyAdjustment(kind))
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
                .accessibilityLabel(AccessibleName.adjustment(kind))
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
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isPressed.toggle() }
            .help("Hold to compare with the original (\\ toggles)")
    }
}
