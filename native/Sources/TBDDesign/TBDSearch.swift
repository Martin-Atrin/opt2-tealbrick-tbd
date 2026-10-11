import SwiftUI

/// Shared query dialog. The owning screen keeps its existing filtering and result actions.
public struct TBDSearchButton: View {
    @Binding private var query: String
    private let prompt: String
    private let openSignal: Bool
    @State private var presented = false
    public init(text: Binding<String>, prompt: String, openSignal: Bool = false) { _query = text; self.prompt = prompt; self.openSignal = openSignal }
    public var body: some View {
        HStack(spacing: 8) {
            Button { presented = true } label: {
                Label(query.isEmpty ? prompt : query, systemImage: "magnifyingglass")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(TBDActionStyle())
            .help(prompt)
            .keyboardShortcut("f", modifiers: .command)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .onChange(of: openSignal) { _, requested in if requested { presented = true } }
        .sheet(isPresented: $presented) { TBDSearchDialog(query: $query, prompt: prompt) }
    }
}
private struct TBDSearchDialog: View {
    @Binding var query: String
    let prompt: String
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(prompt).font(.custom("Switzer", size: 20).weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField(prompt, text: $draft).textFieldStyle(.plain)
                    .focused($focused).onSubmit(apply)
            }
            .padding(14).background(TBDTokens.paper, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border))
            HStack {
                Button("Clear") { draft = ""; focused = true }.buttonStyle(TBDActionStyle(subtle: true))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(TBDActionStyle())
                Button("Show results", action: apply).keyboardShortcut(.defaultAction).buttonStyle(TBDActionStyle(prominent: true))
            }
        }
        .padding(24).frame(width: 480)
        .background(TBDTokens.canvas)
        .onAppear { draft = query; focused = true }
    }
    private func apply() { query = draft.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
}
public extension View {
    func tbdSearchable(text: Binding<String>, prompt: String) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); TBDSearchButton(text: text, prompt: prompt) }
                .padding(.horizontal, 20).padding(.vertical, 10)
            self
        }
    }
}
