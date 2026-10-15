import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library

    var body: some View {
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
        return "\(library.photos.count) photos"
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
            Button("") { library.loupe = false }.keyboardShortcut(.escape, modifiers: [])
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
                            ThumbnailCell(photo: photo, selected: photo.id == library.selection)
                                .id(photo.id)
                                .onTapGesture(count: 2) {
                                    library.selection = photo.id
                                    library.loupe = true
                                }
                                .onTapGesture { library.selection = photo.id }
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
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let selected: Bool
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
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
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

/// One slider per adjustment with an enable checkbox, a hold-to-compare
/// button, reset, and the live render time of the last frame.
struct AdjustmentsPanel: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let preview: PreviewModel

    private var recipe: Binding<Recipe> {
        Binding(
            get: { library.recipe(for: photo.id) },
            set: { library.setRecipe($0, for: photo.id) })
    }

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AdjustmentKind.allCases) { kind in
                        AdjustmentRow(kind: kind, recipe: recipe)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                BeforeButton(isPressed: $library.showBefore)
                Spacer()
                Button("Reset All") { recipe.wrappedValue.resetAll() }
                    .disabled(recipe.wrappedValue.isNeutral)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Text(footer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                set: { recipe.set(kind, to: $0) }), in: kind.range)
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
