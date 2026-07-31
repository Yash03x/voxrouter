import Foundation
import Testing
@testable import VoxRouterKit

@Suite("Quick reply parsing")
struct QuickReplyParsingTests {
    /// The instructions ask for exactly ESCALATE; models decorate the token
    /// anyway. A variant missed here gets spoken at the user as the word
    /// "escalate" while their question is dropped.
    @Test("Decorated escalation tokens all escalate", arguments: [
        "ESCALATE",
        "escalate",
        "Escalate",
        "  ESCALATE  ",
        "ESCALATE.",
        "ESCALATE!",
        "\"ESCALATE\"",
        "'escalate'",
        "\u{201C}ESCALATE.\u{201D}",
        "**ESCALATE**",
        "\nESCALATE.\n",
        "ESCALATE — this needs the web",
        "ESCALATE. That needs your calendar.",
        "\"ESCALATE\" — live sports scores.",
    ])
    func escalateVariants(reply: String) {
        #expect(QuickAnswerOutcome.parseReply(reply) == .escalated(.modelDeclined))
    }

    /// Nothing speakable in any of these — passing them to the synthesiser
    /// would answer the user with silence, which is worse than a slow engine.
    @Test("Empty or unspeakable replies count as declined", arguments: [
        "",
        "   ",
        "\n\t \n",
        "...",
        "\u{2014}",
    ])
    func nothingSpeakableDeclines(reply: String) {
        #expect(QuickAnswerOutcome.parseReply(reply) == .escalated(.modelDeclined))
    }

    /// The overreach the token check must not make: a reply that contains the
    /// word escalate is an answer about escalation, and the leading-token
    /// check is case-sensitive precisely so a sentence that *opens* with the
    /// word stays an answer too. Treating any of these as a bail-out would
    /// discard exactly the fast answers the tier exists to give. Inputs here
    /// are already single-spaced, so the parsed answer must equal the input
    /// verbatim.
    @Test("A reply containing escalate mid-sentence is an answer", arguments: [
        "You should escalate this to your manager.",
        "Escalate means to increase in intensity or seriousness.",
        "Escalate comes from the Latin scala, a ladder.",
        "I would escalate.",
        "No — escalate it first thing tomorrow.",
    ])
    func midSentenceEscalateIsAnAnswer(reply: String) {
        #expect(QuickAnswerOutcome.parseReply(reply) == .answered(reply))
    }

    /// Answers are spoken, not shown: newlines and run-on spaces are
    /// formatting the synthesiser would stumble over or read as pauses.
    @Test("Answers collapse internal whitespace and trim the edges")
    func collapsesWhitespace() {
        #expect(
            QuickAnswerOutcome.parseReply("  Paris is\nthe capital \n\n  of France. ")
                == .answered("Paris is the capital of France.")
        )
    }
}

@Suite("Deadline racing")
struct WithDeadlineTests {
    private struct StubError: Error {}

    /// Every fast answer flows through this helper; a value lost here is a
    /// model reply silently discarded.
    @Test("A fast operation's value survives the race")
    func fastOperationWins() async throws {
        let value = try await withDeadline(seconds: 5) { "fast" }
        #expect(value == "fast")
    }

    /// The nil must arrive near the deadline, not when the slow operation
    /// eventually finishes — otherwise the "backstop" quietly waits out the
    /// very hang it exists to cut short.
    @Test("A slow operation times out as nil near the deadline")
    func slowOperationTimesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await withDeadline(seconds: 0.2) { () -> String in
            try await Task.sleep(for: .seconds(60))
            return "late"
        }
        let elapsed = clock.now - start
        #expect(value == nil)
        // Far below the operation's 60 s proves the deadline fired; the slack
        // above 0.2 s is for a loaded machine, not correctness.
        #expect(elapsed < .seconds(5), "took \(elapsed); deadline did not cut the operation short")
        #expect(elapsed >= .milliseconds(190), "returned before the deadline could have fired")
    }

    /// Thrown errors must stay errors: folding them into the nil timeout
    /// would make a guardrail refusal indistinguishable from a hang in the
    /// escalation logs.
    @Test("A throwing operation propagates its error")
    func errorsPropagate() async {
        await #expect(throws: StubError.self) {
            _ = try await withDeadline(seconds: 5) { () -> String in
                throw StubError()
            }
        }
    }

    /// The failure the unstructured rewrite exists to prevent: a task group
    /// cannot return until its children finish, so an operation that ignored
    /// cancellation used to hold the deadline hostage for its full running
    /// time. This operation spins straight past cancellation for two
    /// seconds; the nil must still arrive at the 0.2 s mark.
    @Test("An operation that ignores cancellation cannot outstay the deadline")
    func uncancellableOperationStillTimesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await withDeadline(seconds: 0.2) { () -> String in
            // Spin rather than sleep: Task.sleep honours cancellation, and
            // the point here is an operation that does not.
            let end = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < end { await Task.yield() }
            return "late"
        }
        let elapsed = clock.now - start
        #expect(value == nil)
        // Well under the operation's 2 s proves the deadline returned without
        // waiting for the straggler; the slack above 0.2 s is for a loaded
        // machine, not correctness.
        #expect(elapsed < .seconds(1), "took \(elapsed); the straggler held the deadline hostage")
        #expect(elapsed >= .milliseconds(190), "returned before the deadline could have fired")
    }

    /// The straggler is abandoned, not joined — when its value finally
    /// arrives it must vanish quietly, not crash a finished race or resume
    /// anything twice. The confirmation pins that the straggler really did
    /// complete while the test was still watching.
    @Test("An abandoned straggler's late result is discarded without incident")
    func abandonedStragglerResultIsDiscarded() async throws {
        try await confirmation("straggler ran to completion") { finished in
            let value = try await withDeadline(seconds: 0.1) { () -> String in
                let end = ContinuousClock.now + .milliseconds(400)
                while ContinuousClock.now < end { await Task.yield() }
                finished()
                return "late"
            }
            #expect(value == nil)
            // Outlive the straggler so its yield into the finished race
            // happens before this test stops watching for a crash.
            try await Task.sleep(for: .seconds(1))
        }
    }
}

/// The shared prompt assembly every backend routes through — kept pure in the
/// `QuickAnswerer` extension precisely so it is testable without any model.
@Suite("Prompt assembly")
struct PromptAssemblyTests {
    @Test("Context is prepended under its heading, question last")
    func promptCarriesContext() {
        let prompt = OllamaAnswerer.promptText(
            for: "How tall is that in metres?",
            context: "The user asked the height of Everest; you said 29,032 feet."
        )
        #expect(prompt.hasPrefix("Earlier in this conversation:"))
        #expect(prompt.contains("29,032 feet"))
        #expect(prompt.hasSuffix("How tall is that in metres?"))
    }

    /// An empty digest must behave like no digest: a heading with nothing
    /// under it reads to the model like a corrupted transcript.
    @Test("Without context the prompt is only the question")
    func promptWithoutContext() {
        #expect(OllamaAnswerer.promptText(for: "What is a monad?", context: nil) == "What is a monad?")
        #expect(OllamaAnswerer.promptText(for: "What is a monad?", context: "") == "What is a monad?")
    }
}
