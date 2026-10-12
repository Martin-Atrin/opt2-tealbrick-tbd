import SwiftUI
import TBDDesign
import TBDSpeech

/// Searchable list of library items with the selected transcript beside it.
struct TBDLibraryView: View {
    let context: TBDListeningContext
    /// Restrict to one source kind (the Meetings tab), or nil for everything.
    let kind: TBDSourceKind?
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var query = ""
    @State private var filter: TBDSourceKind?
    @State private var items: [TBDTranscription] = []
    @State private var sort: TBDLibrarySort = .newest
    @State private var dictationMatches = 0

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
                }
                if kind == nil, dictationMatches > 0 {
                    Button("\(dictationMatches) dictation\(dictationMatches == 1 ? "" : "s") also match") {
                        env.dictationQuery = query
                        env.selectedTab = .dictations
                    }
                    .buttonStyle(TBDButtonStyle(.quiet))
                }
                if items.isEmpty {
                    Text(query.isEmpty ? "Nothing here yet. Drop a file, paste a link or record a meeting." : "No matches.")
                        .foregroundStyle(TBDTokens.muted).font(TBDTokens.Typography.body).padding(.top, TBDTokens.Space.lg)
                    Spacer()
                } else {
                    List(selection: $env.selectedTranscriptionID) {
                        if sort == .title {
                            ForEach(items) { item in TBDLibraryRow(item: item).tag(item.id) }
                        } else {
                            ForEach(Self.groups(items), id: \.0) { group, entries in
                                Section(group.title) { ForEach(entries) { item in TBDLibraryRow(item: item).tag(item.id) } }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 300)
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
        .task(id: "\(query)|\(String(describing: filter))|\(sort)|\(env.revision)") {
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            items = (try? env.database?.transcriptions(kind: kind ?? filter, matching: query, sort: sort)) ?? []
            dictationMatches = kind == nil ? ((try? env.database?.dictationMatchCount(query)) ?? 0) : 0
            if env.selectedTranscriptionID == nil || !items.contains(where: { $0.id == env.selectedTranscriptionID }) && kind != nil {
                env.selectedTranscriptionID = items.first?.id
            }
        }
    }
}

extension TBDLibraryView {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink).lineLimit(1)
            HStack(spacing: TBDTokens.Space.sm) {
                Text(item.sourceKind.label.uppercased()).font(TBDTokens.Typography.label).tracking(TBDTokens.Typography.labelTracking)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if item.durationMs > 0 { Text(TBDExport.clock(item.durationMs)) }
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
