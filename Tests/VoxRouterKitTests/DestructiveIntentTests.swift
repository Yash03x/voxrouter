import Foundation
import Testing
@testable import VoxRouterKit

@Suite("Destructive intent gate")
struct DestructiveIntentTests {
    @Test("Inherently dangerous commands always confirm")
    func alwaysConfirms() {
        for phrase in [
            "run rm -rf on the build folder",
            "just sudo install it",
            "force push to main",
            "do a git reset --hard",
            "drop database users",
            "factory reset the config",
        ] {
            #expect(DestructiveIntent.assess(phrase) != nil, "should confirm: \(phrase)")
        }
    }

    @Test("A destructive verb aimed at something broad confirms")
    func broadScopeConfirms() {
        for phrase in [
            "delete everything in the project",
            "remove all files from the folder",
            "wipe the database",
            "get rid of the entire test suite",
            "nuke node_modules",
        ] {
            #expect(DestructiveIntent.assess(phrase) != nil, "should confirm: \(phrase)")
        }
    }

    /// Confirming routine edits would train the user to say yes reflexively,
    /// which is worse than not asking at all.
    @Test("Routine destructive edits are not confirmed")
    func routineWorkIsNotGated() {
        for phrase in [
            "delete the unused import in main.swift",
            "remove that stray print statement",
            "clean up the whitespace",
            "drop the extra semicolon",
            "delete the duplicate test",
            "run the tests and fix what breaks",
            "refactor the parser",
        ] {
            #expect(DestructiveIntent.assess(phrase) == nil, "should NOT confirm: \(phrase)")
        }
    }

    @Test("Detection is case-insensitive")
    func caseInsensitive() {
        #expect(DestructiveIntent.assess("FORCE PUSH to main") != nil)
        #expect(DestructiveIntent.assess("Delete EVERYTHING") != nil)
    }

    @Test("The reason is spoken back so the user knows what they're approving")
    func reasonIsUseful() throws {
        let assessment = try #require(DestructiveIntent.assess("please force push to origin"))
        #expect(assessment.reason.contains("force push"))
    }
}

@Suite("Confirmation replies")
struct ConfirmationReplyTests {
    @Test("Clear affirmations are accepted")
    func affirmations() {
        for reply in ["yes", "Yeah", "do it", "go ahead", "confirm", "okay."] {
            #expect(DestructiveIntent.interpretReply(reply) == .affirm, "for: \(reply)")
        }
    }

    @Test("Clear negations are declines")
    func negations() {
        for reply in ["no", "cancel", "stop", "never mind", "abort!"] {
            #expect(DestructiveIntent.interpretReply(reply) == .decline, "for: \(reply)")
        }
    }

    /// If the recogniser mishears the *confirmation* too, the safe reading is
    /// "no" — an unclear answer must never run a destructive task.
    @Test("An ambiguous reply is not treated as consent")
    func ambiguousIsNotConsent() {
        for reply in [
            "yes but only the tests",
            "run the other thing instead",
            "what did you say",
            "",
        ] {
            #expect(DestructiveIntent.interpretReply(reply) != .affirm, "for: \(reply)")
        }
    }
}
