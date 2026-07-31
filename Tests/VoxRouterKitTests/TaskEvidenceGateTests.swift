import Foundation
import Testing
@testable import VoxRouterKit

/// True for any `.engine` decision regardless of reason — the tables assert
/// direction, not wording, so a better reason string can't break them.
private func routesToEngine(_ decision: RouteDecision) -> Bool {
    if case .engine = decision { return true }
    return false
}

/// The gate decides what the small on-device model is allowed to try, so the
/// failure that matters is asymmetric: a question sent to an engine is slow,
/// but a task cleared for the fast tier is silently lost work. The engine-side
/// tables are therefore the load-bearing ones — every string in them is a real
/// task that must never come back `.tryFast`.
@Suite("Task evidence gate")
struct TaskEvidenceGateTests {

    // MARK: - Tasks must reach the engine

    /// Real tasks, phrased the way people actually speak them. Each one lost
    /// to the fast tier is work that silently never happens, so these must
    /// route to the engine in *and* out of a coding conversation — the
    /// argument matrix below runs every string against both.
    static let tasks: [String] = [
        "run the tests and fix what breaks",
        "open the parser and refactor it",
        "fix the login bug on the settings screen",
        "why is the build failing",
        "commit and push",
        "refactor SystemCommands.swift",
        "add a dark mode toggle to the app",
        "rename the QuickNote struct",
        "start fixing the login bug",
        "keep updating the tests",
        "move the tests into one file",
        "pushing the branch now",
        "try committing the code",
    ]

    @Test("Known tasks never reach the fast tier", arguments: tasks, [false, true])
    func tasksRouteToEngine(_ utterance: String, active: Bool) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: active)
        #expect(routesToEngine(decision), "\"\(utterance)\" must never be tryFast")
    }

    /// One row per signal, so a regression names the signal that broke rather
    /// than just a failing utterance.
    static let signalCases: [(utterance: String, evidence: String)] = [
        ("update the pull request", "verb aimed at a bigram noun"),
        ("fix the errors in the stack trace", "verb aimed at the other bigram noun"),
        ("debug the parser", "verb + noun"),
        ("merge the branch", "verb + noun"),
        ("install the package", "verb + noun"),
        ("delete the old logs", "verb + noun"),
        ("test the build", "dual-role words in distinct positions still pair up"),
        ("undo", "unambiguous verb, no object at all"),
        ("deploy", "unambiguous verb, no object at all"),
        ("check src/main for the handler", "a slash means a path"),
        ("look at notes.txt", "file-extension token"),
        ("what does user_id mean", "snake_case beats the question form"),
        ("is renderFrame slow", "camelCase beats the question form"),
        ("`ls` please", "backticks mean literal code"),
        ("start fixing the bug", "-ing inflection pairs with a noun"),
        ("keep updating the tests", "-ing inflection of an e-dropping stem"),
        ("keep debugging the parser", "doubled-consonant -ing form"),
        ("try opening the log file", "undoubled -ing form of a doubling candidate"),
        ("she renamed the parser class", "-ed inflection pairs with a noun"),
        ("the script deletes the logs", "-s inflection pairs with a noun"),
        ("check what i wrote in the error log", "irregular past pairs with a noun"),
        ("change the error message", "everyday verb + noun"),
        ("remove the flaky test", "everyday verb + noun"),
        ("rewrite the parser", "everyday verb + noun"),
        ("make a new branch", "everyday verb + noun"),
        ("pushing the branch now", "inflected object-free verb pairs with a noun"),
        ("try committing the code", "doubled-consonant -ing of an object-free verb"),
        ("pushing code to production", "object-free inflection with a bare noun, no determiner"),
        ("undoing code changes", "undo inflects like any other stem"),
    ]

    @Test("Each engine signal fires on its own", arguments: signalCases)
    func signalsFireIndividually(_ testCase: (utterance: String, evidence: String)) {
        let decision = TaskEvidenceGate.classify(
            testCase.utterance, activeCodingConversation: false
        )
        #expect(
            routesToEngine(decision),
            "\"\(testCase.utterance)\" should hit the engine: \(testCase.evidence)"
        )
    }

    // MARK: - Questions may try the fast tier

    /// General questions with no task evidence. `.tryFast` is only permission
    /// to try — the on-device model has its own escape hatch — so the bar for
    /// this table is merely "nothing here looks like work". Several rows
    /// carry coding-verb forms on purpose ("wrote", "opening", "moves"): an
    /// inflected verb with no code noun to corroborate it must stay silent,
    /// or every chess question would crawl through an engine.
    static let questions: [String] = [
        "what's fifteen percent of 240",
        "how many ounces are in a liter",
        "when did the ottoman empire fall",
        "write a haiku about rain",
        "translate hello to japanese",
        "what should i cook tonight",
        "how do i say thank you in german",
        "who wrote the great gatsby",
        "define serendipity",
        "convert 30 celsius to fahrenheit",
        "what are the best opening moves in chess",
    ]

    @Test("General questions are offered to the fast tier", arguments: questions)
    func questionsMayTryFast(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: false)
        #expect(decision == .tryFast, "\"\(utterance)\" has no task evidence")
    }

    /// Vocabulary hits must be whole words. "committee" contains "commit" and
    /// "appendix" contains "app"; substring matching would send all of these
    /// to the engine. That misroute is only slow, not fatal — but it is
    /// exactly the creep that would eventually make the fast tier pointless.
    /// The last two rows guard the inflection generator the same way:
    /// "changelog" must not read as "change" even with a code noun sitting
    /// right next to it, and "remover" is not "remove".
    @Test("Word fragments are not evidence", arguments: [
        "when does the committee meet",
        "what's a fixture in the appendix",
        "what does deployment mean",
        "what's in a changelog file",
        "what's a good paint remover",
    ])
    func fragmentsAreNotEvidence(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: false)
        #expect(decision == .tryFast, "\"\(utterance)\" only contains fragments of vocabulary")
    }

    /// The object-free verbs stay exact-match when uncorroborated. Their
    /// inflections saturate ordinary speech — people push back, commit to
    /// plans, undo damage — so an inflected form with no code noun beside it
    /// must stay silent, or the engine would swallow everyday venting. The
    /// bare imperative ("push", "undo") still fires alone; only the
    /// inflections pay the corroboration tax.
    @Test("Uncorroborated object-free inflections are not evidence", arguments: [
        "stop pushing me",
        "she keeps committing to plans",
        "undoing years of progress",
    ])
    func objectFreeInflectionsNeedANoun(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: false)
        #expect(decision == .tryFast, "\"\(utterance)\" has no code noun to corroborate the verb")
    }

    /// "test" and "build" are both verb and noun, and the verb+noun signal
    /// needs one of each. A single occurrence must not play both roles, or
    /// every mention of the word would count as a task.
    @Test("One dual-role word is not a verb-noun pair")
    func dualRoleWordDoesNotPairWithItself() {
        let decision = TaskEvidenceGate.classify(
            "what is a test", activeCodingConversation: false
        )
        #expect(decision == .tryFast)
    }

    // MARK: - The coding-conversation signal

    /// Mid-session, an imperative with no other evidence still means the
    /// work: "make it faster" refers to the code just discussed, and the fast
    /// tier answering it in general terms would silently drop the request.
    @Test("Imperatives mid coding conversation mean the code", arguments: [
        "make it faster",
        "try again",
        "rename it",
        "clean that up",
    ])
    func imperativesMidSessionRouteToEngine(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: true)
        #expect(routesToEngine(decision), "\"\(utterance)\" mid-session refers to the work")
    }

    /// Politeness must not defeat the mid-session signal. "can you fix it"
    /// opens like a question and lands like an order; when auxiliaries sat in
    /// the interrogative exemption these leaked to the fast tier and the task
    /// was silently lost — the exact misroute the gate exists to prevent.
    @Test("Polite question-form imperatives mid-session mean the code", arguments: [
        "can you fix it",
        "could you clean that up",
        "would you rename it",
        "will you take another pass",
        "do it again",
    ])
    func politeImperativesMidSessionRouteToEngine(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: true)
        #expect(routesToEngine(decision), "\"\(utterance)\" mid-session is an order, not a question")
    }

    /// A pronoun hides the object: "why is it crashing" names no code noun,
    /// so every evidence signal misses, and the question exemption then waved
    /// the utterance through — mid-session, the commonest debugging questions
    /// all reached a model that cannot see the crash. A question built from
    /// work vocabulary mid-session IS the coding conversation, so the
    /// exemption must yield to it.
    static let troubleQuestions: [String] = [
        "why is it crashing",
        "how do i fix it",
        "what's wrong with it",
        "can you explain why it broke",
    ]

    @Test("Trouble questions mid-session are the coding conversation", arguments: troubleQuestions)
    func troubleQuestionsMidSessionRouteToEngine(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: true)
        #expect(routesToEngine(decision), "\"\(utterance)\" mid-session is about the work")
    }

    /// Outside a session the same questions have no referent: "how do i fix
    /// it" with no conversation behind it is a fair general question, and
    /// routing it engine-ward would slow every it-question ever spoken. The
    /// asymmetry with the test above is the whole value of the flag.
    @Test("The same trouble questions are fast-eligible outside a session", arguments: troubleQuestions)
    func troubleQuestionsOutsideSessionStayFast(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: false)
        #expect(decision == .tryFast, "\"\(utterance)\" has no referent outside a session")
    }

    /// The conversation signal must not swallow ordinary questions: being in
    /// a coding session doesn't make "what time is it" about the code. The
    /// contraction case guards the tokeniser — "what's" has to read as "what"
    /// — and the auxiliary-opener cases guard the carve-out that keeps the
    /// polite-imperative rule from eating real questions: "can you tell me
    /// what time it is" carries a wh-word after the "can", so it stays a
    /// question even though "can you fix it" does not.
    @Test("Interrogatives stay fast-eligible even mid coding conversation", arguments: [
        "what time is it",
        "how do i say thank you in german",
        "what's the capital of france",
        "can you tell me what time it is",
        "could you explain what a monad is",
        "why is the sky blue",
    ])
    func interrogativesMidSessionStayFast(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: true)
        #expect(decision == .tryFast, "\"\(utterance)\" is a question wherever it's asked")
    }

    /// Outside a session the same bare imperatives have no referent, so they
    /// carry no task evidence: the asymmetry between this test and the
    /// mid-session ones is the entire point of the `activeCodingConversation`
    /// flag. Only the bare forms earn this — the polite forms carry their
    /// own evidence and are pinned engine-ward in the test below.
    @Test("The same bare imperatives are fast-eligible outside a session", arguments: [
        "make it faster",
        "try again",
        "do it again",
    ])
    func imperativesOutsideSessionStayFast(_ utterance: String) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: false)
        #expect(decision == .tryFast)
    }

    /// The polite forms outlive the session. The mid-session defense above
    /// expires with the 30-minute window, and once it did, the politeness
    /// prefix walked "can you fix it" straight past the gate to a model that
    /// cannot fix anything — the misroute that loses work, found live rather
    /// than here. A work verb behind an auxiliary "you"-address is an order
    /// in any conversation state; the matrix runs both states to pin the "any".
    /// The question forms stay exempt — a wh-word after the auxiliary redeems
    /// "can you tell me what time it is" — which the interrogative tables
    /// above and below cover.
    @Test("Polite orders on work verbs route to the engine in any state", arguments: [
        "can you fix it",
        "would you rename it",
        "could you update it please",
        "can you run that again",
    ], [false, true])
    func politeOrdersRouteToEngineAnyState(_ utterance: String, active: Bool) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: active)
        #expect(routesToEngine(decision), "\"\(utterance)\" is an order whatever the session state")
    }

    // MARK: - The definite-referent signal

    /// After the 30-minute timeout both mid-session defenses vanish at once,
    /// but the referents in the user's head persist: "explain the parser"
    /// still means *their* parser, and the fast tier answered it with a
    /// confident description of some parser it invented. A definite
    /// determiner in front of a code noun is that referent made audible, so
    /// it must route to the engine in any conversation state — the matrix
    /// runs both states to pin down the "regardless".
    @Test("Definite references to code route to the engine in any state", arguments: [
        "explain the parser",
        "what does this error mean",
        "tell me about the pull request",
        "walk me through that stack trace",
        "what's in my logs",
    ], [false, true])
    func definiteReferencesRouteToEngine(_ utterance: String, active: Bool) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: active)
        #expect(routesToEngine(decision), "\"\(utterance)\" names a referent the fast tier has never seen")
    }

    /// The indefinite twins are general knowledge — exactly what the fast
    /// tier exists for. If "a parser" ever routes like "the parser", the
    /// signal has decayed into a code-noun blacklist and every vocabulary
    /// question crawls through an engine; the matrix runs both states so a
    /// session can't make an indefinite question definite.
    @Test("Indefinite references are general knowledge in any state", arguments: [
        "what does a parser do",
        "explain a parser",
        "what's a pull request",
        "what's a stack trace",
    ], [false, true])
    func indefiniteReferencesStayFast(_ utterance: String, active: Bool) {
        let decision = TaskEvidenceGate.classify(utterance, activeCodingConversation: active)
        #expect(decision == .tryFast, "\"\(utterance)\" refers to no particular code")
    }

    // MARK: - The length signal

    /// Nobody dictates 25+ words to ask a quick question; long utterances are
    /// briefs describing what to build. This one has no other signal in it —
    /// no coding verbs, no code nouns — so length alone must carry it.
    @Test("A long utterance is a brief even with no coding vocabulary")
    func longBriefRoutesToEngine() {
        let brief = """
            i was thinking we could plan a small party for grandma next month \
            and i want you to help me figure out the guest list the food and \
            the music
            """
        let decision = TaskEvidenceGate.classify(brief, activeCodingConversation: false)
        #expect(routesToEngine(decision))
    }

    /// The budget is "more than 24 words", and an off-by-one here moves the
    /// line silently — nothing else covers the exact boundary.
    @Test("The word budget boundary is exact")
    func wordBudgetBoundary() {
        let at = Array(repeating: "la", count: 24).joined(separator: " ")
        let over = Array(repeating: "la", count: 25).joined(separator: " ")
        #expect(TaskEvidenceGate.classify(at, activeCodingConversation: false) == .tryFast)
        #expect(routesToEngine(TaskEvidenceGate.classify(over, activeCodingConversation: false)))
    }

    // MARK: - Degenerate input

    /// An empty transcript has no evidence and nothing to lose; it must fall
    /// through quietly rather than crash a tokeniser expecting words.
    @Test("Empty and whitespace input degrades to tryFast", arguments: ["", "   ", "\n"])
    func emptyInputIsHarmless(_ utterance: String) {
        #expect(TaskEvidenceGate.classify(utterance, activeCodingConversation: false) == .tryFast)
        #expect(TaskEvidenceGate.classify(utterance, activeCodingConversation: true) == .tryFast)
    }
}
