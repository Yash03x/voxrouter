import Foundation
import Testing
@testable import VoxRouterKit

@Suite("Ollama request format")
struct OllamaRequestTests {
    /// The request must decode as JSON with every measured knob in place —
    /// a malformed body wouldn't fail loudly, it would 400 and quietly turn
    /// the whole backend into an escalation machine.
    @Test("The generate request carries the tuned knobs")
    func requestCarriesKnobs() throws {
        let body = OllamaAnswerer.requestBody(model: "qwen2.5:7b", prompt: "two plus two")
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(object["model"] as? String == "qwen2.5:7b")
        #expect(object["prompt"] as? String == "two plus two")
        #expect(object["stream"] as? Bool == false)
        #expect(object["keep_alive"] as? String == "30m")
        let options = try #require(object["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0.2)
        let format = try #require(object["format"] as? [String: Any])
        #expect(format["required"] as? [String] == ["thought", "can_answer", "answer"])
    }

    /// The system prompt is the tuned, measured wording — and its
    /// `can_answer=false` phrase is a contract with the schema's field name.
    /// Rename either alone and every hand-off becomes a decode failure with
    /// the model left no taught way to bail.
    @Test("The system prompt travels verbatim and names the hand-off field")
    func systemPromptContract() throws {
        let body = OllamaAnswerer.requestBody(model: "m", prompt: "q")
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let system = try #require(object["system"] as? String)

        #expect(system == OllamaAnswerer.systemPrompt)
        #expect(system.hasPrefix("You are the quick-answer layer"))
        #expect(system.contains("can_answer=false"))
        #expect(OllamaAnswerer.formatJSON.contains("\"can_answer\""))
    }

    /// The schema's property order is the design: reasoning first, verdict
    /// after. A serializer that shuffled keys would silently let the model
    /// judge before it thinks — the measured cause of overconfident
    /// yes-answers — so the byte order of the format block is asserted, not
    /// its parsed shape.
    @Test("Schema properties stay in reasoning-first order on the wire")
    func schemaOrderSurvivesSerialisation() throws {
        let raw = String(decoding: OllamaAnswerer.requestBody(model: "m", prompt: "q"), as: UTF8.self)
        let thought = try #require(raw.range(of: "\"thought\""))
        let canAnswer = try #require(raw.range(of: "\"can_answer\""))
        let answer = try #require(raw.range(of: "\"answer\""))
        #expect(thought.lowerBound < canAnswer.lowerBound)
        #expect(canAnswer.lowerBound < answer.lowerBound)
    }

    /// Spoken questions contain quotes, newlines and umlauts; any of them
    /// breaking the hand-assembled JSON would fail every question that used
    /// one.
    @Test("Prompt text needing escapes survives the round trip")
    func promptEscaping() throws {
        let tricky = "say \"hi\"\nto the café — 15% of 240?"
        let body = OllamaAnswerer.requestBody(model: "m", prompt: tricky)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["prompt"] as? String == tricky)
    }

    /// The prewarm request must name the model and residency and nothing
    /// else — an accidental format or system field would make Ollama
    /// generate instead of just load.
    @Test("Prewarm requests only the load")
    func prewarmBodyIsMinimal() throws {
        let body = OllamaAnswerer.prewarmBody(model: "qwen2.5:7b")
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["model"] as? String == "qwen2.5:7b")
        #expect(object["prompt"] as? String == "")
        #expect(object["keep_alive"] as? String == "30m")
        #expect(object["format"] == nil)
        #expect(object["system"] == nil)
    }
}

@Suite("Ollama reply parsing")
struct OllamaReplyParsingTests {
    /// Ollama wraps the generated document in an outer envelope; builds one
    /// the way the server does.
    private func envelope(_ inner: String) throws -> Data {
        try JSONEncoder().encode(["response": inner])
    }

    @Test("A confident reply becomes a spoken answer")
    func confidentReplyAnswers() throws {
        let data = try envelope(
            #"{"thought":"easy arithmetic","can_answer":true,"answer":"It's 36."}"#
        )
        #expect(OllamaAnswerer.parseResponseBody(data) == .answered("It's 36."))
    }

    /// Answers are spoken, not shown — the same collapse `parseReply` gives
    /// every backend must apply here too.
    @Test("Answer whitespace is collapsed for speech")
    func collapsesWhitespace() throws {
        let data = try envelope(
            #"{"thought":"t","can_answer":true,"answer":"Paris is\nthe capital."}"#
        )
        #expect(OllamaAnswerer.parseResponseBody(data) == .answered("Paris is the capital."))
    }

    @Test("A structured hand-off escalates as the model declining")
    func handOffDeclines() throws {
        let data = try envelope(
            #"{"thought":"needs live weather data","can_answer":false,"answer":""}"#
        )
        #expect(OllamaAnswerer.parseResponseBody(data) == .escalated(.modelDeclined))
    }

    /// The verdict alone is not enough: a model that says can_answer=true
    /// while producing nothing speakable — or a bail-out token — has still
    /// declined, and speaking its reply would answer the user with silence
    /// or the word "escalate".
    @Test("A confident verdict with no speakable answer still declines", arguments: [
        #"{"thought":"t","can_answer":true,"answer":""}"#,
        #"{"thought":"t","can_answer":true,"answer":"   "}"#,
        #"{"thought":"t","can_answer":true,"answer":"ESCALATE."}"#,
    ])
    func emptyAnswerDeclines(inner: String) throws {
        let data = try envelope(inner)
        #expect(OllamaAnswerer.parseResponseBody(data) == .escalated(.modelDeclined))
    }

    /// Undecodable bytes are the server misbehaving, not the model judging —
    /// the log must say `failed`, not dress it up as a decline.
    @Test("Malformed replies escalate as failed", arguments: [
        "not json at all",
        #"{"thought":"t"}"#,
        #"{"can_answer":"yes","answer":"x"}"#,
    ])
    func malformedInnerFails(inner: String) throws {
        let data = try envelope(inner)
        #expect(OllamaAnswerer.parseResponseBody(data) == .escalated(.failed))
    }

    @Test("A body that isn't the API envelope escalates as failed")
    func malformedOuterFails() {
        let data = Data("<html>502 Bad Gateway</html>".utf8)
        #expect(OllamaAnswerer.parseResponseBody(data) == .escalated(.failed))
    }
}

@Suite("Ollama answerer")
struct OllamaAnswererTests {
    /// The everyday case on a Mac without Ollama: nothing is listening, and
    /// the tier must get out of the way in milliseconds — via connection
    /// refused — not sit out a timeout on every quick question the machine
    /// ever hears. The generous bound is for loaded CI hosts; the point is
    /// that it fails well under the 8 s deadline.
    @Test("A dead server escalates as unavailable, fast")
    func deadServerEscalatesFast() async throws {
        let answerer = OllamaAnswerer(
            model: "qwen2.5:7b",
            // Port 1 is reserved and never listening on a Mac, so connecting
            // refuses immediately.
            baseURL: try #require(URL(string: "http://127.0.0.1:1"))
        )
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await answerer.answer("what is two plus two", context: nil)
        let elapsed = clock.now - start

        #expect(outcome == .escalated(.unavailable))
        #expect(elapsed < .seconds(3), "took \(elapsed); an absent server must fail fast")
    }

    /// A listening TCP socket whose connections are never accepted or
    /// answered. The kernel completes the handshake for backlogged
    /// connections without any userspace help, so bind-plus-listen alone
    /// simulates the nasty failure the idle bound exists for: a server that
    /// is reachable and then says nothing.
    private struct StalledServer {
        struct SetupFailed: Error {}

        let port: UInt16
        private let fd: Int32

        init() throws {
            // Locals throughout: touching a stored property from inside the
            // pointer closures would capture `self` before it is fully
            // initialized, which Swift rejects.
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw SetupFailed() }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0  // Ephemeral: the kernel picks a free port.
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(socketFD, 4) == 0 else {
                close(socketFD)
                throw SetupFailed()
            }

            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socketFD, $0, &length)
                }
            }
            guard named == 0 else {
                close(socketFD)
                throw SetupFailed()
            }
            fd = socketFD
            port = UInt16(bigEndian: assigned.sin_port)
        }

        func stop() { close(fd) }
    }

    /// A wedged-but-listening server is not an absent one: it must escalate
    /// as `.timedOut`, which the chain treats as tier-final, not as
    /// `.unavailable`, which the chain skips past — a stall has already cost
    /// the question the idle bound, and shopping it to another backend would
    /// stack more latency on top. The timing assertion carries half the test:
    /// the 8 s deadline *also* reads as `.timedOut`, so only finishing well
    /// before it proves the 2 s idle bound was what tripped.
    @Test("A stalled-but-listening server escalates as timed out, before the deadline")
    func stalledServerEscalatesAsTimedOut() async throws {
        let server = try StalledServer()
        defer { server.stop() }
        let answerer = OllamaAnswerer(
            model: "qwen2.5:7b",
            baseURL: try #require(URL(string: "http://127.0.0.1:\(server.port)"))
        )
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await answerer.answer("what is two plus two", context: nil)
        let elapsed = clock.now - start

        #expect(outcome == .escalated(.timedOut))
        #expect(
            elapsed < .seconds(7),
            "took \(elapsed); the 2 s idle bound, not the 8 s deadline, must trip"
        )
    }

    /// Live round trip against a local Ollama. A no-op unless a server
    /// answers the probe — guarded rather than skipped so it exercises the
    /// real wire format on any machine that has one, without anyone flipping
    /// a test flag. A reachable server may legitimately decline, time out
    /// cold, or lack the model entirely; what it must never do is trip the
    /// malformed-reply path, which would mean this code misreads the real
    /// API.
    @Test("Live round trip returns a spoken-ready outcome")
    func liveRoundTrip() async {
        let config = Config.default
        var probe = URLRequest(url: config.ollamaBaseURL)
        probe.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: probe),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }

        let answerer = OllamaAnswerer(model: config.ollamaModel, baseURL: config.ollamaBaseURL)
        await answerer.prewarm()
        let outcome = await answerer.answer("What colour is a clear daytime sky?", context: nil)
        switch outcome {
        case .answered(let text):
            #expect(!text.isEmpty)
            #expect(!text.contains("\n"), "answers must be collapsed for speech")
        case .escalated(let reason):
            #expect(reason != .failed, "a live server must not read as malformed")
        }
    }
}
