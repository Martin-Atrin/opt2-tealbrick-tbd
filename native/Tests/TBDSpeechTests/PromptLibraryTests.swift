import Foundation
import TBDModels
import XCTest
@testable import TBDSpeech

/// Records every request and answers with a fixed string (no network).
private final class FakeCompleter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TBDCompletionRequest] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    var requests: [TBDCompletionRequest] { lock.withLock { stored } }
    var complete: TBDCompleter {
        { [self] request in
            lock.withLock { stored.append(request) }
            return reply
        }
    }
}

final class PromptLibraryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var prefs: TBDListeningPreferences!

    override func setUpWithError() throws {
        suite = "tbd.tests.prompts.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        prefs = TBDListeningPreferences(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func library() throws -> TBDListeningDatabase {
        let db = try TBDListeningDatabase(inMemory: ())
        try db.preparePromptLibrary(preferences: prefs)
        return db
    }

    // MARK: Seeding

    func testBuiltInsAreSeededExactlyOnce() throws {
        let db = try library()
        try db.preparePromptLibrary(preferences: prefs)
        try db.preparePromptLibrary(preferences: prefs)
        let results = try db.prompts(category: .result)
        let transforms = try db.prompts(category: .transform)
        XCTAssertEqual(results.map(\.name), ["Summary", "Action Items & Decisions", "Chapter Breakdown", "Study Guide", "Blog Post", "What Stood Out"])
        XCTAssertEqual(transforms.map(\.name), ["Polish", "Distill", "Decide"])
        XCTAssertEqual(transforms.map(\.hotkey), ["ctrl+opt+1", "ctrl+opt+2", "ctrl+opt+3"])
        XCTAssertEqual(try db.quickPrompts().count, 14)
        XCTAssertEqual(try db.pinnedQuickPrompts().map(\.label), ["Tell me more", "Why?", "Give an example", "Counter-argument?", "TL;DR"])
        for prompt in results + transforms {
            XCTAssertEqual(try db.promptVersions(promptId: prompt.id).map(\.versionNumber), [1], prompt.name)
        }
        // The built-in Summary is byte-identical to the old default summary prompt setting.
        let summary = try XCTUnwrap(db.prompt(id: TBDPrompt.summaryID))
        XCTAssertEqual(summary.content, TBDListeningPreferences.defaultSummaryPrompt)
        XCTAssertTrue(summary.isAutoRun)
        XCTAssertEqual(try db.defaultSummaryPrompt()?.id, TBDPrompt.summaryID)
        // A deleted built-in is not re-seeded on the next launch.
        try db.deletePrompt(id: TBDPrompt.summaryID)
        try db.preparePromptLibrary(preferences: prefs)
        XCTAssertEqual(try db.prompts(category: .result).count, 5)
        XCTAssertEqual(try db.deletedPrompts().map(\.id), [TBDPrompt.summaryID])
        XCTAssertEqual(try db.defaultSummaryPrompt()?.name, "Action Items & Decisions")
    }

    // MARK: Versions

    func testEditingAUserPromptMakesANewVersionAndHistoryListsBoth() throws {
        let db = try library()
        let created = try db.savePrompt(TBDPrompt(name: "  Risks ", content: "List the risks."))
        XCTAssertEqual(created.name, "Risks")
        var edited = created
        edited.content = "List the risks with owners."
        let saved = try db.savePrompt(edited)
        let history = try db.promptVersions(promptId: created.id)
        XCTAssertEqual(history.map(\.versionNumber), [2, 1])
        XCTAssertEqual(history.map(\.content), ["List the risks with owners.", "List the risks."])
        XCTAssertEqual(saved.activeVersionId, history[0].id)
        XCTAssertEqual(try db.prompt(id: created.id)?.content, "List the risks with owners.")

        // Renaming is metadata: no new version.
        var renamed = saved
        renamed.name = "Risk register"
        try db.savePrompt(renamed)
        XCTAssertEqual(try db.promptVersions(promptId: created.id).count, 2)

        // Generation settings are part of the request: a new version.
        var tuned = try XCTUnwrap(db.prompt(id: created.id))
        tuned.inference = TBDPromptInference(temperature: 0.2, maxTokens: 800)
        try db.savePrompt(tuned)
        XCTAssertEqual(try db.promptVersions(promptId: created.id).first?.inference, TBDPromptInference(temperature: 0.2, maxTokens: 800))

        // Restoring version 1 adds version 4 with version 1's values.
        let restored = try db.restorePromptVersion(promptId: created.id, versionId: history[1].id)
        let afterRestore = try db.promptVersions(promptId: created.id)
        XCTAssertEqual(afterRestore.map(\.versionNumber), [4, 3, 2, 1])
        XCTAssertEqual(afterRestore[0].origin, .restore)
        XCTAssertEqual(afterRestore[0].content, "List the risks.")
        XCTAssertNil(afterRestore[0].inference)
        XCTAssertEqual(restored.content, "List the risks.")
        XCTAssertEqual(restored.name, "Risk register")

        // Bad cases.
        let other = try db.savePrompt(TBDPrompt(name: "Other", content: "x"))
        XCTAssertThrowsError(try db.restorePromptVersion(promptId: other.id, versionId: history[1].id)) {
            XCTAssertEqual($0 as? TBDPromptLibraryError, .versionBelongsToDifferentPrompt)
        }
        XCTAssertThrowsError(try db.savePrompt(TBDPrompt(name: "   ", content: "x"))) { XCTAssertEqual($0 as? TBDPromptLibraryError, .emptyName) }
        var hot = other
        hot.inference = TBDPromptInference(temperature: 2.5)
        XCTAssertThrowsError(try db.savePrompt(hot)) {
            XCTAssertEqual($0 as? TBDPromptInference.ValidationError, .outOfRange(field: "temperature", minimum: 0, maximum: 2))
        }
    }

    func testEditingABuiltInMarksItCustomisedAndResetRestoresTheShippedText() throws {
        let db = try library()
        var polish = try XCTUnwrap(db.prompt(id: "0fce9ddb-7e2d-4b1a-ae3e-6f7c9b2a4d11"))
        XCTAssertNil(polish.userCustomizedAt)
        polish.content = "Make it shorter."
        polish.hotkey = "f19"
        let saved = try db.savePrompt(polish)
        XCTAssertNotNil(saved.userCustomizedAt)
        let reset = try db.resetBuiltInPrompt(id: polish.id)
        XCTAssertEqual(reset.content, TBDPrompt.builtIn(id: polish.id)?.content)
        XCTAssertEqual(reset.hotkey, "ctrl+opt+1")
        XCTAssertNil(reset.userCustomizedAt)
        XCTAssertEqual(try db.promptVersions(promptId: polish.id).map(\.origin), [.systemUpdate, .user, .systemUpdate])
    }

    func testTrashRestoreRenamesWhenTheNameIsTaken() throws {
        let db = try library()
        let first = try db.savePrompt(TBDPrompt(name: "Notes", content: "a"))
        XCTAssertTrue(try db.deletePrompt(id: first.id))
        XCTAssertFalse(try db.deletePrompt(id: first.id), "already in the trash")
        XCTAssertNil(try db.prompt(id: first.id))
        try db.savePrompt(TBDPrompt(name: "notes", content: "b"))
        XCTAssertTrue(try db.restoreDeletedPrompt(id: first.id))
        XCTAssertEqual(try db.prompt(id: first.id)?.name, "Notes (Restored)")
        XCTAssertEqual(try db.promptVersions(promptId: first.id).count, 1, "history survives the trash")
    }

    // MARK: Auto-run

    func testPerSourceAutoRunFollowsTheEarlierRules() throws {
        let db = try library()
        let prompt = try db.savePrompt(TBDPrompt(name: "Recap", content: "Recap it."))
        try db.setPromptAutoRun(id: prompt.id, source: .meeting, enabled: true)
        XCTAssertEqual(try db.prompt(id: prompt.id)?.appliesToSources, [.meeting])
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting).map(\.name), ["Summary", "Recap"])
        XCTAssertEqual(try db.autoRunPrompts(for: .file).map(\.name), ["Summary"])
        for source in [TBDSourceKind.file, .url, .voiceNote] { try db.setPromptAutoRun(id: prompt.id, source: source, enabled: true) }
        XCTAssertNil(try db.prompt(id: prompt.id)?.appliesToSources, "every source collapses to all")
        try db.setPromptAutoRun(id: prompt.id, source: .url, enabled: false)
        XCTAssertEqual(try db.prompt(id: prompt.id)?.appliesToSources, [.file, .meeting, .voiceNote])
        try db.togglePromptVisibility(id: prompt.id)
        XCTAssertEqual(try db.prompt(id: prompt.id)?.isAutoRun, false, "hiding stops auto-run")
    }

    // MARK: Collections

    func testCollectionsAssignAndRemove() throws {
        let db = try library()
        let work = try db.savePromptCollection(TBDPromptCollection(name: " Work "))
        let home = try db.savePromptCollection(TBDPromptCollection(name: "Home"))
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(try db.promptCollections().map(\.name), ["Work", "Home"])
        XCTAssertThrowsError(try db.savePromptCollection(TBDPromptCollection(name: "work"))) {
            XCTAssertEqual($0 as? TBDPromptLibraryError, .duplicateCollectionName("work"))
        }
        XCTAssertThrowsError(try db.savePromptCollection(TBDPromptCollection(name: "  "))) { XCTAssertEqual($0 as? TBDPromptLibraryError, .emptyCollectionName) }

        XCTAssertTrue(try db.assignPrompt(id: TBDPrompt.summaryID, toCollection: work.id))
        XCTAssertEqual(try db.prompt(id: TBDPrompt.summaryID)?.collectionId, work.id)
        XCTAssertEqual(try db.prompts(category: .result).filter { $0.collectionId == work.id }.map(\.name), ["Summary"])
        XCTAssertEqual(try db.promptVersions(promptId: TBDPrompt.summaryID).count, 1, "collections are not versioned")
        XCTAssertTrue(try db.assignPrompt(id: TBDPrompt.summaryID, toCollection: nil))
        XCTAssertNil(try db.prompt(id: TBDPrompt.summaryID)?.collectionId)
        XCTAssertFalse(try db.assignPrompt(id: "missing", toCollection: work.id))
        XCTAssertThrowsError(try db.assignPrompt(id: TBDPrompt.summaryID, toCollection: "nope")) {
            XCTAssertEqual($0 as? TBDPromptLibraryError, .collectionNotFound("nope"))
        }

        try db.reorderPromptCollections(ids: [home.id, work.id])
        XCTAssertEqual(try db.promptCollections().map(\.name), ["Home", "Work"])
        XCTAssertThrowsError(try db.reorderPromptCollections(ids: [home.id])) { XCTAssertEqual($0 as? TBDPromptLibraryError, .invalidOrder) }

        // Deleting a collection unfiles its prompts; prompts stay.
        try db.assignPrompt(id: TBDPrompt.summaryID, toCollection: home.id)
        XCTAssertTrue(try db.deletePromptCollection(id: home.id))
        XCTAssertNil(try db.prompt(id: TBDPrompt.summaryID)?.collectionId)
        XCTAssertEqual(try db.prompts(category: .result).count, 6)
    }

    // MARK: Settings import

    func testCustomSummaryPromptSettingBecomesTheSummaryPromptOnce() throws {
        prefs.summaryPrompt = "Summarise in three bullets."
        let db = try library()
        try db.preparePromptLibrary(preferences: prefs)
        let summary = try XCTUnwrap(db.prompt(id: TBDPrompt.summaryID))
        XCTAssertEqual(summary.content, "Summarise in three bullets.")
        XCTAssertEqual(try db.defaultSummaryPrompt()?.content, "Summarise in three bullets.")
        let versions = try db.promptVersions(promptId: TBDPrompt.summaryID)
        XCTAssertEqual(versions.map(\.versionNumber), [2, 1])
        XCTAssertEqual(versions[0].origin, .import)
        XCTAssertEqual(versions[0].changeNote, "Imported from the summary prompt setting")
        XCTAssertEqual(versions[1].content, TBDListeningPreferences.defaultSummaryPrompt)
        XCTAssertNil(summary.userCustomizedAt, "an import is not a user edit")

        // Changing the setting later does not import again.
        prefs.summaryPrompt = "Something else."
        try db.preparePromptLibrary(preferences: prefs)
        XCTAssertEqual(try db.prompt(id: TBDPrompt.summaryID)?.content, "Summarise in three bullets.")
        XCTAssertEqual(try db.promptVersions(promptId: TBDPrompt.summaryID).count, 2)
    }

    func testUnsetOrDefaultSummaryPromptImportsNothing() throws {
        XCTAssertEqual(try library().promptVersions(promptId: TBDPrompt.summaryID).count, 1)
        prefs.summaryPrompt = TBDListeningPreferences.defaultSummaryPrompt
        XCTAssertEqual(try library().promptVersions(promptId: TBDPrompt.summaryID).count, 1)
    }

    func testSavedTransformPromptsAndTheirHotkeyMoveIntoTheLibraryOnce() throws {
        prefs.transformPrompts = [
            TBDTransformPrompt(id: "a", name: "Shout", instruction: "Uppercase it."),
            TBDTransformPrompt(id: "b", name: "Pirate", instruction: "Rewrite like a pirate."),
        ]
        prefs.transformPromptID = "b"
        prefs.transformHotkey = "F18"
        let db = try library()
        try db.preparePromptLibrary(preferences: prefs)
        let user = try db.prompts(category: .transform).filter { !$0.isBuiltIn }
        XCTAssertEqual(user.map(\.name), ["Shout", "Pirate"])
        XCTAssertEqual(user.map(\.content), ["Uppercase it.", "Rewrite like a pirate."])
        XCTAssertEqual(user.map(\.hotkey), [nil, "f18"])
        XCTAssertEqual(try db.promptVersions(promptId: user[1].id).map(\.origin), [.import])
        XCTAssertEqual(prefs.transformHotkey, "", "the hotkey now lives on its Transform")
        XCTAssertEqual(prefs.transformPromptID, user[1].id)
    }

    func testUnsavedTransformListKeepsTheHotkeyOnItsDefault() throws {
        prefs.transformHotkey = "ctrl+opt+t"
        prefs.transformPromptID = "formal"
        let db = try library()
        let user = try db.prompts(category: .transform).filter { !$0.isBuiltIn }
        XCTAssertEqual(user.map(\.name), ["Make formal"])
        XCTAssertEqual(user.map(\.hotkey), ["ctrl+opt+t"])
    }

    func testNoSavedTransformsAndNoHotkeyImportsNothing() throws {
        let db = try library()
        XCTAssertEqual(try db.prompts(category: .transform).count, 3)
        XCTAssertEqual(prefs.transformHotkey, "")
    }

    // MARK: Running prompts

    func testRunningAChosenPromptStoresASummaryWithThatPromptsText() async throws {
        let db = try library()
        var item = TBDTranscription(title: "Planning", sourceKind: .meeting, status: .completed)
        item.rawText = "We ship on Friday."
        try db.save(item)
        let fake = FakeCompleter(reply: "Fixed summary.")
        var actions = try XCTUnwrap(db.prompts(category: .result).first { $0.name == "Action Items & Decisions" })
        actions.inference = TBDPromptInference(temperature: 0.3, maxTokens: 900)
        actions.modelOverride = "small-model"
        actions = try db.savePrompt(actions)

        let first = try await TBDPromptRunner.summarize(item, with: actions, extraInstructions: " Only owners. ", into: db, complete: fake.complete)
        XCTAssertEqual(first.content, "Fixed summary.")
        XCTAssertEqual(first.prompt, actions.content)
        XCTAssertEqual(first.promptId, actions.id)
        XCTAssertEqual(first.promptVersionId, actions.activeVersionId)
        XCTAssertEqual(first.promptName, "Action Items & Decisions")
        XCTAssertEqual(first.extraInstructions, "Only owners.")
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.task, .analysis)
        XCTAssertEqual(request.maxTokens, 900)
        XCTAssertEqual(request.temperature, 0.3)
        XCTAssertEqual(request.modelOverride, "small-model")
        XCTAssertEqual(request.messages.first, TBDChatMessage(.system, actions.content + "\n\nAdditional instructions for this run:\nOnly owners."))
        XCTAssertEqual(request.messages.last, TBDChatMessage(.user, "Title: Planning\n\nTranscript:\nWe ship on Friday."))

        // A second prompt on the same transcript adds another summary.
        let summaryPrompt = try XCTUnwrap(db.defaultSummaryPrompt())
        try await TBDPromptRunner.summarize(item, with: summaryPrompt, into: db, complete: fake.complete)
        let stored = try db.summaries(for: item.id)
        XCTAssertEqual(stored.map(\.promptName), ["Action Items & Decisions", "Summary"])
        XCTAssertEqual(stored.map(\.prompt), [actions.content, TBDListeningPreferences.defaultSummaryPrompt])
        XCTAssertEqual(stored.map(\.content), ["Fixed summary.", "Fixed summary."])
        XCTAssertEqual(fake.requests[1].maxTokens, 4096)
        XCTAssertNil(fake.requests[1].temperature)
        XCTAssertNil(stored[1].extraInstructions)
    }

    func testMeetingNotesAreSentOnlyWhenThePromptAsksForThem() throws {
        var item = TBDTranscription(title: "Sync", sourceKind: .meeting, status: .completed)
        item.rawText = "Hi."
        item.userNotes = "Budget matters"
        var prompt = TBDPrompt(name: "P", content: "Do it.")
        XCTAssertEqual(TBDPromptRunner.summaryMessages(prompt: prompt, transcription: item)[0].content, "Do it.")
        prompt.includeMeetingNotes = true
        XCTAssertEqual(TBDPromptRunner.summaryMessages(prompt: prompt, transcription: item)[0].content,
                       "Do it.\n\nThe user's notes from the meeting (what they think matters; the transcript is the source of truth):\nBudget matters")
    }

    // MARK: Quick prompts

    func testQuickPromptPinEditAndHidePersist() throws {
        let db = try library()
        let decisions = try XCTUnwrap(db.quickPrompts().first { $0.label == "Decisions made" })
        XCTAssertTrue(try db.setQuickPromptPinned(id: decisions.id, pinned: true))
        XCTAssertEqual(try db.pinnedQuickPrompts().map(\.label).last, "Decisions made")
        XCTAssertFalse(try db.setQuickPromptPinned(id: "missing", pinned: true))

        var edited = try XCTUnwrap(db.quickPrompts().first { $0.id == decisions.id })
        edited.label = "Decisions"
        edited.prompt = "List decisions only."
        try db.saveQuickPrompt(edited)
        let reread = try XCTUnwrap(db.quickPrompts().first { $0.id == decisions.id })
        XCTAssertEqual([reread.label, reread.prompt], ["Decisions", "List decisions only."])
        XCTAssertTrue(reread.isPinned)
        XCTAssertTrue(reread.isBuiltIn)

        // Hiding a pinned prompt unpins it; a hidden prompt is in neither list.
        try db.toggleQuickPromptVisibility(id: decisions.id)
        let hidden = try XCTUnwrap(db.quickPrompts().first { $0.id == decisions.id })
        XCTAssertEqual([hidden.isVisible, hidden.isPinned], [false, false])
        XCTAssertFalse(try db.visibleQuickPrompts().contains { $0.id == decisions.id })
        // Pinning shows it again.
        try db.setQuickPromptPinned(id: decisions.id, pinned: true)
        XCTAssertTrue(try db.pinnedQuickPrompts().contains { $0.id == decisions.id })

        // Built-ins cannot be deleted; custom prompts can. Group casing follows existing groups.
        XCTAssertFalse(try db.deleteQuickPrompt(id: decisions.id))
        let custom = try db.saveQuickPrompt(TBDQuickPromptItem(label: "Risks?", prompt: "List risks.", groupLabel: " capture "))
        XCTAssertEqual(custom.groupLabel, "CAPTURE")
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(try db.quickPrompts().count, 15)
        XCTAssertTrue(try db.deleteQuickPrompt(id: custom.id))
        XCTAssertEqual(try db.quickPrompts().count, 14)

        // Restore puts the shipped text and pin back.
        try db.restoreQuickPromptDefault(id: decisions.id)
        let restored = try XCTUnwrap(db.quickPrompts().first { $0.id == decisions.id })
        XCTAssertEqual(restored.label, "Decisions made")
        XCTAssertFalse(restored.isPinned)
        XCTAssertEqual(restored.asQuickPrompt, TBDQuickPrompt(label: "Decisions made", group: "CAPTURE", prompt: TBDQuickPrompt.starters[2].prompt, key: decisions.id))
    }

    // MARK: Transforms

    func testTransformCreateEditDelete() throws {
        let db = try library()
        let created = try db.savePrompt(TBDPrompt(name: "Shout", content: "Uppercase it.", category: .transform, isAutoRun: true, hotkey: " Ctrl+Opt+9 "))
        XCTAssertEqual(created.hotkey, "ctrl+opt+9")
        XCTAssertFalse(created.isAutoRun, "Transforms never auto-run")
        XCTAssertEqual(try db.prompts(category: .transform).map(\.name), ["Polish", "Distill", "Decide", "Shout"])
        var edited = created
        edited.content = "UPPERCASE IT."
        edited.hotkey = ""
        try db.savePrompt(edited)
        let reread = try XCTUnwrap(db.prompt(id: created.id))
        XCTAssertEqual(reread.content, "UPPERCASE IT.")
        XCTAssertNil(reread.hotkey)
        edited.hotkey = "q"
        XCTAssertThrowsError(try db.savePrompt(edited)) {
            XCTAssertEqual($0 as? TBDPromptLibraryError, .invalidHotkey(TBDHotkey.ParseError.needsModifier("q").localizedDescription))
        }
        XCTAssertTrue(try db.deletePrompt(id: created.id))
        XCTAssertEqual(try db.prompts(category: .transform).map(\.name), ["Polish", "Distill", "Decide"])
        try db.deletePrompt(id: "1ad7c2b0-9c6f-4f0e-9c39-5e4d1f1d2a55")
        try db.restoreMissingBuiltIns(category: .transform)
        XCTAssertEqual(try db.prompts(category: .transform).map(\.name), ["Polish", "Distill", "Decide"])
        XCTAssertEqual(try db.deletedPrompts().map(\.name), ["Shout"])
    }

    func testTransformHotkeyBindingsCoverExactlyTheTransformsWithValidHotkeys() throws {
        let prompts = [
            TBDPrompt(id: "c", name: "C", content: "x", category: .transform, sortOrder: 3, hotkey: "ctrl+opt+1"),   // duplicate of a
            TBDPrompt(id: "a", name: "A", content: "x", category: .transform, sortOrder: 1, hotkey: "ctrl+opt+1"),
            TBDPrompt(id: "b", name: "B", content: "x", category: .transform, sortOrder: 2, hotkey: "f18"),
            TBDPrompt(id: "d", name: "D", content: "x", category: .transform, sortOrder: 4),                      // no hotkey
            TBDPrompt(id: "e", name: "E", content: "x", category: .transform, sortOrder: 5, hotkey: "nonsense+key"),
            TBDPrompt(id: "f", name: "F", content: "x", category: .transform, sortOrder: 6, hotkey: "fn"),          // dictation key
            TBDPrompt(id: "g", name: "G", content: "x", category: .transform, sortOrder: 7, hotkey: "ctrl+opt+7", deletedAt: Date()),
            TBDPrompt(id: "h", name: "H", content: "x", category: .result, sortOrder: 8, hotkey: "ctrl+opt+8"),
            TBDPrompt(id: "i", name: "I", content: "x", category: .transform, sortOrder: 9, hotkey: "cmd+shift+y"),
        ]
        let bindings = TBDTransformHotkeys.bindings(for: prompts, reserved: [.fn])
        XCTAssertEqual(bindings, [
            .init(hotkey: try TBDHotkey.parse("ctrl+opt+1"), transformID: "a"),
            .init(hotkey: try TBDHotkey.parse("f18"), transformID: "b"),
            .init(hotkey: try TBDHotkey.parse("cmd+shift+y"), transformID: "i"),
        ])
        XCTAssertEqual(TBDTransformHotkeys.bindings(for: []), [])
    }

    func testTheSeededTransformsBindControlOptionDigits() throws {
        let db = try library()
        let bindings = TBDTransformHotkeys.bindings(for: try db.prompts(category: .transform), reserved: [.fn])
        XCTAssertEqual(bindings.map(\.hotkey.serialized), ["ctrl+opt+1", "ctrl+opt+2", "ctrl+opt+3"])
    }

    func testATransformRunWritesAHistoryRowWithTheExactInputAndOutput() async throws {
        let db = try library()
        let polish = try XCTUnwrap(db.prompts(category: .transform).first)
        let fake = FakeCompleter(reply: "  Polished text.\n")
        let output = try await TBDPromptRunner.transform("polish   this text", with: polish, sourceAppBundleID: "com.example.notes",
                                                         sourceAppName: "Notes", database: db, complete: fake.complete)
        XCTAssertEqual(output, "Polished text.")
        let runs = try db.transformRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].inputText, "polish   this text")
        XCTAssertEqual(runs[0].outputText, "Polished text.")
        XCTAssertEqual(runs[0].transformId, polish.id)
        XCTAssertEqual(runs[0].transformName, "Polish")
        XCTAssertEqual(runs[0].sourceAppDisplayName, "Notes")
        XCTAssertEqual(fake.requests.first?.task, .general)
        XCTAssertEqual(fake.requests.first?.messages, [
            TBDChatMessage(.system, polish.content + "\nReturn only the resulting text, with no preamble, quotes or explanation."),
            TBDChatMessage(.user, "polish   this text"),
        ])

        // An empty model answer is an error and writes no history.
        let empty = FakeCompleter(reply: " \n")
        do {
            _ = try await TBDPromptRunner.transform("x", with: polish, database: db, complete: empty.complete)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TBDChatClientError, .emptyResponse)
        }
        XCTAssertEqual(try db.transformRunCount(), 1)
    }

    func testDeletingAndClearingTransformHistory() throws {
        let db = try library()
        let older = TBDTransformRun(transformId: nil, transformName: "Polish", inputText: "a", outputText: "A", createdAt: Date(timeIntervalSince1970: 100))
        let newer = TBDTransformRun(transformId: nil, transformName: "Distill", inputText: "b", outputText: "B", createdAt: Date(timeIntervalSince1970: 200))
        try db.saveTransformRun(older)
        try db.saveTransformRun(newer)
        XCTAssertEqual(try db.transformRuns().map(\.transformName), ["Distill", "Polish"])
        XCTAssertEqual(try db.transformRuns(limit: 1).map(\.id), [newer.id])
        XCTAssertTrue(try db.deleteTransformRun(id: older.id))
        XCTAssertFalse(try db.deleteTransformRun(id: older.id))
        XCTAssertEqual(try db.transformRunCount(), 1)
        try db.clearTransformRuns()
        XCTAssertEqual(try db.transformRuns(), [])
        XCTAssertEqual(try db.transformRunCount(), 0)
    }

    func testRunningLabels() {
        XCTAssertEqual(TBDPrompt.defaultRunningLabel(forName: "Polish"), "Polishing…")
        XCTAssertEqual(TBDPrompt.defaultRunningLabel(forName: "Make"), "Making…")
        XCTAssertEqual(TBDPrompt.defaultRunningLabel(forName: "Summary writer"), "Transforming…")
        XCTAssertEqual(TBDPrompt.defaultRunningLabel(forName: "Shortened"), "Transforming…")
    }
}
