import Foundation
import Testing
@testable import VoxRouterKit

/// Counts its calls, so "the second backend was never consulted" can be
/// asserted rather than assumed.
private final class ScriptedAnswerer: QuickAnswerer, @unchecked Sendable {
    let displayName: String
    private let outcome: QuickAnswerOutcome
    private let lock = NSLock()
    private var answers = 0
    private var prewarms = 0

    init(_ name: String, _ outcome: QuickAnswerOutcome) {
        self.displayName = name
        self.outcome = outcome
    }

    var answerCount: Int { lock.withLock { answers } }
    var prewarmCount: Int { lock.withLock { prewarms } }

    func answer(_ question: String, context: String?) async -> QuickAnswerOutcome {
        lock.withLock { answers += 1 }
        return outcome
    }

    func prewarm() async {
        lock.withLock { prewarms += 1 }
    }
}

@Suite("Chained answerer")
struct ChainedAnswererTests {
    /// The chain's whole purpose: a missing preferred backend is skipped and
    /// the next one gets the question.
    @Test("An unavailable backend falls through to the next")
    func unavailableFallsThrough() async {
        let absent = ScriptedAnswerer("absent", .escalated(.unavailable))
        let present = ScriptedAnswerer("present", .answered("It's 4."))
        let chain = ChainedAnswerer([absent, present])

        let (outcome, backend) = await chain.attributedAnswer("two plus two", context: nil)
        #expect(outcome == .answered("It's 4."))
        #expect(backend == "present")
        #expect(absent.answerCount == 1)
        #expect(present.answerCount == 1)
    }

    /// Preference order is real: when the first backend answers, the second
    /// must never even be consulted — it is the fallback, not a second
    /// opinion.
    @Test("A first-backend answer never consults the rest")
    func firstAnswerWins() async {
        let first = ScriptedAnswerer("first", .answered("Paris."))
        let second = ScriptedAnswerer("second", .answered("Lyon."))
        let chain = ChainedAnswerer([first, second])

        let (outcome, backend) = await chain.attributedAnswer("capital of france", context: nil)
        #expect(outcome == .answered("Paris."))
        #expect(backend == "first")
        #expect(second.answerCount == 0, "the fallback must not be a second opinion")
    }

    /// With nobody home the chain reports plain unavailability — to the
    /// pipeline this reads exactly like the tier being off, which is the
    /// behaviour every older configuration already relied on.
    @Test("All backends unavailable collapses to unavailable")
    func allUnavailable() async {
        let a = ScriptedAnswerer("a", .escalated(.unavailable))
        let b = ScriptedAnswerer("b", .escalated(.unavailable))
        let chain = ChainedAnswerer([a, b])

        let (outcome, backend) = await chain.attributedAnswer("two plus two", context: nil)
        #expect(outcome == .escalated(.unavailable))
        #expect(backend == nil, "no backend produced the outcome, so none may be named")
        #expect(a.answerCount == 1 && b.answerCount == 1)
    }

    /// The decision this suite exists to pin: a decline is final for the
    /// whole tier. One small model has already weighed the question and
    /// judged it beyond the tier; handing it to a second small model of the
    /// same class just doubles the latency before the engine — the safe
    /// destination — gets it. Only *absence* may fall through.
    @Test("A model's decline does not fall through to the next backend",
          arguments: [QuickEscalation.modelDeclined, .timedOut, .failed])
    func nonAvailabilityEscalationsAreFinal(reason: QuickEscalation) async {
        let judge = ScriptedAnswerer("judge", .escalated(reason))
        let eager = ScriptedAnswerer("eager", .answered("Sure, done!"))
        let chain = ChainedAnswerer([judge, eager])

        let (outcome, backend) = await chain.attributedAnswer(
            "what's the weather in berlin right now", context: nil
        )
        #expect(outcome == .escalated(reason))
        #expect(backend == "judge")
        #expect(eager.answerCount == 0,
                "shopping a declined question to another small model is the misroute that loses work")
    }

    /// Prewarming is per-model residency, so warming only the preferred
    /// backend would leave the fallback paying its cold load inside someone's
    /// first real question — on the exact machines that need the fallback.
    @Test("Prewarm reaches every backend")
    func prewarmReachesAll() async {
        let a = ScriptedAnswerer("a", .escalated(.unavailable))
        let b = ScriptedAnswerer("b", .answered("x"))
        let chain = ChainedAnswerer([a, b])

        await chain.prewarm()
        #expect(a.prewarmCount == 1)
        #expect(b.prewarmCount == 1)
    }

    /// Degenerate but must not trap: an empty chain is simply unavailable.
    @Test("An empty chain is unavailable")
    func emptyChain() async {
        let chain = ChainedAnswerer([])
        let outcome = await chain.answer("two plus two", context: nil)
        #expect(outcome == .escalated(.unavailable))
    }
}
