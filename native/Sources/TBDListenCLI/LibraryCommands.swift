import ArgumentParser
import Foundation
import TBDSpeech

struct Vocabulary: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Custom words applied to every transcript.",
                                                    subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List custom words.")
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let words = try openLibrary().customWords()
            if json { outputJSON(words.map(TBDListenJSON.CustomWord.init)); return }
            if words.isEmpty { output("No custom words."); return }
            for word in words {
                output("\(word.id.prefix(8))  \(word.word)\(word.replacement.map { " → \($0)" } ?? "")\(word.isEnabled ? "" : " (off)")")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a custom word (optionally replacing what the engine hears).")
        @Argument(help: "The word or phrase the engine produces.") var word: String
        @Option(help: "Text to write instead.") var replacement: String?
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError("The word is empty.") }
            let library = try openLibrary(readOnly: false)
            if try library.customWords().contains(where: { $0.word.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                throw ValidationError("\(trimmed) is already a custom word.")
            }
            let entry = TBDCustomWord(word: trimmed, replacement: replacement.flatMap { $0.isEmpty ? nil : $0 })
            try library.save(entry)
            if json { outputJSON(TBDListenJSON.CustomWord(entry)) } else { output("Added \(entry.word).") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a custom word by word or id prefix.")
        @Argument(help: "Word or id prefix.") var word: String
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let library = try openLibrary(readOnly: false)
            let words = try library.customWords()
            let matches = words.filter { $0.word.caseInsensitiveCompare(word) == .orderedSame || $0.id.hasPrefix(word) }
            guard matches.count == 1, let entry = matches.first else {
                throw ValidationError(matches.isEmpty ? "No custom word matches \(word)." : "\(word) matches several entries; use the id.")
            }
            try library.deleteCustomWord(id: entry.id)
            if json { outputJSON(TBDListenJSON.CustomWord(entry)) } else { output("Removed \(entry.word).") }
        }
    }
}

struct Snippets: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dictation snippets: a spoken trigger expands to text.",
                                                    subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List snippets.")
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let snippets = try openLibrary().snippets()
            if json { outputJSON(snippets.map(TBDListenJSON.Snippet.init)); return }
            if snippets.isEmpty { output("No snippets."); return }
            for snippet in snippets {
                output("\(snippet.id.prefix(8))  \(snippet.trigger) → \(snippet.expansion)  (used \(snippet.useCount)×)\(snippet.isEnabled ? "" : " (off)")")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a snippet.")
        @Argument(help: "Spoken trigger phrase.") var trigger: String
        @Argument(help: "Text it expands to.") var expansion: String
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else { throw ValidationError("Trigger and expansion must not be empty.") }
            let library = try openLibrary(readOnly: false)
            if try library.snippets().contains(where: { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame }) {
                throw ValidationError("A snippet for \(trigger) exists already.")
            }
            let snippet = TBDSnippet(trigger: trigger, expansion: expansion)
            try library.save(snippet)
            if json { outputJSON(TBDListenJSON.Snippet(snippet)) } else { output("Added \(snippet.trigger).") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a snippet by trigger or id prefix.")
        @Argument(help: "Trigger or id prefix.") var trigger: String
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let library = try openLibrary(readOnly: false)
            let matches = try library.snippets().filter { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame || $0.id.hasPrefix(trigger) }
            guard matches.count == 1, let snippet = matches.first else {
                throw ValidationError(matches.isEmpty ? "No snippet matches \(trigger)." : "\(trigger) matches several snippets; use the id.")
            }
            try library.deleteSnippet(id: snippet.id)
            if json { outputJSON(TBDListenJSON.Snippet(snippet)) } else { output("Removed \(snippet.trigger).") }
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or change Listen preferences (shared with the TBD app).",
                                                    subcommands: [ShowAll.self, Get.self, Set.self], defaultSubcommand: ShowAll.self)

    struct ShowAll: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show every Listen preference.")
        @Flag(help: "Print JSON (an object of key → value; null means default).") var json = false
        func run() throws {
            let snapshot = appPreferences.configSnapshot()
            if json {
                output(TBDListenJSON.encode(Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key, $0.value) })))
                return
            }
            for entry in snapshot { output("\(entry.key) = \(entry.value)") }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one preference.")
        @Argument(help: "Key (see `tbd-listen config show`).") var key: String
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let value = try appPreferences.configValue(key)
            if json { outputJSON(TBDListenJSON.ConfigEntry(key: key, value: value)) } else { output(value.description) }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one preference. Use default (or auto) to reset an optional key.")
        @Argument(help: "Key (see `tbd-listen config show`).") var key: String
        @Argument(help: "New value.") var value: String
        @Flag(help: "Print JSON.") var json = false
        func run() throws {
            let preferences = appPreferences
            try preferences.setConfig(key, to: value)
            let stored = try preferences.configValue(key)
            if json { outputJSON(TBDListenJSON.ConfigEntry(key: key, value: stored)) } else { output("\(key) = \(stored)") }
        }
    }
}
