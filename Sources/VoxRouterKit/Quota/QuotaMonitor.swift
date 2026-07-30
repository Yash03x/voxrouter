import Foundation

/// Keeps a warm quota snapshot so routing never touches the network.
///
/// The whole point: a spoken command must not pay for an HTTP round trip, a
/// JSON decode, or a stale-cache miss before it starts working. A background
/// task refreshes on an interval; `current()` is an in-memory read.
///
/// It also holds *local* exhaustion overrides. OpenUsage's upstream data can be
/// minutes old, so when an engine actually returns a rate-limit error we record
/// that immediately rather than waiting for the dashboard to catch up.
public actor QuotaMonitor {
    public struct State: Sendable {
        public var snapshot: QuotaSnapshot?
        public var lastError: String?
        public var lastRefresh: Date?
        /// providerId -> the moment it becomes usable again.
        public var localExhaustion: [String: Date] = [:]

        public func isLocallyExhausted(_ providerId: String, now: Date = Date()) -> Bool {
            guard let until = localExhaustion[providerId] else { return false }
            return until > now
        }
    }

    /// Injected so routing can be tested against synthetic quota without a
    /// running dashboard.
    private let fetch: @Sendable () async throws -> QuotaSnapshot
    private let interval: TimeInterval
    private var state = State()
    private var refreshTask: Task<Void, Never>?

    public init(
        interval: TimeInterval = 20,
        fetch: @escaping @Sendable () async throws -> QuotaSnapshot
    ) {
        self.fetch = fetch
        self.interval = interval
    }

    public init(client: QuotaClient, interval: TimeInterval = 20) {
        self.init(interval: interval) { try await client.fetchAll() }
    }

    public func current() -> State { state }

    /// Refresh once, now. Returns the snapshot or throws.
    @discardableResult
    public func refresh() async throws -> QuotaSnapshot {
        do {
            let snapshot = try await fetch()
            state.snapshot = snapshot
            state.lastRefresh = Date()
            state.lastError = nil
            if snapshot.isDegraded {
                Log.quota.warning("OpenUsage returned no progress rows — schema may have changed")
            }
            return snapshot
        } catch {
            state.lastError = error.localizedDescription
            state.lastRefresh = Date()
            Log.quota.error("quota refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [interval] in
            while !Task.isCancelled {
                _ = try? await self.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Record that an engine really did hit its limit, ahead of the dashboard.
    /// `until` comes from the provider's own reset time when we know it, and
    /// otherwise from a conservative default.
    public func markExhausted(_ providerId: String, until: Date) {
        state.localExhaustion[providerId] = until
        Log.quota.notice(
            "marked \(providerId, privacy: .public) exhausted until \(until, privacy: .public)"
        )
    }

    public func clearExhaustion(_ providerId: String) {
        state.localExhaustion[providerId] = nil
    }

    /// Best guess at when a provider frees up: its own reported reset, else a
    /// fallback window.
    public func resetEstimate(for providerId: String, fallback: TimeInterval) -> Date {
        if let reset = state.snapshot?.provider(providerId)?.bindingReset, reset > Date() {
            return reset
        }
        return Date().addingTimeInterval(fallback)
    }
}
