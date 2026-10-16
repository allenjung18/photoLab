import SwiftUI
import AppKit

/// Import from Card… (⇧⌘I): the cards (`CardVolumes`, with Refresh) and
/// Choose Folder… for any other folder; the destination root with Change…;
/// how many photos are new, how many already imported and how many other
/// files are skipped (`ImportPlan`); then the run's progress with Cancel,
/// and when it ends Eject (a card only, never automatic) and Open (the
/// import's common folder through `Library.open`).
struct ImportSheet: View {
    @Environment(Importer.self) private var imports
    @Environment(Library.self) private var library
    @Environment(PresetLibrary.self) private var presets

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Photos").font(.title3.weight(.semibold))
            switch imports.state {
            case .idle:
                sourceSection
                destinationSection
                developSection
                summary
            case .running:
                progress
            case .finished, .cancelled:
                result
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(imports.isRunning)
    }

    // MARK: Before the run

    private var sourceSection: some View {
        GroupBox("From") {
            VStack(alignment: .leading, spacing: 8) {
                if !imports.listingDone {
                    ProgressView().controlSize(.small)
                } else if imports.listing.cards.isEmpty {
                    Text("No card with a DCIM folder is mounted.")
                        .foregroundStyle(.secondary)
                }
                ForEach(imports.listing.cards) { card in
                    Button {
                        imports.choose(.card(card))
                    } label: {
                        HStack {
                            Image(systemName: imports.source == .card(card) ? "largecircle.fill.circle" : "circle")
                            Image(systemName: "sdcard")
                            Text(card.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(imports.listing.unreadable, id: \.name) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Can't read “\(volume.name)”: \(volume.message)")
                            .font(.caption).foregroundStyle(.red)
                        if volume.isPermission {
                            Button("Open System Settings") { ImportPanel.openPrivacySettings() }
                                .help("Privacy & Security › Files and Folders: allow PhotoLab Removable Volumes")
                        }
                    }
                }
                if case .folder(let url)? = imports.source {
                    HStack {
                        Image(systemName: "largecircle.fill.circle")
                        Image(systemName: "folder")
                        Text(url.path).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button("Refresh") { Task { await imports.refresh() } }
                        .help("List the mounted cards again")
                    Button("Choose Folder…") {
                        if let url = ImportPanel.chooseSource() { imports.choose(.folder(url)) }
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var destinationSection: some View {
        GroupBox("Into") {
            HStack {
                Text(imports.root.path).lineLimit(1).truncationMode(.middle)
                    .help("Photos go into YYYY/YYYY-MM-DD folders here, by capture date")
                Spacer()
                Button("Change…") {
                    if let url = ImportPanel.chooseRoot(from: imports.root) { imports.setRoot(url) }
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }

    private var developSection: some View {
        GroupBox("After import") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("After import", selection: Binding(get: { imports.develop.resolved(in: presets.presets).choice },
                                                          set: { imports.develop = $0 })) {
                    Text("None").tag(ImportDevelop.none)
                    Text("Auto").tag(ImportDevelop.auto)
                    ForEach(presets.presets) { Text($0.name).tag(ImportDevelop.preset($0.name)) }
                }
                .labelsHidden()
                .help("Applied to the photos this run copies when you press Open")
                if let note = imports.develop.resolved(in: presets.presets).note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// The Open button's title for the remembered choice.
    static func openTitle(_ develop: ImportDevelop) -> String {
        switch develop {
        case .none: return "Open"
        case .auto: return "Open and Auto"
        case .preset(let name): return "Open and Apply \(name)"
        }
    }

    @ViewBuilder private var summary: some View {
        if imports.planning {
            HStack { ProgressView().controlSize(.small); Text("Reading the photos…").foregroundStyle(.secondary) }
        } else if let plan = imports.plan {
            Text(Self.summaryLine(plan)).font(.callout)
        }
    }

    /// "n new · m already imported · k other files skipped".
    static func summaryLine(_ plan: ImportPlan) -> String {
        var parts = ["\(plan.copies.count) new", "\(plan.already.count) already imported"]
        if plan.otherFiles > 0 {
            parts.append("\(plan.otherFiles) other file\(plan.otherFiles == 1 ? "" : "s") skipped")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: The run

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(imports.completed), total: Double(max(1, imports.total)))
            HStack {
                Text("Importing \(min(imports.completed + 1, imports.total)) of \(imports.total)")
                    .font(.callout.monospacedDigit())
                if let current = imports.current {
                    Text(current.lastPathComponent)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            let clean = imports.failures.isEmpty && imports.state == .finished
            HStack {
                Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(clean ? .green : .orange)
                Text(resultLine).font(.callout)
            }
            ForEach(imports.failures.prefix(5)) { failure in
                Text("\(failure.source.lastPathComponent) — \(failure.message)")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            if imports.develop.resolved(in: presets.presets).choice != .none {
                Text("Done applies nothing: only Open applies the After import choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if imports.ejected, let name = imports.source?.displayName {
                Text("“\(name)” was ejected; it can be removed.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = imports.ejectError {
                Text("Can't eject: \(error)").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var resultLine: String {
        let already = imports.plan?.already.count ?? 0
        var s = imports.state == .cancelled
            ? "Cancelled: \(imports.done) of \(imports.total) imported"
            : "Imported \(imports.done) photo\(imports.done == 1 ? "" : "s")"
        if already > 0 { s += " · \(already) already imported" }
        if !imports.failures.isEmpty { s += " · \(imports.failures.count) failed" }
        return s
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        switch imports.state {
        case .idle:
            Button("Cancel") { imports.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import") { imports.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(imports.plan?.copies.isEmpty ?? true)
        case .running:
            Button("Cancel") { imports.cancel() }
                .help("Stop after the file being copied; what is copied stays")
        case .finished, .cancelled:
            if imports.source?.card != nil {
                Button("Eject") { imports.eject() }
                    .disabled(imports.ejected)
                    .help("Unmount and eject the card")
            }
            Button(Self.openTitle(imports.develop.resolved(in: presets.presets).choice)) {
                imports.open(in: library, presets: presets.presets)
            }
                .disabled(imports.openFolder == nil)
                .help("Open the imported photos' folder")
            Button("Done") { imports.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
