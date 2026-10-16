import SwiftUI

/// PhotoLab › Settings… (⌘,): the grid's thumbnail size, the loupe's
/// preview quality, the launch reopen and the sort each kind of source opens
/// in, and the learned style (its sample count, Forget Style). Every control edits the library's `AppSettings` (the sort through
/// `Library.setDefaultSort(_:for:)`, so the open source re-sorts when it is
/// of that kind); a change applies at once and is remembered.
struct SettingsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var settings = library.settings
        Form {
            Section("Grid") {
                LabeledContent("Thumbnail size") {
                    HStack {
                        Slider(value: $settings.gridThumbnailSize, in: AppSettings.thumbnailSizes)
                            .labelsHidden()
                        Text("\(Int(settings.gridThumbnailSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section {
                Picker("Preview quality", selection: $settings.previewQuality) {
                    ForEach(PreviewQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
            } header: {
                Text("Loupe")
            } footer: {
                Text("Balanced and Fast render the fitted photo at ¾ or ½ of the screen's pixels, so sliders respond sooner. 1:1 and exports are always full resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Launch") {
                Toggle("Reopen the last folder or album", isOn: $settings.reopenLastSource)
            }
            Section {
                LabeledContent("Learned from") {
                    HStack {
                        Text(styleSummary)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Forget Style") { library.forgetStyle() }
                            .disabled(!library.canForgetStyle)
                    }
                }
            } header: {
                Text("Style")
            } footer: {
                Text(library.styleError ?? "Photo › Learn Style from Selected Photos… compares your Basic and white-balance values with Auto's. It stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                sortRow("Folders", kind: .folder)
                sortRow("Photos albums", kind: .photos)
            } header: {
                Text("Sort")
            } footer: {
                Text("The order each kind of source opens in. The grid's Sort menu changes the same choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The sample count of the learned style (`StyleProfile.sampleCount`).
    private var styleSummary: String {
        let n = library.styleProfile?.sampleCount ?? 0
        return n == 0 ? "No photos" : "\(n) photo\(n == 1 ? "" : "s")"
    }

    private func sortRow(_ title: String, kind: RecentSource.Kind) -> some View {
        let current = library.defaultSort(for: kind)
        return LabeledContent(title) {
            HStack {
                Picker(title, selection: Binding(
                    get: { current.key },
                    set: { library.setDefaultSort(PhotoSort(key: $0, ascending: current.ascending), for: kind) })) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Direction", selection: Binding(
                    get: { current.ascending },
                    set: { library.setDefaultSort(PhotoSort(key: current.key, ascending: $0), for: kind) })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
