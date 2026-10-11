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

    var body: some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
            VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TBDTokens.muted)
                    TextField("Search transcripts", text: $query).textFieldStyle(.plain)
                }
                .tbdField()
                if kind == nil {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(TBDSourceKind?.none)
                        ForEach(TBDSourceKind.allCases, id: \.self) { Text($0.label).tag(TBDSourceKind?.some($0)) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                if items.isEmpty {
                    Text(query.isEmpty ? "Nothing here yet. Drop a file, paste a link or record a meeting." : "No matches.")
                        .foregroundStyle(TBDTokens.muted).font(TBDTokens.Typography.body).padding(.top, TBDTokens.Space.lg)
                    Spacer()
                } else {
                    List(items, selection: $env.selectedTranscriptionID) { item in
                        TBDLibraryRow(item: item).tag(item.id)
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
        .task(id: "\(query)|\(String(describing: filter))|\(env.revision)") {
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            items = (try? env.database?.transcriptions(kind: kind ?? filter, matching: query)) ?? []
            if env.selectedTranscriptionID == nil || !items.contains(where: { $0.id == env.selectedTranscriptionID }) && kind != nil {
                env.selectedTranscriptionID = items.first?.id
            }
        }
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
