import Foundation

public struct RoutingPolicy: Codable, Sendable {
    /// Tie-break order when several engines are comfortably available.
    public var preferenceOrder: [String]
    /// Above this load on the current engine, start looking for somewhere else.
    public var highWater: Double
    /// Only switch *to* an engine below this load. The gap between high and low
    /// water is the hysteresis band that stops flip-flopping.
    public var lowWater: Double
    /// Escape hatch on `lowWater`: switch to an engine that isn't "fresh" anyway
    /// when it is at least this many points cooler than the incumbent. Without
    /// this, a nearly-exhausted engine at 95% would be held onto in preference
    /// to one at 75%, purely because 75% is above low-water.
    public var minimumSwitchGain: Double
    /// Never dispatch to an engine at or above this — too likely to die mid-task.
    public var hardCeiling: Double
    /// How long to sideline an engine that returned a rate-limit error when we
    /// have no reset time to go on.
    public var blindCooldown: TimeInterval

    public init(
        preferenceOrder: [String] = ["claude", "codex"],
        highWater: Double = 85,
        lowWater: Double = 70,
        minimumSwitchGain: Double = 15,
        hardCeiling: Double = 97,
        blindCooldown: TimeInterval = 30 * 60
    ) {
        self.preferenceOrder = preferenceOrder
        self.highWater = highWater
        self.lowWater = lowWater
        self.minimumSwitchGain = minimumSwitchGain
        self.hardCeiling = hardCeiling
        self.blindCooldown = blindCooldown
    }
}

public struct RoutingDecision: Sendable, Equatable {
    public let engineId: String
    public let reason: String
    public let load: Double
    /// True when we're continuing on an engine we'd rather leave, because the
    /// alternatives are no better.
    public let isCompromise: Bool
}

public enum RoutingOutcome: Sendable, Equatable {
    case dispatch(RoutingDecision)
    /// Everything is spent. `retryAfter` is the earliest known reset.
    case exhausted(retryAfter: Date?)
    /// No engine is even installed.
    case noEnginesAvailable
}

/// Picks an engine from a warm quota snapshot.
///
/// Deliberately *sticky*. Routing purely on "whoever has the most headroom"
/// looks right and behaves badly: engines trade places on every refresh, and
/// each switch costs a context handoff. So we stay put until the current engine
/// crosses `highWater`, then move only to an engine below `lowWater`.
public actor EngineRouter {
    private var policy: RoutingPolicy
    private let monitor: QuotaMonitor
    /// The engine we're currently sticking to.
    private var incumbent: String?

    public init(policy: RoutingPolicy, monitor: QuotaMonitor) {
        self.policy = policy
        self.monitor = monitor
    }

    public func updatePolicy(_ policy: RoutingPolicy) { self.policy = policy }

    public func currentIncumbent() -> String? { incumbent }

    /// Force the incumbent, e.g. when the user says "use codex for this".
    public func pin(_ engineId: String?) { incumbent = engineId }

    /// - Parameter installed: engine ids that actually have a working binary.
    public func decide(installed: Set<String>, now: Date = Date()) async -> RoutingOutcome {
        let state = await monitor.current()

        let candidateIds = policy.preferenceOrder.filter { installed.contains($0) }
        guard !candidateIds.isEmpty else { return .noEnginesAvailable }

        // Without usable quota data, fall back to plain preference order rather
        // than pretending everything is at 0%.
        guard let snapshot = state.snapshot, !snapshot.isDegraded else {
            let fallback = candidateIds.first { !state.isLocallyExhausted($0, now: now) }
            guard let engineId = fallback else {
                return .exhausted(retryAfter: state.localExhaustion.values.min())
            }
            incumbent = engineId
            return .dispatch(RoutingDecision(
                engineId: engineId,
                reason: state.snapshot == nil
                    ? "no quota data (\(state.lastError ?? "dashboard unreachable")) — using preference order"
                    : "quota data unusable — using preference order",
                load: 0,
                isCompromise: true
            ))
        }

        struct Candidate {
            let id: String
            let load: Double
            let reset: Date?
        }

        let candidates: [Candidate] = candidateIds.compactMap { id in
            guard !state.isLocallyExhausted(id, now: now) else { return nil }
            let provider = snapshot.provider(id)
            return Candidate(
                id: id,
                load: provider?.bindingLoad ?? 0,
                reset: provider?.bindingReset
            )
        }

        let usable = candidates.filter { $0.load < policy.hardCeiling }
        guard !usable.isEmpty else {
            let resets = candidates.compactMap(\.reset) + state.localExhaustion.values
            return .exhausted(retryAfter: resets.min())
        }

        // 1. Stay on the incumbent while it's comfortable.
        if let incumbent, let held = usable.first(where: { $0.id == incumbent }),
           held.load < policy.highWater {
            return .dispatch(RoutingDecision(
                engineId: held.id,
                reason: "holding \(held.id) at \(pct(held.load)) (under \(pct(policy.highWater)) high-water)",
                load: held.load,
                isCompromise: false
            ))
        }

        let coolest = usable.min { $0.load < $1.load }!

        // 2. Incumbent is hot — switch to something fresh, or to anything
        //    meaningfully cooler.
        if let incumbent, let held = usable.first(where: { $0.id == incumbent }) {
            let gain = held.load - coolest.load
            let isFresh = coolest.load < policy.lowWater
            let isWorthIt = gain >= policy.minimumSwitchGain
            if coolest.id != held.id, isFresh || isWorthIt {
                self.incumbent = coolest.id
                let why = isFresh
                    ? "\(coolest.id) is fresh at \(pct(coolest.load))"
                    : "\(coolest.id) is \(pct(gain)) cooler"
                return .dispatch(RoutingDecision(
                    engineId: coolest.id,
                    reason: "\(held.id) at \(pct(held.load)) exceeded high-water — switching, \(why)",
                    load: coolest.load,
                    isCompromise: false
                ))
            }
            // Nothing better is available; riding it out beats a handoff that
            // buys no headroom.
            return .dispatch(RoutingDecision(
                engineId: held.id,
                reason: "\(held.id) at \(pct(held.load)) is hot but no alternative is fresh or \(pct(policy.minimumSwitchGain)) cooler — continuing",
                load: held.load,
                isCompromise: true
            ))
        }

        // 3. Cold start. Honour preference order unless the preferred engine is
        //    already past high-water.
        let preferred = usable.first!
        let chosen = preferred.load < policy.highWater ? preferred : coolest
        incumbent = chosen.id

        // Say so when the top-preference engine was passed over for being
        // absent rather than busy — otherwise "preferred engine codex" reads as
        // a policy statement when it's really a missing install.
        var reason: String
        if chosen.id == preferred.id {
            reason = "preferred engine \(chosen.id) at \(pct(chosen.load))"
        } else {
            reason = "preferred \(preferred.id) at \(pct(preferred.load)) — starting on \(chosen.id) at \(pct(chosen.load))"
        }
        if let top = policy.preferenceOrder.first, !installed.contains(top) {
            reason += " (\(top) not installed)"
        }

        return .dispatch(RoutingDecision(
            engineId: chosen.id,
            reason: reason,
            load: chosen.load,
            isCompromise: false
        ))
    }

    /// Called when an engine returns a rate-limit error. Sidelines it and
    /// re-decides so the caller can retry immediately on the other engine.
    public func handleRateLimit(
        engineId: String,
        installed: Set<String>,
        retryAfter: Date? = nil
    ) async -> RoutingOutcome {
        let until: Date
        if let retryAfter {
            until = retryAfter
        } else {
            until = await monitor.resetEstimate(for: engineId, fallback: policy.blindCooldown)
        }
        await monitor.markExhausted(engineId, until: until)
        if incumbent == engineId { incumbent = nil }
        return await decide(installed: installed)
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}
