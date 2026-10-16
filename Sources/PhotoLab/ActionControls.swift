import SwiftUI

/// The marks and the context menu as clickable controls. Every action runs the
/// `AppCommand` of the same name (the one definition the menus and keys use),
/// over a `CommandContext` that pins its targets, so a button, a menu item and
/// a key do the same thing through the same `Library` method.
extension AppCommand {
    static let rateNames: [Name] = [.rate0, .rate1, .rate2, .rate3, .rate4, .rate5]
}

/// Pick, Reject and five stars for `targets`: the loupe's panel footer (the
/// one photo) and the batch bar (every selected photo). A star that is the
/// current rating of every target clears it, as in Lightroom.
struct FlagStarControl: View {
    @Environment(Library.self) private var library
    let targets: [Photo.ID]

    private var context: CommandContext { CommandContext(library: library, targetIDs: targets) }

    private var flags: Set<Marks.Flag?> { Set(targets.map { library.flag(for: $0) }) }
    private var ratings: Set<Int> { Set(targets.map { library.rating(for: $0) }) }

    var body: some View {
        let ctx = context
        HStack(spacing: 4) {
            Button { AppCommand.command(.pick).perform(ctx) } label: {
                Image(systemName: flags == [.pick] ? "flag.fill" : "flag")
            }
            .accessibilityLabel(AccessibleName.pick)
            .help("Pick (P)")
            Button { AppCommand.command(.reject).perform(ctx) } label: {
                Image(systemName: flags == [.reject] ? "xmark.circle.fill" : "xmark.circle")
            }
            .accessibilityLabel(AccessibleName.reject)
            .help("Reject (X)")
            Button { AppCommand.command(.unflag).perform(ctx) } label: {
                Image(systemName: "flag.slash")
            }
            .accessibilityLabel(AccessibleName.unflag)
            .help("Unflag (U)")
            HStack(spacing: 0) {
                ForEach(1...Marks.maxRating, id: \.self) { n in
                    Button {
                        let clear = ratings == [n]
                        AppCommand.command(AppCommand.rateNames[clear ? 0 : n]).perform(ctx)
                    } label: {
                        Image(systemName: ratings.count == 1 && n <= ratings.first! ? "star.fill" : "star")
                    }
                    .accessibilityLabel(AccessibleName.stars(n))
                    .help("\(n) star\(n == 1 ? "" : "s") (\(n))")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(targets.isEmpty)
    }
}

/// The grid cell's right-click menu. A right-click outside the selection acts
/// on that photo alone, inside it on the batch targets
/// (`Library.contextTargets(for:)`).
struct PhotoContextMenu: View {
    @Environment(Library.self) private var library
    @Environment(PresetLibrary.self) private var presets
    @Environment(ExportQueue.self) private var exports
    let photo: Photo

    private func item(_ ctx: CommandContext, _ name: AppCommand.Name) -> some View {
        let command = AppCommand.command(name)
        return Button(command.title) { command.perform(ctx) }
            .disabled(!command.isEnabled(ctx))
    }

    var body: some View {
        let targets = library.contextTargets(for: photo.id)
        let ctx = CommandContext(library: library, presets: presets, exports: exports,
                                 targetIDs: targets, subjectID: photo.id)
        item(ctx, .pick)
        item(ctx, .reject)
        item(ctx, .unflag)
        Menu("Rating") {
            ForEach(0...Marks.maxRating, id: \.self) { n in item(ctx, AppCommand.rateNames[n]) }
        }
        item(ctx, .keywords)
        Menu("Apply Preset") {
            ForEach(presets.presets) { preset in
                Button(preset.name) { library.apply(preset, to: targets) }
            }
        }
        .disabled(presets.presets.isEmpty || targets.isEmpty)
        Divider()
        item(ctx, .copySettings)
        item(ctx, .pasteSettings)
        item(ctx, .export)
        item(ctx, .resetPhoto)
        item(ctx, .createVirtualCopy)
        item(ctx, .removeVirtualCopy)
        if let url = photo.fileURL {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
