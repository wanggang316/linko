import Foundation

// MARK: - Errors

/// Errors surfaced by `ClashAPIClient`.
public enum ClashAPIError: Error, Equatable, Sendable {
    /// The server returned something that is not an HTTP response.
    case invalidResponse
    /// The server answered with a non-2xx status code. `message` is taken
    /// from the JSON error body (`{"message": "..."}`) when present.
    case unexpectedStatus(code: Int, message: String)
}

extension ClashAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The Clash API returned an invalid response."
        case .unexpectedStatus(let code, let message):
            return message.isEmpty
                ? "The Clash API returned HTTP \(code)."
                : "The Clash API returned HTTP \(code): \(message)"
        }
    }
}

// MARK: - Response payloads

/// One delay-test sample from a proxy's `history` array in `GET /proxies`.
public struct ClashDelayHistoryEntry: Codable, Equatable, Sendable {
    /// Timestamp string as reported by the core (RFC 3339).
    public let time: String?
    /// Measured delay in milliseconds; 0 means the test failed.
    public let delay: Int

    public init(time: String? = nil, delay: Int) {
        self.time = time
        self.delay = delay
    }
}

/// Full per-proxy payload from `GET /proxies`, including selector membership
/// and the node's delay-test history. `ClashAPIClient.proxies()` reduces this
/// to the leaner `ClashProxy`; use `proxyDetails()` when history is needed.
public struct ClashProxyDetail: Codable, Equatable, Sendable {
    public let name: String?
    public let type: String
    /// Currently selected member, present on selector-type proxies.
    public let now: String?
    /// Member tags, present on selector/group-type proxies.
    public let all: [String]?
    /// Recent delay-test results, most recent last.
    public let history: [ClashDelayHistoryEntry]?
    public let udp: Bool?

    public init(
        name: String? = nil,
        type: String,
        now: String? = nil,
        all: [String]? = nil,
        history: [ClashDelayHistoryEntry]? = nil,
        udp: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.history = history
        self.udp = udp
    }

    /// The most recent delay sample, if any test has run.
    public var latestDelay: Int? {
        history?.last?.delay
    }
}

// MARK: - Internal wire formats

struct VersionResponse: Decodable {
    let version: String
}

struct ProxiesResponse: Decodable {
    let proxies: [String: ClashProxyDetail]
}

struct DelayResponse: Decodable {
    let delay: Int
}

struct ErrorResponse: Decodable {
    let message: String
}

struct SelectRequestBody: Encodable {
    let name: String
}
