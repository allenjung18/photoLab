import SwiftUI

/// Open Photos Library…: the authorization state, then the albums. The
/// Allow button is the one place the system dialog is shown (the user's
/// click); a refusal links to System Settings; Recents is first, then the
/// regular albums, each with its image count. Return opens the selected
/// album, Esc cancels. Edits made in Photos are not shown: PhotoLab edits
/// the unadjusted original.
struct PhotosAlbumSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var browser = PhotosBrowser(access: .live)
    @State private var selected: PhotosAlbum.ID?
    @State private var requesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Photos Library")
                .font(.headline)
            Group {
                switch browser.status {
                case .notDetermined:
                    prompt("PhotoLab needs permission to read your Photos library. It reads the originals and writes back only what you export or save to Photos.") {
                        Button("Allow Access to Photos…") {
                            requesting = true
                            Task {
                                await browser.requestAccess()
                                requesting = false
                            }
                        }
                        .disabled(requesting)
                    }
                case .denied:
                    prompt("Photos access is off for PhotoLab. Turn it on under System Settings › Privacy & Security › Photos, then come back here.") {
                        Button("Open System Settings…") { browser.openSettings() }
                        Button("Check Again") { browser.refresh() }
                    }
                case .restricted:
                    prompt("Photos access is restricted on this Mac, so no album can be opened here.") { EmptyView() }
                case .authorized, .limited:
                    albums
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("Edits made in Photos are not shown; PhotoLab edits the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedAlbum == nil)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
        .onChange(of: browser.status) { _, _ in browser.refresh() }
    }

    private func prompt<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) { actions() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albums: some View {
        List(browser.albums, selection: $selected) { album in
            HStack {
                Image(systemName: album.isRecents ? "clock" : "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text(album.title)
                Spacer()
                Text("\(album.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(album.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selected = album.id
                open()
            }
        }
        .overlay {
            if browser.albums.isEmpty {
                Text(browser.status == .limited
                     ? "No album is in reach: Photos shared no photos with PhotoLab."
                     : "No albums.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedAlbum: PhotosAlbum? {
        browser.albums.first { $0.id == selected }
    }

    private func open() {
        guard let album = selectedAlbum else { return }
        library.open(album: album, access: browser.access)
        dismiss()
    }
}
