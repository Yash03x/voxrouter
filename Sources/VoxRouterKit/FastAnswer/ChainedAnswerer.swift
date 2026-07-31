import Foundation

/// Tries each fast-answer backend in order, settling for the first one that
/// is actually present.
///
/// Exists because availability is a runtime fact, not a build-time one:
/// Ollama is a server the user can stop mid-session or never install, and
/// any backend added later will have its own way of being absent. Baking
/// "which backend?" into construction would freeze an answer to a question
/// that keeps changing, so the chain asks every time — each backend reports
/// its own absence as `.escalated(.unavailable)` fast, and the chain simply
/// moves past it.
///
/// Only *absence* falls through. A backend that timed out, failed, or —
/// especially — judged the question beyond it (`modelDeclined`) is a final
/// answer for the whole tier: one small model has already weighed the
/// question, and deferring to a second small model of the same class would
/// double the latency before the engine gets it without changing the verdict
/// the engine path was built to absorb. Escalating is the cheap misroute;
/// shopping a request around models until one overconfidently takes it is
/// the expensive one.
public struct ChainedAnswerer: QuickAnswerer {
    /// Preference order: earlier backends get first refusal.
    let backends: [any QuickAnswerer]

    public init(_ backends: [any QuickAnswerer]) {
        self.backends = backends
    }

    public var displayName: String {
        backends.map(\.displayName).joined(separator: "→")
    }

    /// The standard chain for this machine and config: Ollama, alone.
    ///
    /// A chain of one is kept deliberately — the chain, not any backend, is
    /// what the pipeline holds, so adding a backend later (an API, a
    /// different local runtime) is one `QuickAnswerer` conformance appended
    /// here, in one file, with no pipeline change. No availability decision
    /// is made at construction: whether the Ollama server is actually
    /// *there* is checked per question inside `OllamaAnswerer.answer` — a
    /// user who stops it mid-session gets a fast `.unavailable` instead of
    /// a stale construction-time verdict in either direction.
    public static func standard(config: Config) -> ChainedAnswerer {
        ChainedAnswerer([
            OllamaAnswerer(model: config.ollamaModel, baseURL: config.ollamaBaseURL)
        ])
    }

    public func answer(_ question: String, context: String?) async -> QuickAnswerOutcome {
        await attributedAnswer(question, context: context).outcome
    }

    /// `answer`, plus *which* backend settled it — nil when none was there.
    /// Separate method rather than richer protocol plumbing: only the CLI's
    /// reporting wants the name, and the pipeline's speech path must stay a
    /// plain outcome.
    public func attributedAnswer(
        _ question: String, context: String?
    ) async -> (outcome: QuickAnswerOutcome, backend: String?) {
        for backend in backends {
            let outcome = await backend.answer(question, context: context)
            guard outcome != .escalated(.unavailable) else { continue }
            return (outcome, backend.displayName)
        }
        // Every backend absent — for the caller this is indistinguishable
        // from the single-backend tier being off, which is exactly right.
        return (.escalated(.unavailable), nil)
    }

    /// Prewarms every backend, concurrently: Ollama's cold load is measured
    /// in seconds, and making any other backend queue behind it — or vice
    /// versa — would reintroduce at launch the very latency prewarming
    /// exists to hide.
    public func prewarm() async {
        await withTaskGroup(of: Void.self) { group in
            for backend in backends {
                group.addTask { await backend.prewarm() }
            }
        }
    }
}
