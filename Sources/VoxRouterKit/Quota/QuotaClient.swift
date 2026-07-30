import Foundation

public enum QuotaError: Error, LocalizedError, Sendable {
    /// OpenUsage.app isn't running, or isn't serving on the expected port.
    case dashboardUnavailable(underlying: String)
    case badStatus(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .dashboardUnavailable(let why):
            return "OpenUsage dashboard unreachable (\(why)). Is OpenUsage.app running?"
        case .badStatus(let code):
            return "OpenUsage returned HTTP \(code)."
        case .malformed(let detail):
            return "OpenUsage response could not be parsed: \(detail)"
        }
    }
}

/// Reads quota from OpenUsage's local HTTP API.
///
/// Endpoint discovered by string-scanning OpenUsage.app and probing; verified
/// against OpenUsage 0.7.7-beta.1. `/v1/usage` returns every enabled provider,
/// `/v1/usage/{providerId}` returns one. Both return an array.
public struct QuotaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, timeout: TimeInterval = 2.0) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        // Loopback only — never wait on proxy resolution or DNS.
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
    }

    public func fetchAll() async throws -> QuotaSnapshot {
        let providers: [ProviderUsage] = try await get("/v1/usage")
        return QuotaSnapshot(providers: providers)
    }

    public func fetch(provider id: String) async throws -> ProviderUsage? {
        let providers: [ProviderUsage] = try await get("/v1/usage/\(id)")
        return providers.first
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path.trimmingPrefix("/").description)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.dashboardUnavailable(underlying: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuotaError.badStatus(http.statusCode)
        }

        do {
            return try JSONDecoder.openUsage().decode(T.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw QuotaError.malformed("\(error) — body began: \(preview)")
        }
    }
}
