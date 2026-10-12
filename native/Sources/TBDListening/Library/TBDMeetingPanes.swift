import SwiftUI
import TBDDesign
import TBDSpeech

/// Plain-text notes with `/action`, `/decision` and `/now` commands, a word count and save state.
struct TBDNotesEditor: View {
    @Binding var text: String
    /// Recording time for `/now`, or nil after the meeting (stamps then use 0:00).
    var elapsedMs: () -> Int = { 0 }
    var status: String?
    var placeholder = "Take notes while you record…"
    var footnote = "Saved with the meeting. Stays on this Mac."

    var body: some View {
        let suggestions = TBDNotesCommands.suggestions(for: text)
        let words = text.split(whereSeparator: \.isWhitespace).count
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(TBDTokens.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(TBDTokens.Space.xs)
                if text.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(placeholder).foregroundStyle(TBDTokens.muted)
                        Text("Type / for Action, Decision or Timestamp.").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
                    }
                    .padding(.horizontal, TBDTokens.Space.sm).padding(.vertical, TBDTokens.Space.sm)
                    .allowsHitTesting(false)
                }
            }
            .background(TBDTokens.paper, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm).strokeBorder(TBDTokens.border))
            if !suggestions.isEmpty {
                HStack(spacing: TBDTokens.Space.sm) {
                    ForEach(suggestions) { command in
                        Button(command.title) { text = TBDNotesCommands.apply(command, to: text, elapsedMs: elapsedMs()) }
                            .buttonStyle(TBDButtonStyle(.quiet)).help(command.help)
                    }
                }
                .transition(.opacity)
            }
            HStack {
                Text(footnote)
                Spacer()
                if words >= TBDNotesCommands.softCapWords {
                    Text("Prompts may trim notes past ~8,000 words.").foregroundStyle(TBDTokens.alert)
                }
                if let status { Text(status) }
                Text("\(words) word\(words == 1 ? "" : "s")")
            }
            .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
        }
        .animation(TBDMotion.instant, value: suggestions)
    }
}

/// Conversation over a transcript: starters, streamed answers, follow-ups, saved history.
struct TBDAskView: View {
    @ObservedObject var model: TBDAskModel
    var starters: [TBDQuickPrompt] = TBDQuickPrompt.starters
    var placeholder = "Ask about the meeting…"
    var showsHistory = true

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            if !model.available {
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    Text("Turn on AI for Ask").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
                    Text("Assign a model to the Analysis route in Settings → Models. Questions go only to that model.")
                        .font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
                }
                .tbdCard(padding: TBDTokens.Space.md)
            }
            if showsHistory, model.conversations.count > 0 || !model.lines.isEmpty {
                HStack(spacing: TBDTokens.Space.sm) {
                    if model.conversations.count > 1 {
                        Menu("Conversations") {
                            ForEach(model.conversations) { item in
                                Button(item.title.isEmpty ? "Chat" : item.title) { model.select(item) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    Button { model.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                        .buttonStyle(TBDButtonStyle(.quiet)).disabled(model.lines.isEmpty)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
                        if model.lines.isEmpty {
                            Text("Start with a quick prompt, then keep drilling down.").foregroundStyle(TBDTokens.muted)
                                .font(TBDTokens.Typography.body)
                            prompts(starters, grouped: true)
                        }
                        ForEach(model.lines) { line in
                            bubble(line).id(line.id)
                        }
                        if !model.lines.isEmpty, !model.streaming {
                            prompts(TBDQuickPrompt.followUps, grouped: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.lines.last?.text) { _, _ in
                    if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(TBDTokens.alert) }
            HStack(spacing: TBDTokens.Space.sm) {
                TextField(placeholder, text: $model.input).onSubmit { model.send() }.tbdField()
                if model.streaming {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(TBDButtonStyle(.icon)).help("Stop").accessibilityLabel("Stop answer")
                } else {
                    Button("Ask") { model.send() }.buttonStyle(TBDButtonStyle(.secondary))
                        .disabled(!model.available || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder private func prompts(_ items: [TBDQuickPrompt], grouped: Bool) -> some View {
        let groups = grouped ? Dictionary(grouping: items, by: { $0.group ?? "" }) : ["": items]
        let order = grouped ? items.compactMap(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } : [""]
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            ForEach(order.isEmpty ? [""] : order, id: \.self) { group in
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    if !group.isEmpty { TBDLabel(group) }
                    TBDFlowRow(spacing: TBDTokens.Space.xs) {
                        ForEach(groups[group] ?? []) { prompt in
                            Button(prompt.label) { model.send(prompt) }
                                .buttonStyle(TBDButtonStyle(.quiet)).disabled(!model.available || model.streaming)
                        }
                    }
                }
            }
        }
    }

    private func bubble(_ line: TBDAskModel.Line) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TBDLabel(line.role == .user ? "You" : "Answer")
            if line.streaming && line.text.isEmpty {
                ProgressView().controlSize(.small)
            } else if line.role == .assistant {
                Text(LocalizedStringKey(line.text)).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line.text).font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink).textSelection(.enabled)
            }
            if line.role == .assistant, !line.streaming {
                Button { TBDPasteService.copy(line.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(TBDButtonStyle(.quiet))
            }
        }
        .padding(.leading, line.role == .assistant ? TBDTokens.Space.md : 0)
    }
}

/// Wrapping row of small controls.
struct TBDFlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
