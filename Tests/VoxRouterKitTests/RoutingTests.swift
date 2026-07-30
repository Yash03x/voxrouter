import Foundation
import Testing
@testable import VoxRouterKit

// MARK: - Fixtures
//
// These use the real wire shape captured from OpenUsage 0.7.7-beta.1, so the
// tests cover the decoder as well as the routing policy.

private func snapshot(claude: Double?, codex: Double?) throws -> QuotaSnapshot {
    func provider(_ id: String, _ name: String, _ load: Double) -> String {
        """
        {"displayName":"\(name)","providerId":"\(id)","plan":"Test",
         "fetchedAt":"2026-07-29T22:00:15.340Z",
         "lines":[
           {"limit":100,"type":"progress","label":"Weekly","used":\(load),
            "format":{"kind":"percent"},"periodDurationMs":604800000,
            "color":null,"resetsAt":"2026-08-05T06:26:45.000Z"},
           {"subtitle":null,"type":"text","label":"Credits","value":"$0.00","color":null},
           {"points":[{"valueLabel":"0 tokens","label":"1. Jul","value":0}],
            "type":"barChart","label":"Usage Trend","note":"est","color":null}
         ]}
        """
    }
    var parts: [String] = []
    if let claude { parts.append(provider("claude", "Claude", claude)) }
    if let codex { parts.append(provider("codex", "Codex", codex)) }
    let json = "[\(parts.joined(separator: ","))]"
    return QuotaSnapshot(
        providers: try JSONDecoder.openUsage().decode([ProviderUsage].self, from: Data(json.utf8))
    )
}

private func decode(_ json: String) throws -> [ProviderUsage] {
    try JSONDecoder.openUsage().decode([ProviderUsage].self, from: Data(json.utf8))
}

private func router(
    claude: Double?,
    codex: Double?,
    policy: RoutingPolicy = RoutingPolicy()
) async throws -> EngineRouter {
    let fixture = try snapshot(claude: claude, codex: codex)
    let monitor = QuotaMonitor { fixture }
    _ = try await monitor.refresh()
    return EngineRouter(policy: policy, monitor: monitor)
}

private func chosen(_ outcome: RoutingOutcome) -> RoutingDecision? {
    if case .dispatch(let decision) = outcome { return decision }
    return nil
}

private let both: Set<String> = ["claude", "codex"]

// MARK: - Decoding

@Suite("Quota decoding")
struct DecodingTests {
    @Test("Non-progress rows decode but never count as quota")
    func ignoresNonProgressRows() throws {
        let snap = try snapshot(claude: 42, codex: nil)
        let provider = try #require(snap.provider("claude"))
        #expect(provider.lines.count == 3)
        #expect(provider.windows.count == 1)
        #expect(provider.bindingLoad == 42)
    }

    @Test("A provider is as available as its most-constrained window")
    func bindingWindowIsTheMostConstrained() throws {
        let providers = try decode("""
        [{"providerId":"claude","displayName":"Claude","plan":"Max 20x","lines":[
          {"limit":100,"type":"progress","label":"Session","used":12,"format":{"kind":"percent"}},
          {"limit":100,"type":"progress","label":"Weekly","used":91,"format":{"kind":"percent"}},
          {"limit":100,"type":"progress","label":"Fable","used":3,"format":{"kind":"percent"}}
        ]}]
        """)
        #expect(providers[0].bindingLoad == 91)
        #expect(providers[0].bindingWindow?.label == "Weekly")
    }

    @Test("A response with no progress rows is flagged degraded, not read as 0%")
    func degradedWhenNoProgressRows() throws {
        let providers = try decode("""
        [{"providerId":"claude","lines":[{"type":"text","label":"Today","value":"$1.00"}]}]
        """)
        #expect(QuotaSnapshot(providers: providers).isDegraded)
    }

    @Test("Count-formatted rows normalise to percent")
    func nonPercentFormatIsNormalised() throws {
        let providers = try decode("""
        [{"providerId":"codex","lines":[
          {"limit":500,"type":"progress","label":"Requests","used":250,"format":{"kind":"count"}}
        ]}]
        """)
        #expect(providers[0].bindingLoad == 50)
    }

    @Test("Both ISO-8601 precisions parse")
    func parsesBothDatePrecisions() throws {
        let providers = try decode("""
        [{"providerId":"a","fetchedAt":"2026-07-29T22:00:15.340Z","lines":[
          {"limit":100,"type":"progress","label":"W","used":1,"format":{"kind":"percent"},
           "resetsAt":"2026-08-05T06:26:45Z"}
        ]}]
        """)
        #expect(providers[0].fetchedAt != nil)
        #expect(providers[0].windows.first?.resetsAt != nil)
    }

    @Test("Unknown line types are ignored rather than fatal")
    func toleratesUnknownLineTypes() throws {
        let providers = try decode("""
        [{"providerId":"x","lines":[
          {"type":"sparkline_v2","label":"New Thing","mystery":42},
          {"limit":100,"type":"progress","label":"W","used":7,"format":{"kind":"percent"}}
        ]}]
        """)
        #expect(providers[0].bindingLoad == 7)
    }
}

// MARK: - Routing

@Suite("Engine routing")
struct RoutingTests {
    @Test("Prefers the first listed engine when both are idle")
    func prefersFirstEngineWhenBothIdle() async throws {
        let r = try await router(claude: 0, codex: 0)
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "claude")
        #expect(!d.isCompromise)
    }

    /// Claude at 60% vs Codex at 5%: pure max-headroom routing would jump to
    /// Codex on every refresh. Hysteresis must hold while 60% is under
    /// high-water, because each switch costs a context handoff.
    @Test("Sticks with the incumbent even when the alternative is cooler")
    func sticksToIncumbent() async throws {
        let r = try await router(claude: 60, codex: 5)
        _ = await r.decide(installed: both)
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "claude")
    }

    @Test("Switches once the incumbent crosses high-water")
    func switchesPastHighWater() async throws {
        let r = try await router(claude: 90, codex: 10)
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "codex")
    }

    /// Both hot and within a couple of points of each other: a handoff buys
    /// nothing, so ride it out — but flag it rather than pretending it's fine.
    @Test("Rides out a hot engine when no alternative is meaningfully better")
    func staysPutWhenNothingIsFresh() async throws {
        let r = try await router(claude: 90, codex: 88)
        _ = await r.decide(installed: both)
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "codex")
        #expect(d.isCompromise, "should be flagged as a compromise, not silent")
    }

    /// A nearly-exhausted incumbent must yield to a merely-busy alternative,
    /// even though the alternative is above low-water.
    @Test("Switches to a not-fresh engine when it is meaningfully cooler")
    func switchesForMeaningfulGain() async throws {
        let r = try await router(claude: 95, codex: 75)
        await r.pin("claude")
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "codex", "20 points of headroom is worth the handoff")
    }

    /// The same gap low down must NOT trigger a switch — that's the thrash the
    /// hysteresis exists to prevent.
    @Test("A comfortable incumbent ignores a large headroom gap")
    func comfortableIncumbentIgnoresGap() async throws {
        let r = try await router(claude: 40, codex: 5)
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "claude")
    }

    @Test("Cold start says when the top preference is absent, not just busy")
    func explainsMissingPreferredEngine() async throws {
        let r = try await router(claude: 0, codex: 53)
        let d = try #require(chosen(await r.decide(installed: ["codex"])))
        #expect(d.engineId == "codex")
        #expect(d.reason.contains("claude not installed"))
    }

    @Test("Reports exhausted when every engine is past the hard ceiling")
    func exhaustedAboveCeiling() async throws {
        let r = try await router(claude: 99, codex: 98)
        guard case .exhausted(let retryAfter) = await r.decide(installed: both) else {
            Issue.record("expected exhausted")
            return
        }
        #expect(retryAfter != nil, "should say when quota frees up")
    }

    /// The dashboard refreshes on a ~5 min cycle, so a real 429 can arrive while
    /// quota still reads healthy. Failover must not wait for the next poll.
    @Test("A real rate-limit error fails over immediately, ignoring stale quota")
    func reactiveFailover() async throws {
        let r = try await router(claude: 10, codex: 20)
        let first = try #require(chosen(await r.decide(installed: both)))
        #expect(first.engineId == "claude")

        let second = try #require(
            chosen(await r.handleRateLimit(engineId: "claude", installed: both))
        )
        #expect(second.engineId == "codex")
    }

    @Test("Rate-limiting the only engine reports exhausted")
    func rateLimitOnLastEngine() async throws {
        let r = try await router(claude: 10, codex: nil)
        let outcome = await r.handleRateLimit(engineId: "claude", installed: ["claude"])
        guard case .exhausted = outcome else {
            Issue.record("expected exhausted, got \(outcome)")
            return
        }
    }

    @Test("Degraded quota data falls back to preference order and says so")
    func degradedFallsBackToPreference() async throws {
        let providers = try decode("""
        [{"providerId":"claude","lines":[{"type":"text","label":"Today","value":"$1"}]}]
        """)
        let fixture = QuotaSnapshot(providers: providers)
        let monitor = QuotaMonitor { fixture }
        _ = try await monitor.refresh()
        let r = EngineRouter(policy: RoutingPolicy(), monitor: monitor)

        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "claude")
        #expect(d.isCompromise, "degraded data must be flagged, not trusted")
    }

    @Test("A dead dashboard must not block work")
    func unreachableDashboardStillDispatches() async throws {
        struct Boom: Error {}
        let monitor = QuotaMonitor { throw Boom() }
        _ = try? await monitor.refresh()
        let r = EngineRouter(policy: RoutingPolicy(), monitor: monitor)

        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "claude")
        #expect(d.isCompromise)
    }

    @Test("An uninstalled engine is never chosen")
    func skipsUninstalledEngines() async throws {
        // Claude is idle and preferred, but absent — Codex must win anyway.
        let r = try await router(claude: 0, codex: 53)
        let d = try #require(chosen(await r.decide(installed: ["codex"])))
        #expect(d.engineId == "codex")
    }

    @Test("No installed engines is distinct from exhausted")
    func noEnginesAvailable() async throws {
        let r = try await router(claude: 0, codex: 0)
        #expect(await r.decide(installed: []) == .noEnginesAvailable)
    }

    @Test("Pinning overrides quota-based choice")
    func respectsPin() async throws {
        let r = try await router(claude: 0, codex: 0)
        await r.pin("codex")
        let d = try #require(chosen(await r.decide(installed: both)))
        #expect(d.engineId == "codex")
    }
}

// MARK: - Rate-limit detection

@Suite("Rate-limit sniffing")
struct RateLimitSnifferTests {
    @Test("Detects usage-limit phrasing")
    func detectsLimitPhrasing() {
        #expect(RateLimitSniffer.looksRateLimited(
            #"{"msg":{"type":"error","message":"You've reached your usage limit."}}"#
        ))
    }

    @Test("Ordinary output is not mistaken for a limit")
    func ignoresOrdinaryOutput() {
        #expect(!RateLimitSniffer.looksRateLimited("Reading file src/main.swift"))
        #expect(!RateLimitSniffer.looksRateLimited("Applied 3 edits, 0 errors"))
    }

    /// Bare status codes collide with token counts, byte sizes and ids, which is
    /// why they were removed from the patterns.
    @Test("Numbers that merely contain a status code are not limits")
    func bareNumbersAreNotLimits() {
        #expect(!RateLimitSniffer.looksRateLimited("wrote 429 bytes"))
        #expect(!RateLimitSniffer.looksRateLimited("input_tokens: 20401"))
        #expect(!RateLimitSniffer.looksUnavailable("session 401f3b2c"))
        #expect(!RateLimitSniffer.looksUnavailable("processed 403 files"))
    }

    @Test("Auth failures are classified as unavailable, not as quota")
    func authIsUnavailableNotQuota() {
        let line = "Failed to authenticate: OAuth session expired and could not be refreshed"
        #expect(RateLimitSniffer.looksUnavailable(line))
        #expect(!RateLimitSniffer.looksRateLimited(line))
        guard case .unavailable = RateLimitSniffer.classify(line) else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test("Parses a unix reset timestamp")
    func parsesUnixReset() {
        let line = #"{"rate_limits":{"primary":{"used_percent":100.0,"resets_at":1785825834}}}"#
        #expect(RateLimitSniffer.retryAfter(in: line)?.timeIntervalSince1970 == 1_785_825_834)
    }

    @Test("Parses a retry-after offset")
    func parsesRetryOffset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let parsed = RateLimitSniffer.retryAfter(in: "retry_after: 120 seconds", now: now)
        #expect(parsed?.timeIntervalSince1970 == 1_000_120)
    }
}

// MARK: - Engine output parsing

@Suite("Engine output parsing")
struct EngineParsingTests {
    @Test("Codex token_count surfaces a reached limit with its reset time")
    func codexLimitReached() throws {
        let line = #"{"type":"event_msg","msg":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1785825834},"rate_limit_reached_type":"primary"}}}"#
        guard case .rateLimited(_, let retryAfter) = CodexEngine().parse(line: line) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter?.timeIntervalSince1970 == 1_785_825_834)
    }

    @Test("A healthy token_count is not treated as a limit")
    func codexHealthyTokenCount() {
        let line = #"{"type":"event_msg","msg":{"type":"token_count","rate_limits":{"primary":{"used_percent":15.0,"resets_at":1785825834},"rate_limit_reached_type":null}}}"#
        guard case .raw = CodexEngine().parse(line: line) else {
            Issue.record("15% used is not a limit")
            return
        }
    }

    @Test("Codex exec commands become actions")
    func codexExtractsCommand() throws {
        let line = #"{"msg":{"type":"exec_command_begin","command":["swift","build"]}}"#
        guard case .action(let command) = CodexEngine().parse(line: line) else {
            Issue.record("expected action")
            return
        }
        #expect(command == "swift build")
    }

    @Test("Claude tool_use blocks become actions")
    func claudeExtractsToolUse() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}"#
        guard case .action(let name) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected action")
            return
        }
        #expect(name == "Edit")
    }

    @Test("Claude prose is surfaced as text")
    func claudeExtractsProse() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the leak."}]}}"#
        guard case .text(let prose) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected text")
            return
        }
        #expect(prose == "Fixed the leak.")
    }

    @Test("A Claude execution error is a failure, not a rate limit")
    func claudeResultError() throws {
        let line = #"{"type":"result","subtype":"error_during_execution","result":"disk full"}"#
        guard case .failed(let detail) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected failed")
            return
        }
        #expect(detail == "disk full")
    }

    @Test("A Claude usage-limit result is a rate limit")
    func claudeUsageLimitResult() {
        let line = #"{"type":"result","subtype":"error","result":"Claude usage limit reached"}"#
        guard case .rateLimited = ClaudeEngine().parse(line: line) else {
            Issue.record("expected rateLimited")
            return
        }
    }

    /// Regression for a costly live bug: Claude emits `rate_limit_event` on
    /// healthy runs with `status: "allowed"`. Text-sniffing the JSON matched
    /// "rate_limit", so a *completed* Claude run was discarded and re-run on
    /// Codex — double quota spend on every single task.
    @Test("A healthy rate_limit_event is not a rate limit")
    func healthyRateLimitEventIsIgnored() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1785420000,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false},"uuid":"b1db8da4","session_id":"b5e1b673"}"#
        guard case .raw = ClaudeEngine().parse(line: line) else {
            Issue.record("an allowed rate_limit_event must not trigger failover")
            return
        }
    }

    @Test("A rejected rate_limit_event is a rate limit, with its reset time")
    func rejectedRateLimitEventIsHonoured() throws {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1785420000,"rateLimitType":"five_hour"}}"#
        guard case .rateLimited(_, let retryAfter) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter?.timeIntervalSince1970 == 1_785_420_000)
    }

    /// The structural fix behind both cases above: protocol JSON is classified
    /// by its fields, never by substring match.
    @Test("Protocol JSON mentioning limits in passing is not sniffed")
    func structuredJsonIsNotTextSniffed() {
        // A tool result that happens to quote a limit message must not be read
        // as this engine hitting a limit.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"grep found: usage limit reached"}]}}"#
        guard case .raw = ClaudeEngine().parse(line: line) else {
            Issue.record("structured JSON must not be text-sniffed")
            return
        }
    }

    @Test("Malformed output degrades to raw instead of crashing")
    func toleratesGarbage() {
        guard case .raw = ClaudeEngine().parse(line: "{not json at all") else {
            Issue.record("expected raw")
            return
        }
    }

    @Test("Resume threads the session id through")
    func claudeResumeArgs() {
        let args = ClaudeEngine().arguments(for: "fix tests", resuming: "abc123")
        #expect(args.first == "-p")
        #expect(args.contains("--resume"))
        #expect(args.contains("abc123"))
    }

    @Test("Codex puts the task last so flags parse correctly")
    func codexArgOrder() {
        let args = CodexEngine().arguments(for: "fix tests", resuming: nil)
        #expect(args.first == "exec")
        #expect(args.last == "fix tests")
    }
}

/// Fixtures captured verbatim from `codex exec --json` on codex-cli
/// 0.146.0-alpha.3.1, which uses a different schema from older builds.
@Suite("Codex current-schema parsing")
struct CodexCurrentSchemaTests {
    @Test("thread.started yields the resumable thread id")
    func threadStarted() throws {
        let line = #"{"type":"thread.started","thread_id":"019fb004-5cd8-7263-a183-178555ea904c"}"#
        guard case .session(let id) = CodexEngine().parse(line: line) else {
            Issue.record("expected session")
            return
        }
        #expect(id == "019fb004-5cd8-7263-a183-178555ea904c")
    }

    @Test("An agent_message item becomes text")
    func agentMessageItem() throws {
        let line = #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"PONG"}}"#
        guard case .text(let text) = CodexEngine().parse(line: line) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "PONG")
    }

    /// The regression that motivated dual-schema support: codex emits an
    /// `error` item for advisory warnings and the turn still completes. Treating
    /// it as fatal failed every run on a config with unstable features enabled.
    @Test("An advisory error item is not a task failure")
    func advisoryErrorIsNotFatal() {
        let line = #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Under-development features enabled: chronicle. Under-development features are incomplete and may behave unpredictably."}}"#
        switch CodexEngine().parse(line: line) {
        case .failed:
            Issue.record("an advisory warning must not fail the run")
        case .status:
            break
        default:
            Issue.record("expected status")
        }
    }

    @Test("A rate-limit error item still fails over")
    func rateLimitErrorItem() {
        let line = #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"You have hit your usage limit. Try again later."}}"#
        guard case .rateLimited = CodexEngine().parse(line: line) else {
            Issue.record("expected rateLimited")
            return
        }
    }

    @Test("turn.failed is a real failure")
    func turnFailed() throws {
        let line = #"{"type":"turn.failed","error":{"message":"model refused"}}"#
        guard case .failed(let detail) = CodexEngine().parse(line: line) else {
            Issue.record("expected failed")
            return
        }
        #expect(detail == "model refused")
    }

    @Test("command_execution items become actions")
    func commandExecutionItem() throws {
        let line = #"{"type":"item.completed","item":{"id":"i","type":"command_execution","command":"swift build"}}"#
        guard case .action(let command) = CodexEngine().parse(line: line) else {
            Issue.record("expected action")
            return
        }
        #expect(command == "swift build")
    }

    @Test("file_change items name the touched paths")
    func fileChangeItem() throws {
        let line = #"{"type":"item.completed","item":{"id":"i","type":"file_change","changes":[{"path":"a.swift","kind":"modify"}]}}"#
        guard case .action(let detail) = CodexEngine().parse(line: line) else {
            Issue.record("expected action")
            return
        }
        #expect(detail.contains("a.swift"))
    }

    @Test("Items are reported once, on completion")
    func itemsReportedOnceOnly() {
        let started = #"{"type":"item.started","item":{"id":"i","type":"agent_message","text":"PONG"}}"#
        guard case .raw = CodexEngine().parse(line: started) else {
            Issue.record("item.started must not double-report")
            return
        }
    }

    @Test("turn.completed is a status, not a failure")
    func turnCompleted() {
        let line = #"{"type":"turn.completed","usage":{"input_tokens":20017,"output_tokens":6}}"#
        guard case .status = CodexEngine().parse(line: line) else {
            Issue.record("expected status")
            return
        }
    }

    @Test("The older schema still parses")
    func legacySchemaStillWorks() throws {
        let line = #"{"type":"event_msg","msg":{"type":"agent_message","message":"done"}}"#
        guard case .text(let text) = CodexEngine().parse(line: line) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "done")
    }

    @Test("Claude reports its session id for same-engine resume")
    func claudeSessionId() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
        guard case .session(let id) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected session")
            return
        }
        #expect(id == "abc-123")
    }
}
