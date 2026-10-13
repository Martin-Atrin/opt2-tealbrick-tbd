import SwiftUI
import TBDDesign
import TBDSpeech

/// Searchable list of library items with the selected transcript beside it.
struct TBDLibraryView: View {
    let context: TBDListeningContext
    /// Restrict to one source kind (the Meetings tab), or nil for everything.
    let kind: TBDSourceKind?
    /// Show only items that carry ANY of these labels (empty: everything).
    var labelFilter: Set<String> = []
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var query = ""
    @State private var filter: TBDSourceKind?
    @State private var items: [TBDTranscription] = []
    @State private var sort: TBDLibrarySort = .newest
    @State private var favoritesOnly = false
    @State private var dictationMatches = 0
    @StateObject private var bulk: TBDLibraryBulkModel
    @FocusState private var selectionFocus: Bool

    init(context: TBDListeningContext, kind: TBDSourceKind?, labelFilter: Set<String> = []) {
        self.context = context
        self.kind = kind
        self.labelFilter = labelFilter
        _bulk = StateObject(wrappedValue: TBDLibraryBulkModel(env: context.env))
    }

    /// The page the meetings stay on after "remove audio only".
    private var surface: String { kind == .meeting ? "Meetings" : "Library" }

    var body: some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
            VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TBDTokens.muted)
                    TextField("Search transcripts", text: $query).textFieldStyle(.plain)
                }
                .tbdField()
                HStack(spacing: TBDTokens.Space.sm) {
                    if kind == nil {
                        Picker("Show", selection: $filter) {
                            Text("All").tag(TBDSourceKind?.none)
                            ForEach(TBDSourceKind.allCases, id: \.self) { Text($0.label).tag(TBDSourceKind?.some($0)) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(TBDLibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    Toggle(isOn: $favoritesOnly) { Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star") }
                        .toggleStyle(.button).help("Show only favorites")
                    Spacer(minLength: 0)
                    if !bulk.selection.isActive, !items.isEmpty {
                        Button { bulk.selection.begin() } label: { Label("Select", systemImage: "checklist") }
                            .buttonStyle(TBDButtonStyle(.quiet)).help("Select several items to export or delete")
                    }
                }
                if let message = bulk.message {
                    HStack(alignment: .top, spacing: TBDTokens.Space.sm) {
                        Text(message).font(.system(size: 12)).foregroundStyle(TBDTokens.alert).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { bulk.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Dismiss message")
                    }
                }
                if bulk.selection.isActive { selectionBar }
                if kind == nil, dictationMatches > 0 {
                    Button("\(dictationMatches) dictation\(dictationMatches == 1 ? "" : "s") also match") {
                        env.dictationQuery = query
                        env.selectedTab = .dictations
                    }
                    .buttonStyle(TBDButtonStyle(.quiet))
                }
                if items.isEmpty {
                    Text(!query.isEmpty || favoritesOnly ? "No matches." : "Nothing here yet. Drop a file, paste a link or record a meeting.")
                        .foregroundStyle(TBDTokens.muted).font(TBDTokens.Typography.body).padding(.top, TBDTokens.Space.lg)
                    Spacer()
                } else {
                    if bulk.selection.isActive {
                        List { rows }.listStyle(.inset).scrollContentBackground(.hidden)
                    } else {
                        List(selection: $env.selectedTranscriptionID) { rows }.listStyle(.inset).scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(width: 300)
            .focusable(bulk.selection.isActive)
            .focused($selectionFocus)
            .focusEffectDisabled()
            .onChange(of: bulk.selection.isActive) { _, active in if active { selectionFocus = true } }
            .onKeyPress(keys: [.delete, .deleteForward, "a", "A"]) { press in handleKey(press) }
            Rectangle().fill(TBDTokens.border).frame(width: TBDTokens.Stroke.hairline)
            Group {
                if let id = env.selectedTranscriptionID, items.contains(where: { $0.id == id }) || kind == nil {
                    TBDTranscriptDetailView(context: context, id: id).id(id)
                } else {
                    Text("Select a transcript").foregroundStyle(TBDTokens.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: items.map(\.id)) { _, ids in bulk.selection.prune(to: Set(ids)) }
        .onDisappear { bulk.cancelExport() }
        .alert(pendingDeleteTitle, isPresented: Binding(get: { bulk.pendingDelete != nil }, set: { if !$0 { bulk.pendingDelete = nil } }),
               presenting: bulk.pendingDelete) { targets in
            Button("Cancel", role: .cancel) {}
            Button(pendingDeleteConfirm(targets), role: .destructive) { bulk.confirmDelete(targets) }
        } message: { targets in
            Text(targets.count == 1 ? TBDBulkDeletePlan.single(targets[0]).message : TBDBulkDeletePlan(targets).message)
        }
        .alert(TBDBulkAudioPlan.title, isPresented: Binding(get: { bulk.pendingAudio != nil }, set: { if !$0 { bulk.pendingAudio = nil } }),
               presenting: bulk.pendingAudio) { request in
            Button("Cancel", role: .cancel) {}
            Button(TBDBulkAudioPlan.confirmTitle, role: .destructive) { bulk.confirmRemoveAudio(request) }
        } message: { request in
            Text(request.targets.count == 1 && request.skipped == 0
                 ? TBDBulkAudioPlan.single(request.targets[0], surface: surface)
                 : TBDBulkAudioPlan(request.targets, skipped: request.skipped, surface: surface).message)
        }
        .task(id: "\(query)|\(String(describing: filter))|\(sort)|\(favoritesOnly)|\(env.revision)|\(labelFilter.sorted())") {
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            items = (try? env.database?.transcriptions(kind: kind ?? filter, matching: query, favoritesOnly: favoritesOnly, sort: sort)) ?? []
            if let labelled = try? env.database?.transcriptionIDs(withAnyLabel: labelFilter) { items = items.filter { labelled.contains($0.id) } }
            dictationMatches = kind == nil ? ((try? env.database?.dictationMatchCount(query)) ?? 0) : 0
            if env.selectedTranscriptionID == nil || !items.contains(where: { $0.id == env.selectedTranscriptionID }) && kind != nil {
                env.selectedTranscriptionID = items.first?.id
            }
        }
    }
}

extension TBDLibraryView {
    @ViewBuilder
    private var rows: some View {
        if sort == .title {
            ForEach(items) { row($0) }
        } else {
            ForEach(Self.groups(items), id: \.0) { group, entries in
                Section(group.title) { ForEach(entries) { row($0) } }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TBDTranscription) -> some View {
        if bulk.selection.isActive {
            TBDLibraryRow(item: item, ticked: bulk.selection.contains(item.id))
                .contentShape(Rectangle())
                .onTapGesture { if !bulk.isBusy { bulk.selection.toggle(item.id) } }
                .contextMenu { menu(item) }
        } else {
            TBDLibraryRow(item: item).tag(item.id).contextMenu { menu(item) }
        }
    }

    @ViewBuilder
    private func menu(_ item: TBDTranscription) -> some View {
        if !bulk.selection.isActive {
            Button("Open") { env.selectedTranscriptionID = item.id }
            Button("Select Many…") { bulk.selection.begin(startingWith: item.id) }
            Divider()
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") { bulk.toggleFavorite(item) }
        if TBDRetentionSweeper.hasRemovableAudio(item) {
            Button("Remove Audio Only…") { bulk.requestRemoveAudio([item]) }.disabled(bulk.isBusy)
        }
        Divider()
        Button(item.sourceKind == .meeting ? "Delete Meeting…" : "Delete…", role: .destructive) { bulk.requestDelete([item]) }
            .disabled(bulk.isBusy)
    }

    private var pendingDeleteTitle: String {
        guard let targets = bulk.pendingDelete else { return "Delete?" }
        return targets.count == 1 ? TBDBulkDeletePlan.single(targets[0]).title : TBDBulkDeletePlan(targets).title
    }

    private func pendingDeleteConfirm(_ targets: [TBDTranscription]) -> String {
        targets.count == 1 ? TBDBulkDeletePlan.single(targets[0]).confirm : TBDBulkDeletePlan(targets).confirmTitle
    }

    private var selected: [TBDTranscription] { bulk.selection.selected(in: items) }

    /// Count, Select All, Clear, Export…, Remove Audio Only…, Delete… (v1 selection bar).
    private var selectionBar: some View {
        let chosen = selected
        let withAudio = chosen.filter { TBDRetentionSweeper.hasRemovableAudio($0) }
        let meetings = chosen.filter { $0.sourceKind == .meeting }
        let ids = items.map(\.id)
        return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            HStack(spacing: TBDTokens.Space.sm) {
                if let working = bulk.working { ProgressView().controlSize(.small); Text(working) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(TBDTokens.accent); Text("\(chosen.count) selected") }
            }
            .font(TBDTokens.Typography.control)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                Button("Cancel") { bulk.selection.exit() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(bulk.isBusy)
                Button("Select All") { bulk.selection.selectAll(ids) }
                    .disabled(bulk.isBusy || bulk.selection.areAllSelected(ids))
                Button("Clear") { bulk.selection.clear() }.disabled(bulk.isBusy || chosen.isEmpty)
                Button("Export…") { bulk.showExportOptions = true }.disabled(bulk.isBusy || chosen.isEmpty)
                    .popover(isPresented: $bulk.showExportOptions, arrowEdge: .bottom) { exportPanel(chosen) }
                if kind == .meeting || !withAudio.isEmpty {
                    Button("Remove Audio Only…") { bulk.requestRemoveAudio(withAudio, skipped: meetings.count - withAudio.count) }
                        .disabled(bulk.isBusy || withAudio.isEmpty)
                }
                Button("Delete…", role: .destructive) { bulk.requestDelete(chosen) }.disabled(bulk.isBusy || chosen.isEmpty)
            }
            .buttonStyle(TBDButtonStyle(.secondary))
        }
        .padding(TBDTokens.Space.sm)
        .background(TBDTokens.selected.opacity(0.5))
        .overlay(alignment: .bottom) { Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline) }
        .popover(item: $bulk.exportResult, arrowEdge: .bottom) { result in exportResultView(result) }
    }

    private func exportPanel(_ chosen: [TBDTranscription]) -> some View {
        TBDExportPanel(title: "Export Selected", subtitle: "\(chosen.count) \(chosen.count == 1 ? "item" : "items")",
                       format: $bulk.exportFormat, options: $bulk.exportOptions, forBatch: true,
                       actionTitle: "Choose Folder…", actionIcon: "folder", actionDisabled: bulk.isBusy || chosen.isEmpty,
                       onAction: { bulk.exportSelected(chosen) }, onClose: { bulk.showExportOptions = false })
    }

    private func exportResultView(_ result: TBDBulkExportResult) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            Label(result.title, systemImage: result.isCompleteSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(TBDTokens.Typography.control)
            Text(result.directory.lastPathComponent).font(.system(size: 11)).foregroundStyle(TBDTokens.muted).lineLimit(1)
            if result.failedCount > 0 {
                Text("\(result.failedCount) \(result.failedCount == 1 ? "file" : "files") failed.").font(.system(size: 12)).foregroundStyle(TBDTokens.alert)
                ForEach(result.failureLines.prefix(5), id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(TBDTokens.muted) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.exportedURLs); bulk.exportResult = nil }
                .buttonStyle(TBDButtonStyle(.secondary))
        }
        .padding(TBDTokens.Space.md).frame(minWidth: 260)
    }

    /// Delete / Backspace deletes the ticked rows (after confirming); Command-A ticks all listed rows.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard bulk.selection.isActive, !bulk.isBusy else { return .ignored }
        if press.key == .delete || press.key == .deleteForward {
            let chosen = selected
            guard !chosen.isEmpty else { return .ignored }
            bulk.requestDelete(chosen)
            return .handled
        }
        if (press.key == "a" || press.key == "A"), press.modifiers.contains(.command) {
            bulk.selection.selectAll(items.map(\.id))
            return .handled
        }
        return .ignored
    }

    /// Date sections (Today, Yesterday, Previous 7 / 30 days, months), keeping the list order inside each.
    static func groups(_ items: [TBDTranscription]) -> [(TBDDateGroup, [TBDTranscription])] {
        var order: [TBDDateGroup] = []
        var buckets: [TBDDateGroup: [TBDTranscription]] = [:]
        let now = Date()
        for item in items {
            let group = TBDDateGroup.of(item.createdAt, now: now)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(item)
        }
        return order.sorted().map { ($0, buckets[$0] ?? []) }
    }
}

struct TBDLibraryRow: View {
    let item: TBDTranscription
    /// Selection mode: a checkbox shows, ticked or not. Nil outside selection mode.
    var ticked: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.sm) {
            if let ticked {
                Image(systemName: ticked ? "checkmark.square.fill" : "square").foregroundStyle(ticked ? TBDTokens.accent : TBDTokens.muted)
                    .accessibilityLabel(ticked ? "Selected" : "Not selected")
            }
            details
            Spacer(minLength: 0)
            if item.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(TBDTokens.accent).help("Favorite").accessibilityLabel("Favorite")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink).lineLimit(1)
            HStack(spacing: TBDTokens.Space.sm) {
                Text(item.sourceKind.label.uppercased()).font(TBDTokens.Typography.label).tracking(TBDTokens.Typography.labelTracking)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if item.durationMs > 0 { Text(TBDExport.clock(item.durationMs)) }
                TBDLabelBadges(transcriptionID: item.id)
                switch item.status {
                case .processing: Text("Processing").foregroundStyle(TBDTokens.accent)
                case .failed: Text("Failed").foregroundStyle(TBDTokens.alert)
                case .cancelled: Text("Cancelled")
                case .completed: EmptyView()
                }
            }
            .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
        }
        .padding(.vertical, 3)
    }
}
