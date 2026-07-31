import Foundation

/// The fast tier's backend: a local Ollama server.
///
/// Exists because without it every "what's fifteen percent of 240" was paying
/// for a twenty-second engine round trip and a slice of quota to answer a
/// question a local model handles in one second. Ollama is plain HTTP on
/// localhost, so this type is deliberately not availability-gated: it
/// compiles and runs on macOS 15, and the question still never leaves the
/// machine.
///
/// The same asymmetry as the rest of the tier governs every error path here:
/// answering a task the model can't do loses work, while escalating a question
/// merely answers it slowly — so refusals, timeouts, absent servers and
/// malformed replies all collapse to ordinary `escalated` values, and nothing
/// thrown in here can ever reach speech.
public struct OllamaAnswerer: QuickAnswerer {
    public let displayName = "ollama"

    /// Which model to ask for and where the server listens — config-driven,
    /// because both are the user's installation, not ours to guess.
    let model: String
    let baseURL: URL

    public init(model: String, baseURL: URL) {
        self.model = model
        self.baseURL = baseURL
    }

    /// How long the whole call gets before the question goes to the engine.
    ///
    /// Sized from measurement, not hope: warm answers came back in 0.81 s
    /// median, 1.07 s max, while a cold model load took 11.4 s. The deadline
    /// deliberately sits between the two — a question that lands mid-load
    /// escalates to the engine (slow, nothing lost) instead of holding the
    /// user in silence for the load. `prewarm()` plus `keepAlive` exist to
    /// make that cold path a once-per-session event.
    static let deadlineSeconds: TimeInterval = 8

    /// Idle bound on the URL request itself. A server that isn't there fails
    /// in milliseconds via connection refused — that's the everyday case on a
    /// Mac without Ollama and it must stay that fast. This bound is for the
    /// nastier failure, a socket that accepts and then stalls; two seconds is
    /// roughly double the measured warm maximum, so a healthy generation
    /// never trips it while a wedged one can't drag the tier to the 8 s
    /// deadline every single time.
    static let requestTimeout: TimeInterval = 2

    /// Model residency. The gap this buys is the whole fast tier: 11.4 s cold
    /// versus 0.81 s warm, so half an hour of residency turns the load into a
    /// once-per-session cost instead of a per-question one. Sent on every
    /// request, so ordinary use keeps extending it.
    static let keepAlive = "30m"

    /// These instructions are the product; edit with care.
    ///
    /// This exact wording was tuned and measured against local models — 12/12
    /// on the safety set with qwen2.5:7b, zero unsafe answers, zero
    /// over-escalations — so it is used verbatim. An earlier revision asked
    /// for a bare token reply ("reply with exactly ESCALATE") and small models
    /// ignored that contract 100% of the time; the structured
    /// `can_answer=false` hand-off below is what they actually obey. The
    /// phrase is a contract with the schema in `formatJSON`; rename one and
    /// the other must follow, or every hand-off becomes a decode failure.
    /// "Weigh it in thought first" leans on the schema putting `thought`
    /// before the verdict.
    static let systemPrompt = """
        You are the quick-answer layer of a Mac voice assistant. You handle \
        everyday questions yourself: mental arithmetic, unit conversions, \
        general knowledge, word definitions, translations, short creative \
        writing, cooking ideas, casual advice. Answer those confidently in \
        one or two short spoken sentences of plain text, in the same language \
        the user spoke. Hand off (can_answer=false) only when the request: \
        asks to DO something on the computer (fix, change, delete, run, open, \
        send), needs live information like weather, news, sports or the \
        current time, needs the user's personal files, apps or data, or is \
        something you genuinely do not know. Weigh it in thought first, \
        briefly.
        """

    /// The reply schema, as raw JSON rather than a serialised dictionary.
    ///
    /// The property order is load-bearing, not cosmetic: a small model that
    /// must emit `can_answer` before any reasoning reverts to overconfident
    /// yes-answers, while one forced to write its `thought` first hands off
    /// reliably — measured, not assumed. Dictionary-based JSON serialisation
    /// shuffles keys, which would silently reorder the generation and undo
    /// the measured behaviour, so the schema is written out by hand.
    static let formatJSON = """
        {"type":"object","properties":{"thought":{"type":"string"},\
        "can_answer":{"type":"boolean"},"answer":{"type":"string"}},\
        "required":["thought","can_answer","answer"]}
        """

    /// Where generation requests go.
    var generateURL: URL { baseURL.appendingPathComponent("api/generate") }

    public func answer(_ question: String, context: String?) async -> QuickAnswerOutcome {
        // A `let` by the time the race captures it — the deadline closure is
        // @Sendable, and a mutable capture wouldn't compile under strict
        // concurrency anyway.
        let request: URLRequest = {
            var request = URLRequest(url: generateURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = Self.requestTimeout
            request.httpBody = Self.requestBody(
                model: model,
                prompt: Self.promptText(for: question, context: context)
            )
            return request
        }()

        do {
            let outcome = try await withDeadline(seconds: Self.deadlineSeconds) {
                () -> QuickAnswerOutcome in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    // The server is up but can't serve this request — most
                    // often the configured model was never pulled. There is
                    // nothing to retry and nothing to say, so it reads the
                    // same as no server at all.
                    Log.dispatch.notice("ollama answer: non-200, escalating")
                    return .escalated(.unavailable)
                }
                return Self.parseResponseBody(data)
            }
            guard let outcome else {
                Log.dispatch.notice("ollama answer: no reply within deadline, escalating")
                return .escalated(.timedOut)
            }
            return outcome
        } catch let error as URLError where error.code == .timedOut {
            // The idle bound tripping is the opposite diagnosis from the
            // branch below: this server completed the handshake and then went
            // silent, so logging it as "unreachable" would send whoever is
            // debugging off to check a server that is demonstrably listening.
            // It must not read as `.unavailable` either — that is the one
            // outcome `ChainedAnswerer` skips past, so a wedged server would
            // be silently shopped to the next backend after already costing
            // the question two seconds. A stall, like the 8 s deadline, is
            // this tier deciding the engine should take over.
            Log.dispatch.notice("ollama stalled: reachable but idle past the request timeout, escalating")
            return .escalated(.timedOut)
        } catch {
            // Connection refused lands here, in milliseconds — the everyday
            // case on a Mac without Ollama installed. It must be quiet and
            // cheap: this branch runs on every quick question such a machine
            // ever asks.
            Log.dispatch.notice(
                "ollama unreachable, escalating: \(error.localizedDescription, privacy: .public)"
            )
            return .escalated(.unavailable)
        }
    }

    /// Warms the model before the first question.
    ///
    /// An empty prompt makes Ollama load the model and generate nothing —
    /// the documented idiom for triggering residency. Fire-and-forget: any
    /// failure means the first real question pays the cold load or escalates,
    /// which is exactly what would have happened without prewarming. The
    /// generous timeout is deliberate — this request *is* the 11.4 s load,
    /// and cutting it short client-side risks abandoning the very work it
    /// exists to do early.
    public func prewarm() async {
        var request = URLRequest(url: generateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = Self.prewarmBody(model: model)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Wire format

    /// Assembles the generation request by hand, for the same reason
    /// `formatJSON` is a string literal: `JSONSerialization` and `JSONEncoder`
    /// both shuffle dictionary keys, and the schema's property order is what
    /// makes the model reason before it judges. Only the two caller-supplied
    /// strings need escaping, and those go through real JSON encoding.
    static func requestBody(model: String, prompt: String) -> Data {
        let body = """
            {"model":\(jsonString(model)),\
            "system":\(jsonString(systemPrompt)),\
            "prompt":\(jsonString(prompt)),\
            "stream":false,\
            "format":\(formatJSON),\
            "options":{"temperature":0.2},\
            "keep_alive":\(jsonString(keepAlive))}
            """
        return Data(body.utf8)
    }

    /// The prewarm request: model and residency, no prompt, no schema.
    static func prewarmBody(model: String) -> Data {
        let body = """
            {"model":\(jsonString(model)),"prompt":"","stream":false,\
            "keep_alive":\(jsonString(keepAlive))}
            """
        return Data(body.utf8)
    }

    /// JSON-escapes one string. Encoding a bare string cannot actually fail;
    /// the fallback exists only because the API is typed as throwing, and an
    /// empty literal beats crashing the answer path on the impossible.
    private static func jsonString(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: .fragmentsAllowed
            )
        else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ollama's non-streaming reply: the generated text arrives as a JSON
    /// string in `response`, which — because the request carried a schema —
    /// is itself a JSON document.
    private struct GenerateResponse: Decodable {
        let response: String
    }

    /// The inner document the schema forced the model to produce. `thought`
    /// is deliberately not decoded: its entire job is done at generation
    /// time, and reading it back would only tempt someone to speak it.
    private struct QuickReply: Decodable {
        let canAnswer: Bool
        let answer: String?

        enum CodingKeys: String, CodingKey {
            case canAnswer = "can_answer"
            case answer
        }
    }

    /// Turns a 200 body into an outcome — the last guard before speech.
    ///
    /// Both decode layers failing read as `failed`, not `modelDeclined`: a
    /// server that returns unparseable bytes is broken, and the log should
    /// say so rather than dress it up as the model's judgement. A parsed
    /// verdict is necessary but not sufficient — `parseReply` still collapses
    /// whitespace for speech, treats an empty answer as declining, and
    /// catches a model that says can_answer=true while writing a bail-out
    /// token into the answer field.
    static func parseResponseBody(_ data: Data) -> QuickAnswerOutcome {
        guard let outer = try? JSONDecoder().decode(GenerateResponse.self, from: data),
              let reply = try? JSONDecoder().decode(QuickReply.self, from: Data(outer.response.utf8))
        else {
            Log.dispatch.error("ollama answer: malformed reply, escalating")
            return .escalated(.failed)
        }
        guard reply.canAnswer else { return .escalated(.modelDeclined) }
        return QuickAnswerOutcome.parseReply(reply.answer ?? "")
    }
}
