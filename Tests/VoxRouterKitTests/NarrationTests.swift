import Foundation
import Testing
@testable import VoxRouterKit

@Suite("Spoken narration filter")
struct SpeakableTests {
    /// The rule that matters most: engine replies routinely contain diffs, and
    /// reading one aloud is unusable.
    @Test("Fenced code is dropped entirely")
    func dropsCodeFences() {
        let text = """
        I fixed the parser.

        ```swift
        func parse(_ input: String) -> Int {
            return Int(input) ?? 0
        }
        ```

        Tests pass now.
        """
        let spoken = SpokenNarration.speakable(text)
        #expect(spoken.contains("I fixed the parser"))
        #expect(spoken.contains("Tests pass now"))
        #expect(!spoken.contains("func parse"))
        #expect(!spoken.contains("```"))
    }

    @Test("An unterminated code fence doesn't leak the rest of the message")
    func dropsUnterminatedFence() {
        let spoken = SpokenNarration.speakable("Here you go:\n```\nlet x = 1\nlet y = 2")
        #expect(spoken.contains("Here you go"))
        #expect(!spoken.contains("let x"))
    }

    @Test("Inline code keeps its words but loses the backticks")
    func stripsInlineBackticks() {
        let spoken = SpokenNarration.speakable("Call `parseConfig` before `start`.")
        #expect(spoken == "Call parseConfig before start.")
    }

    /// Hearing a path spelled out component by component is useless; the
    /// filename is the identifying part.
    @Test("File paths are reduced to the filename")
    func shortensPaths() {
        let spoken = SpokenNarration.speakable(
            "Updated Sources/VoxRouterKit/Audio/VoiceGate.swift and Tests/Helper.swift"
        )
        #expect(spoken.contains("VoiceGate.swift"))
        #expect(!spoken.contains("Sources/"))
        #expect(spoken.contains("Helper.swift"))
    }

    @Test("Trailing punctuation survives path shortening")
    func keepsPunctuationAfterPaths() {
        let spoken = SpokenNarration.speakable("I changed src/main.swift.")
        #expect(spoken == "I changed main.swift.")
    }

    @Test("Markdown structure is removed")
    func stripsMarkdown() {
        let spoken = SpokenNarration.speakable("""
        ## Summary
        - **Fixed** the leak
        - Added *two* tests
        """)
        #expect(!spoken.contains("#"))
        #expect(!spoken.contains("*"))
        #expect(!spoken.contains("-"))
        #expect(spoken.contains("Fixed the leak"))
        #expect(spoken.contains("two tests"))
    }

    @Test("Links become their label, bare URLs become 'a link'")
    func handlesLinks() {
        #expect(SpokenNarration.speakable("See [the docs](https://example.com/x) for more")
            .contains("the docs"))
        #expect(SpokenNarration.speakable("Try https://example.com/a/b now")
            .contains("a link"))
    }

    @Test("Long text is truncated on a sentence boundary")
    func truncatesAtSentence() {
        let text = String(repeating: "This is a sentence. ", count: 40)
        let spoken = SpokenNarration.speakable(text, maxCharacters: 100)
        #expect(spoken.count <= 101)
        #expect(spoken.hasSuffix("."), "should end cleanly, not mid-clause")
    }

    @Test("Truncation without punctuation falls back to a word boundary")
    func truncatesAtWord() {
        let text = String(repeating: "word ", count: 200)
        let spoken = SpokenNarration.speakable(text, maxCharacters: 50)
        #expect(spoken.count <= 51)
        #expect(!spoken.hasSuffix("wo…"), "should not cut mid-word")
    }

    @Test("Whitespace is collapsed")
    func collapsesWhitespace() {
        #expect(SpokenNarration.speakable("one\n\n\ntwo    three") == "one two three")
    }

    @Test("Ordinary prose passes through unchanged")
    func leavesProseAlone() {
        let text = "I updated the router and all the tests pass."
        #expect(SpokenNarration.speakable(text) == text)
    }
}

@Suite("What gets spoken")
struct NarrationSelectionTests {
    /// An engine emits dozens of tool calls per task. Narrating them would make
    /// the assistant intolerable.
    @Test("Actions and streamed prose are never spoken")
    func staysQuietDuringWork() {
        #expect(SpokenNarration.line(for: .action(engine: "claude", detail: "Edit main.swift")) == nil)
        #expect(SpokenNarration.line(for: .text(engine: "claude", detail: "Looking at it…")) == nil)
    }

    @Test("Only the result, failures and blocking are spoken by default")
    func speaksTheMomentsThatMatter() {
        #expect(SpokenNarration.line(for: .succeeded(engine: "codex", summary: nil)) != nil)
        #expect(SpokenNarration.line(for: .failed(reason: "boom")) != nil)
        #expect(SpokenNarration.line(for: .blocked(retryAfter: nil)) != nil)
    }

    /// Which engine took the task is the router's business. Saying it aloud
    /// defeats the point of routing automatically, and you already know you just
    /// asked for something.
    @Test("Dispatch and handoff are silent by default")
    func engineChoiceIsNotAnnounced() {
        #expect(SpokenNarration.line(for: .routed(engine: "claude", reason: "x")) == nil)
        #expect(SpokenNarration.line(for: .handoff(from: "claude", to: "codex", reason: "x")) == nil)
    }

    @Test("Detailed verbosity restores the engine announcements")
    func detailedVerbositySpeaksEngines() throws {
        let routed = try #require(SpokenNarration.line(
            for: .routed(engine: "claude", reason: "x"), verbosity: .detailed
        ))
        #expect(routed.contains("Claude"))

        let handoff = try #require(SpokenNarration.line(
            for: .handoff(from: "claude", to: "codex", reason: "x"), verbosity: .detailed
        ))
        #expect(handoff.contains("Codex"))
        #expect(handoff.lowercased().contains("quota"))
    }

    @Test("Results are spoken at every verbosity")
    func resultsAlwaysSpeak() {
        for verbosity in [SpokenNarration.Verbosity.minimal, .detailed] {
            #expect(SpokenNarration.line(
                for: .succeeded(engine: "codex", summary: "Fixed it."), verbosity: verbosity
            ) != nil)
            #expect(SpokenNarration.line(for: .failed(reason: "boom"), verbosity: verbosity) != nil)
        }
    }

    /// "Done." before every reply is filler — the answer already says it
    /// finished. Kept only when there's nothing else to say.
    @Test("A summary is spoken on its own, with no preamble")
    func summarySpokenDirectly() throws {
        let line = try #require(SpokenNarration.line(
            for: .succeeded(engine: "codex", summary: "The working tree is clean.")
        ))
        #expect(line == "The working tree is clean.")
        #expect(!line.hasPrefix("Done"))
    }

    @Test("Success with no summary still says something")
    func bareSuccess() throws {
        let line = try #require(SpokenNarration.line(for: .succeeded(engine: "codex", summary: nil)))
        #expect(line == "Done.", "silence would be ambiguous here")
    }

    @Test("A success summary is run through the speech filter")
    func successSummaryIsFiltered() throws {
        let summary = "Fixed it.\n```swift\nlet x = 1\n```\nSee src/a.swift"
        let line = try #require(
            SpokenNarration.line(for: .succeeded(engine: "codex", summary: summary))
        )
        #expect(!line.contains("let x"))
        #expect(!line.contains("src/"))
        #expect(line.hasPrefix("Fixed it"), "no preamble before the answer")
    }

    @Test("A code-only summary degrades to 'Done.' rather than silence")
    func codeOnlySummary() throws {
        let line = try #require(
            SpokenNarration.line(for: .succeeded(engine: "codex", summary: "```\ncode\n```"))
        )
        #expect(line == "Done.")
    }

    @Test("Being blocked reports when quota returns")
    func blockedSaysWhen() throws {
        let reset = Date().addingTimeInterval(7200)
        let line = try #require(SpokenNarration.line(for: .blocked(retryAfter: reset)))
        #expect(line.contains("hours"))
    }
}

@Suite("Relative time phrasing")
struct RelativePhraseTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Speaks approximate, human durations")
    func phrasing() {
        func phrase(_ seconds: TimeInterval) -> String {
            SpokenNarration.relativePhrase(now.addingTimeInterval(seconds), from: now)
        }
        #expect(phrase(30) == "in about a minute")
        #expect(phrase(600).contains("minutes"))
        #expect(phrase(3600 * 2).contains("hours"))
        #expect(phrase(3600).contains("an hour"))
        #expect(phrase(86_400) == "tomorrow")
        #expect(phrase(86_400 * 4).contains("days"))
    }

    @Test("A past reset reads as 'shortly', not a negative duration")
    func pastResetIsSane() {
        #expect(SpokenNarration.relativePhrase(now.addingTimeInterval(-500), from: now) == "shortly")
    }
}

@Suite("Speaker protocol")
struct SpeakerTests {
    @Test("The silent speaker is inert")
    func silentSpeakerDoesNothing() async {
        let speaker = SilentSpeaker()
        await speaker.speak("anything")
        speaker.stop()
        #expect(!speaker.isSpeaking)
        #expect(speaker.identifier == "silent")
    }

    @Test("Voice lookup accepts a human name, not just an identifier")
    func resolvesVoiceByName() {
        // Samantha ships with macOS; if absent, only assert we don't crash.
        let byName = SystemSpeaker.resolveVoice("Samantha")
        if byName != nil {
            #expect(byName?.name.localizedCaseInsensitiveContains("Samantha") == true)
        }
        #expect(SystemSpeaker.resolveVoice(nil) == nil)
        #expect(SystemSpeaker.resolveVoice("") == nil)
        #expect(SystemSpeaker.resolveVoice("no-such-voice-xyz") == nil)
    }

    @Test("At least one system voice is installed")
    func hasVoices() {
        #expect(!SystemSpeaker.availableVoices().isEmpty)
    }
}
