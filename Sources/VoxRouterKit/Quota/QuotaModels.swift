import Foundation

// MARK: - Wire types
//
// These mirror OpenUsage's local API at http://127.0.0.1:6736/v1/usage.
// That endpoint is an internal surface for OpenUsage's own widget, not a
// published contract, so every field below is optional and unknown line
// types are ignored. Schema drift must degrade, never crash.

public struct UsageFormat: Decodable, Sendable {
    public let kind: String?
}

/// One row in a provider's panel. `type` discriminates: "progress" rows carry
/// quota, "text" and "barChart" rows are display-only and ignored by routing.
public struct UsageLine: Decodable, Sendable {
    public let type: String
    public let label: String?
    public let used: Double?
    public let limit: Double?
    public let value: String?
    public let note: String?
    public let periodDurationMs: Double?
    public let resetsAt: Date?
    public let format: UsageFormat?
}

public struct ProviderUsage: Decodable, Sendable {
    public let providerId: String
    public let displayName: String?
    public let plan: String?
    public let fetchedAt: Date?
    public let lines: [UsageLine]
}

// MARK: - Derived view

/// A single quota window (e.g. Claude's 5h "Session", Codex's 7d "Weekly"),
/// normalised to percent-used regardless of how the source formatted it.
public struct QuotaWindow: Sendable, Equatable {
    public let label: String
    public let usedPercent: Double
    public let period: TimeInterval?
    public let resetsAt: Date?

    public var headroom: Double { max(0, 100 - usedPercent) }
}

extension UsageLine {
    public var asWindow: QuotaWindow? {
        guard type == "progress", let label, let used else { return nil }
        let percent: Double
        if format?.kind == "percent" {
            percent = used
        } else if let limit, limit > 0 {
            percent = used / limit * 100
        } else {
            return nil  // unusable row — better to omit than to guess
        }
        return QuotaWindow(
            label: label,
            usedPercent: percent.clamped(to: 0...100),
            period: periodDurationMs.map { $0 / 1000 },
            resetsAt: resetsAt
        )
    }
}

extension ProviderUsage {
    public var windows: [QuotaWindow] { lines.compactMap(\.asWindow) }

    /// The window closest to its limit. This is the only number routing cares
    /// about: a provider is as available as its most-constrained window.
    public var bindingWindow: QuotaWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    public var bindingLoad: Double { bindingWindow?.usedPercent ?? 0 }

    /// When the binding window frees up. Used to tell the user how long they're
    /// blocked when every provider is spent.
    public var bindingReset: Date? { bindingWindow?.resetsAt }

    /// How stale OpenUsage's own upstream fetch is. OpenUsage refreshes on a
    /// ~5 min cycle, so this is routinely minutes old — the reason reactive
    /// 429 failover exists alongside proactive routing.
    public func upstreamAge(now: Date = Date()) -> TimeInterval? {
        fetchedAt.map { now.timeIntervalSince($0) }
    }
}

// MARK: - Snapshot

public struct QuotaSnapshot: Sendable {
    public let providers: [ProviderUsage]
    public let observedAt: Date

    public init(providers: [ProviderUsage], observedAt: Date = Date()) {
        self.providers = providers
        self.observedAt = observedAt
    }

    public func provider(_ id: String) -> ProviderUsage? {
        providers.first { $0.providerId.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// True when we got a response but found no usable quota rows in it —
    /// i.e. OpenUsage changed its schema under us. Routing must fall back to
    /// preference order rather than silently treating everything as 0% used.
    public var isDegraded: Bool {
        !providers.isEmpty && providers.allSatisfy { $0.windows.isEmpty }
    }
}

// MARK: - Decoding

extension JSONDecoder {
    /// OpenUsage emits ISO-8601 with milliseconds ("2026-08-05T06:26:45.000Z"),
    /// but not on every field, so accept both precisions.
    public static func openUsage() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? ISO8601Parsers.withFraction.parse(raw) { return date }
            if let date = try? ISO8601Parsers.plain.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unparseable date: \(raw)")
            )
        }
        return decoder
    }
}

/// `ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the former is
/// `Sendable` (the latter isn't, and can't be a global under strict
/// concurrency) and Foundation caches identical styles internally.
enum ISO8601Parsers {
    static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let plain = Date.ISO8601FormatStyle()
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
