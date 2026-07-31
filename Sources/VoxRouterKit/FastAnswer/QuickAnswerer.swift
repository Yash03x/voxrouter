import Foundation

/// What the fast-answer tier did with a question.
///
/// The two ways to misroute are not symmetric. A question escalated to an
/// engine is merely answered slowly; a real task answered by the small model is
/// work silently not done — the user was told something confident and nothing
/// happened. So every state except a produced answer collapses to `escalated`,
/// and the pipeline treats escalation as the boring, safe default rather than
/// as an error.
public enum QuickAnswerOutcome: Equatable, Sendable {
    /// A spoken answer, already flattened to a single line for TTS.
    case answered(String)
    /// The question belongs to an engine. The reason is carried for logging
    /// only — every escalation is handled identically, but a machine that
    /// times out constantly and one whose model is switched off are debugged
    /// very differently.
    case escalated(QuickEscalation)
}

/// Why the fast tier passed on a question.
public enum QuickEscalation: Equatable, Sendable {
    /// The model itself said the question is beyond it, or said nothing.
    case modelDeclined
    /// The backend isn't there — the Ollama server isn't running, or the
    /// configured model was never pulled.
    case unavailable
    /// No reply arrived within the deadline.
    case timedOut
    /// The call threw — guardrail refusals surface this way.
    case failed
}

/// The seam between the voice pipeline and whichever local model answers.
///
/// Kept as a protocol even with a single conforming backend: the pipeline
/// holds this seam, not a concrete type, so another backend — an API, a
/// different local runtime — is one new conformance in one file, with no
/// pipeline change. The protocol keeps implementations honest by having no
/// way to fail loudly — an error thrown from this layer would otherwise end
/// up being read aloud.
public protocol QuickAnswerer: Sendable {
    /// Short name for logs and the CLI — "ollama". Exists so the
    /// tier can say *which* backend produced an outcome: with more than one,
    /// "the fast tier answered" is undebuggable when only one of them is
    /// misbehaving.
    var displayName: String { get }
    /// Answers the question or explains why it won't. Never throws.
    ///
    /// - Parameter context: an optional digest of the conversation so far, so
    ///   "how tall is that in metres" can follow "how tall is Everest".
    func answer(_ question: String, context: String?) async -> QuickAnswerOutcome
    /// Loads model state ahead of the first question, so the cold start is
    /// paid at launch rather than inside someone's first answer.
    func prewarm() async
}

extension QuickAnswerer {
    /// Builds the prompt, prepending the conversation digest when there is
    /// one. Shared by every backend so the continuity framing cannot drift
    /// between them — two models seeing two different transcript shapes would
    /// answer the same follow-up differently. Kept pure so the assembly is
    /// testable without any model. An empty digest is treated as absent — a
    /// heading with nothing under it reads to the model like a corrupted
    /// transcript.
    static func promptText(for question: String, context: String?) -> String {
        guard let context, !context.isEmpty else { return question }
        return """
        Earlier in this conversation:
        \(context)

        \(question)
        """
    }
}

extension QuickAnswerOutcome {
    /// Turns a raw candidate answer into an outcome — the last guard before
    /// speech.
    ///
    /// The model has one structured way to bail, but small models also bail
    /// in prose: the bare token `ESCALATE`, decorated anyway — "ESCALATE.",
    /// quotes, markdown emphasis, stray whitespace. Missing a decorated token
    /// would speak the word "escalate" at the user and drop their question, so
    /// the check strips surrounding whitespace and punctuation before
    /// comparing.
    ///
    /// Models that bail also like to narrate why — "ESCALATE — this needs the
    /// web" — and speaking the narration would present the bail-out to the
    /// user as an answer. So a reply whose *first* word, once stripped of the
    /// same decoration, is the all-caps token escalates too. That leading
    /// check is case-sensitive where the bare-token check is not: a sentence
    /// that merely opens with the word ("Escalate means to increase…") is
    /// ordinary prose, and the model does not open real answers in all caps.
    /// It stops there deliberately: a reply that contains the word
    /// mid-sentence ("you should escalate this to your manager") is an answer
    /// *about* escalation, and discarding it would throw away exactly the
    /// fast answers this tier exists to give.
    ///
    /// Answers are collapsed to single spaces because they are spoken, not
    /// shown: newlines and doubled spaces are formatting the synthesiser
    /// would either ignore or stumble over. A reply with nothing speakable in
    /// it at all — empty, whitespace, bare punctuation like "..." — counts as
    /// the model declining, since speaking it would produce silence anyway.
    static func parseReply(_ raw: String) -> QuickAnswerOutcome {
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return .escalated(.modelDeclined) }
        let collapsed = words.joined(separator: " ")

        let core = collapsed.trimmingCharacters(in: Self.decoration)
        guard !core.isEmpty else { return .escalated(.modelDeclined) }
        guard core.lowercased() != "escalate" else { return .escalated(.modelDeclined) }
        if let first = core.split(whereSeparator: \.isWhitespace).first,
            String(first).trimmingCharacters(in: Self.decoration) == "ESCALATE" {
            return .escalated(.modelDeclined)
        }
        return .answered(collapsed)
    }

    /// What models wrap the bare token in: quotes, sentence punctuation,
    /// markdown emphasis. All Unicode punctuation plus whitespace.
    private static let decoration = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)
}
