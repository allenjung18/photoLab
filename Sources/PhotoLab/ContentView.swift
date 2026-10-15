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
/// to move the selection, Escape back to the grid, Return into the loupe.
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
    @Environment(Library.self) private var library
    let photo: Photo
    @State private var image: NSImage?
    @State private var loadedFor: URL?

    var body: some View {
        ZStack {
            Color.black
            if let image, loadedFor == photo.url {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if let thumb = Thumbnails.shared.cached(photo.url) {
                Image(nsImage: thumb).resizable().scaledToFit().padding(8)
                    .overlay(ProgressView().controlSize(.regular))
            } else {
                ProgressView()
            }
        }
        .task(id: photo.url) {
            let url = photo.url
            let full = await Task.detached(priority: .userInitiated) {
                ImageLoading.downsampled(url, maxPixelSize: 3200)
            }.value
            if !Task.isCancelled { image = full; loadedFor = url }
        }
        .onTapGesture(count: 2) { library.loupe = false }
    }
}
