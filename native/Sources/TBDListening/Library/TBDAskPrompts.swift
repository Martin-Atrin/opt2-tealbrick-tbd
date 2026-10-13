import TBDSpeech

/// Meeting Ask quick prompts from the library (Prompts page → Live Ask). Without a library the
/// shipped lists are used so Ask still works.
enum TBDAskPrompts {
    /// Every visible quick prompt, for the empty Ask state.
    static func starters(_ database: TBDListeningDatabase?) -> [TBDQuickPrompt] {
        guard let database, let items = try? database.visibleQuickPrompts() else { return TBDQuickPrompt.starters + TBDQuickPrompt.followUps }
        return items.map(\.asQuickPrompt)
    }

    /// Visible pinned quick prompts, for the strip after each answer.
    static func followUps(_ database: TBDListeningDatabase?) -> [TBDQuickPrompt] {
        guard let database, let items = try? database.pinnedQuickPrompts() else { return TBDQuickPrompt.followUps }
        return items.map(\.asQuickPrompt)
    }
}
