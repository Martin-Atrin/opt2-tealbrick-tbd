import SwiftUI
import TBDDesign
import TBDSpeech

// Label screens (v1 MeetingClassificationControls): badges on rows, the label editor on a transcript, the label
// filter for the Meetings list, the manage-labels sheet, and aiming a prompt at labels.

enum TBDLabelTint {
    /// Kit tones for the marks (dots) of a label. Fills only; label names are always set in ink.
    private static let palette: [Color] = [TBDColor.toneTeal, TBDColor.toneMoss, TBDColor.toneWood, TBDColor.toneBrick, TBDColor.toneStone, TBDColor.inkSoft]

    static func color(for label: TBDMeetingLabel) -> Color {
        switch TBDLabelColor(token: label.colorToken) {
        case .coral: TBDColor.toneTeal
        case .green: TBDColor.toneMoss
        case .amber: TBDColor.toneWood
        case .red: TBDColor.toneBrick
        case .purple: TBDColor.inkSoft
        case .blue: TBDColor.toneStone
        case .automatic: palette[TBDLabelColor.automaticSlot(for: label.id, paletteCount: palette.count)]
        }
    }

    static func color(_ option: TBDLabelColor, for label: TBDMeetingLabel) -> Color {
        var copy = label
        copy.colorToken = option.token
        return color(for: copy)
    }
}

/// Runs a database change and refreshes the lists; returns the error text, if any.
@MainActor
private func tbdLabelChange(_ env: TBDListeningEnvironment, _ body: (TBDListeningDatabase) throws -> Void) -> String? {
    guard let database = env.database else { return env.databaseError ?? "Library unavailable" }
    do { try body(database); env.changed(); return nil } catch { return error.localizedDescription }
}

/// One label as a small colored tag.
struct TBDLabelTag: View {
    let label: TBDMeetingLabel
    var body: some View {
        // A pill chip: the label colour is the dot, the name stays ink (readable in light and dark).
        TBDChip(label.name, color: TBDLabelTint.color(for: label)).lineLimit(1)
    }
}

/// The labels of one transcript on a list row: the first two, then "+N".
struct TBDLabelBadges: View {
    let transcriptionID: String
    var maximum = 2
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var labels: [TBDMeetingLabel] = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(maximum)) { TBDLabelTag(label: $0) }
            if labels.count > maximum { Text("+\(labels.count - maximum)").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted) }
        }
        .task(id: env.revision) { labels = (try? env.database?.labels(for: transcriptionID)) ?? [] }
    }
}

/// Header of a transcript: its labels and the button that edits them.
struct TBDTranscriptLabelsBar: View {
    let transcriptionID: String
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var labels: [TBDMeetingLabel] = []
    @State private var editing = false
    @State private var managing = false

    var body: some View {
        HStack(spacing: TBDTokens.Space.xs) {
            ForEach(labels) { TBDLabelTag(label: $0) }
            Button { editing = true } label: { Label(labels.isEmpty ? "Add label" : "Labels", systemImage: "tag") }
                .buttonStyle(TBDButtonStyle(.quiet)).help("Label this transcript")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    TBDLabelEditor(transcriptionID: transcriptionID) { editing = false; managing = true }
                }
        }
        .task(id: env.revision) { labels = (try? env.database?.labels(for: transcriptionID)) ?? [] }
        .sheet(isPresented: $managing) { TBDLabelManagementSheet().frame(width: 460, height: 520) }
    }
}

/// Popover: search, tick labels on or off, create a label from the search text.
struct TBDLabelEditor: View {
    let transcriptionID: String
    let onManage: () -> Void
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var query = ""
    @State private var choices: [TBDMeetingLabel] = []
    @State private var assigned: Set<String> = []
    @State private var error: String?

    private var shown: [TBDMeetingLabel] { TBDLabelRules.matching(query, in: choices) }
    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var exact: TBDMeetingLabel? { choices.first { $0.name.compare(typed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Labels")
            TextField("Search or create a label", text: $query).tbdField().onSubmit(commit)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { label in
                        Button { toggle(label) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(TBDLabelTint.color(for: label)).frame(width: 8, height: 8)
                                Text(label.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if assigned.contains(label.id) { Image(systemName: "checkmark").font(TBDFonts.symbol(10, TBDKit.weightNav)) }
                            }
                            .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
                            .padding(.horizontal, 7).padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !typed.isEmpty, exact == nil {
                        Button { commit() } label: { Label("Create “\(typed)”", systemImage: "plus") }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                    if shown.isEmpty, typed.isEmpty { Text("No labels yet. Type a name to create one.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
                }
            }
            .frame(maxHeight: 220)
            Button("Manage labels…", action: onManage).buttonStyle(TBDButtonStyle(.quiet))
            if let error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
        }
        .padding(TBDTokens.Space.md).frame(width: 300)
        .task(id: env.revision) { reload() }
    }

    private func reload() {
        choices = (try? env.database?.meetingLabels()) ?? []
        assigned = (try? env.database?.labelIDs(for: transcriptionID)) ?? []
    }

    private func toggle(_ label: TBDMeetingLabel) {
        error = tbdLabelChange(env) { try $0.toggleLabel(label.id, for: transcriptionID) }
    }

    /// Return: tick the label with that name, or create it and tick it.
    private func commit() {
        guard !typed.isEmpty else { return }
        if let exact {
            if !assigned.contains(exact.id) { toggle(exact) }
        } else {
            error = tbdLabelChange(env) { database in
                let label = try database.createMeetingLabel(name: typed)
                try database.toggleLabel(label.id, for: transcriptionID)
            }
        }
        if error == nil { query = "" }
    }
}

/// "Labels · N" button for the list: show only transcripts that carry ANY of the ticked labels.
struct TBDLabelFilterBar: View {
    @Binding var selection: Set<String>
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var labels: [TBDMeetingLabel] = []
    @State private var open = false
    @State private var managing = false

    var body: some View {
        HStack(spacing: TBDTokens.Space.sm) {
            Button { open = true } label: { Label(selection.isEmpty ? "Labels" : "Labels · \(selection.count)", systemImage: "tag") }
                .buttonStyle(TBDButtonStyle(.secondary))
                .popover(isPresented: $open, arrowEdge: .bottom) { popover }
            if !selection.isEmpty { Button("Clear") { selection = [] }.buttonStyle(TBDButtonStyle(.quiet)) }
            Spacer()
        }
        .task(id: env.revision) {
            labels = (try? env.database?.meetingLabels()) ?? []
            // A label that was archived or deleted can no longer be filtered on.
            selection.formIntersection(labels.map(\.id))
        }
        .sheet(isPresented: $managing) { TBDLabelManagementSheet().frame(width: 460, height: 520) }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            if labels.isEmpty {
                Text("No labels yet").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                Text("Create labels to group meetings and filter your library.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            } else {
                Text("Match any selected label").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(labels) { label in
                            Button {
                                if !selection.insert(label.id).inserted { selection.remove(label.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(TBDLabelTint.color(for: label)).frame(width: 8, height: 8)
                                    Text(label.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: selection.contains(label.id) ? "checkmark" : "circle").font(TBDFonts.symbol(10, TBDKit.weightNav))
                                }
                                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
                                .padding(.horizontal, 7).padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            Button("Manage labels…") { open = false; managing = true }.buttonStyle(TBDButtonStyle(.quiet))
        }
        .padding(TBDTokens.Space.md).frame(width: 280)
    }
}

/// Create, rename, color, archive or restore, and delete labels.
struct TBDLabelManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var query = ""
    @State private var labels: [TBDMeetingLabel] = []
    @State private var counts: [String: Int] = [:]
    @State private var newName = ""
    @State private var renaming: TBDMeetingLabel?
    @State private var renameText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage labels").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                    Text("Rename and color labels across your library.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(TBDButtonStyle(.secondary))
            }
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("New label", text: $newName).tbdField().onSubmit(create)
                Button("Add") { create() }.buttonStyle(TBDButtonStyle(.primary)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Search labels", text: $query).tbdField()
            if let error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    let shown = TBDLabelRules.matching(query, in: labels)
                    if shown.isEmpty {
                        Text(query.isEmpty ? "No labels yet." : "No labels match “\(query)”.").foregroundStyle(TBDColor.muted)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(shown) { label in row(label); Divider() }
                }
            }
        }
        .padding(TBDTokens.Space.xl).background(TBDColor.paper)
        .task(id: env.revision) { reload() }
        .sheet(item: $renaming) { label in
            VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
                Text("Rename label").font(TBDTokens.Typography.title)
                TextField("Label name", text: $renameText).tbdField().onSubmit { saveRename(label) }
                HStack {
                    Button("Cancel") { renaming = nil }.buttonStyle(TBDButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { saveRename(label) }.buttonStyle(TBDButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(TBDTokens.Space.xl).frame(width: 360).background(TBDColor.paper)
        }
    }

    private func row(_ label: TBDMeetingLabel) -> some View {
        let uses = counts[label.id] ?? 0
        return HStack(spacing: TBDTokens.Space.sm) {
            Circle().fill(TBDLabelTint.color(for: label)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.name).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).lineLimit(1)
                Text((label.isArchived ? "Archived · " : "") + "\(uses) transcript\(uses == 1 ? "" : "s")")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            Spacer()
            Menu {
                Button("Rename…") { renameText = label.name; renaming = label }
                Menu("Color") {
                    ForEach(TBDLabelColor.allCases) { option in
                        Button {
                            error = tbdLabelChange(env) { try $0.setMeetingLabelColor(id: label.id, token: option.token) }
                        } label: {
                            Text(option.title + (option == TBDLabelColor(token: label.colorToken) ? "  ✓" : ""))
                        }
                    }
                }
                Divider()
                Button(label.isArchived ? "Restore" : "Archive") {
                    error = tbdLabelChange(env) { try $0.setMeetingLabelArchived(id: label.id, isArchived: !label.isArchived) }
                }
                Button("Delete") { error = tbdLabelChange(env) { try $0.deleteMeetingLabel(id: label.id) } }.disabled(uses > 0)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Archive keeps the label on transcripts and prompt rules. Delete needs a label that is on no transcript.")
        }
        .padding(.vertical, 8)
    }

    private func reload() {
        labels = (try? env.database?.meetingLabels(includeArchived: true)) ?? []
        counts = (try? env.database?.meetingLabelUseCounts()) ?? [:]
    }

    private func create() {
        error = tbdLabelChange(env) { _ = try $0.createMeetingLabel(name: newName) }
        if error == nil { newName = "" }
    }

    private func saveRename(_ label: TBDMeetingLabel) {
        error = tbdLabelChange(env) { try $0.renameMeetingLabel(id: label.id, to: renameText) }
        if error == nil { renaming = nil }
    }
}

/// In the prompt editor: aim a transcript prompt at labels. No label ticked: offered for every transcript.
struct TBDPromptLabelTargets: View {
    let promptID: String
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var labels: [TBDMeetingLabel] = []
    @State private var targets: Set<String> = []
    @State private var error: String?

    var body: some View {
        TBDSettingsRow("Offer for labels", help: targets.isEmpty ? "Offered for every transcript. Tick labels to offer it only for transcripts with one of them."
                       : "Offered only for transcripts that carry one of the ticked labels (and auto-run only for those).") {
            VStack(alignment: .trailing, spacing: TBDTokens.Space.xs) {
                if labels.isEmpty { Text("No labels yet").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
                TBDFlowRow(spacing: 4) {
                    ForEach(labels) { label in
                        Toggle(label.name, isOn: Binding(get: { targets.contains(label.id) }, set: { on in
                            var next = targets
                            if on { next.insert(label.id) } else { next.remove(label.id) }
                            error = tbdLabelChange(env) { try $0.setTargetLabels(next, promptId: promptID) }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
                if let error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            }
            .frame(maxWidth: 360, alignment: .trailing)
        }
        .task(id: "\(promptID)|\(env.revision)") {
            // Archived labels stay listed while a rule still points at them.
            let current = (try? env.database?.targetLabelIDs(promptId: promptID)) ?? []
            targets = current
            labels = ((try? env.database?.meetingLabels(includeArchived: true)) ?? []).filter { !$0.isArchived || current.contains($0.id) }
        }
    }
}
