import Foundation

// MARK: - Connections

/// Snapshot of all live connections plus cumulative byte counters, as returned
/// by `GET /connections` and pushed (~1/s) over the `/connections` WebSocket.
///
/// Wire shape (sing-box `trafficontrol.Snapshot.MarshalJSON`):
/// ```json
/// { "downloadTotal": 12345, "uploadTotal": 678, "connections": [...], "memory": 0 }
/// ```
public struct ClashConnectionsSnapshot: Decodable, Equatable, Sendable {
    /// Cumulative downloaded bytes since the core started.
    public let downloadTotal: Int64
    /// Cumulative uploaded bytes since the core started.
    public let uploadTotal: Int64
    /// Currently open connections. May be absent/`null` when none are active.
    public let connections: [ClashConnection]
    /// Core memory usage in bytes (`memory` field); `0` on builds that omit it.
    public let memory: UInt64

    public init(
        downloadTotal: Int64,
        uploadTotal: Int64,
        connections: [ClashConnection],
        memory: UInt64 = 0
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        self.memory = memory
    }

    private enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections, memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try container.decodeIfPresent(Int64.self, forKey: .downloadTotal) ?? 0
        uploadTotal = try container.decodeIfPresent(Int64.self, forKey: .uploadTotal) ?? 0
        connections = try container.decodeIfPresent([ClashConnection].self, forKey: .connections) ?? []
        memory = try container.decodeIfPresent(UInt64.self, forKey: .memory) ?? 0
    }
}

/// A single live connection entry inside a `ClashConnectionsSnapshot`.
///
/// Wire shape (sing-box `trafficontrol.TrackerMetadata.MarshalJSON`):
/// ```json
/// {
///   "id": "uuid",
///   "metadata": { ... },
///   "upload": 1024,
///   "download": 4096,
///   "start": "2026-06-10T10:00:00Z",
///   "chains": ["proxy", "HK-01"],
///   "rule": "final",
///   "rulePayload": ""
/// }
/// ```
public struct ClashConnection: Decodable, Equatable, Identifiable, Sendable {
    /// Connection UUID; the path component for `DELETE /connections/{id}`.
    public let id: String
    public let metadata: ClashConnectionMetadata
    /// Bytes uploaded on this connection so far.
    public let upload: Int64
    /// Bytes downloaded on this connection so far.
    public let download: Int64
    /// Connection start time as an RFC 3339 string.
    public let start: String
    /// Outbound chain, outermost first (e.g. `["proxy", "HK-01"]`).
    public let chains: [String]
    /// Human-readable matched rule (e.g. `"final"`).
    public let rule: String
    /// Matched rule payload; sing-box always emits an empty string.
    public let rulePayload: String

    public init(
        id: String,
        metadata: ClashConnectionMetadata,
        upload: Int64,
        download: Int64,
        start: String,
        chains: [String],
        rule: String,
        rulePayload: String = ""
    ) {
        self.id = id
        self.metadata = metadata
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        metadata = try container.decode(ClashConnectionMetadata.self, forKey: .metadata)
        upload = try container.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try container.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        start = try container.decodeIfPresent(String.self, forKey: .start) ?? ""
        chains = try container.decodeIfPresent([String].self, forKey: .chains) ?? []
        rule = try container.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rulePayload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
    }
}

/// Per-connection metadata. sing-box encodes every field as a string, including
/// the ports (`sourcePort`/`destinationPort`), so they are modelled as `String`.
///
/// Wire shape:
/// ```json
/// {
///   "network": "tcp",
///   "type": "mixed",
///   "sourceIP": "127.0.0.1",
///   "destinationIP": "1.1.1.1",
///   "sourcePort": "52344",
///   "destinationPort": "443",
///   "host": "example.com",
///   "dnsMode": "normal",
///   "processPath": "/Applications/Safari.app/..."
/// }
/// ```
public struct ClashConnectionMetadata: Decodable, Equatable, Sendable {
    /// `"tcp"` or `"udp"`.
    public let network: String
    /// Inbound type/name (e.g. `"mixed"`).
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    /// Source port as a string (sing-box stringifies ports).
    public let sourcePort: String
    /// Destination port as a string (sing-box stringifies ports).
    public let destinationPort: String
    /// Requested host/domain; empty when the destination was a bare IP.
    public let host: String
    public let dnsMode: String
    /// Originating process path with optional `(user)` suffix; empty when unknown.
    public let processPath: String

    public init(
        network: String,
        type: String,
        sourceIP: String,
        destinationIP: String,
        sourcePort: String,
        destinationPort: String,
        host: String,
        dnsMode: String = "normal",
        processPath: String = ""
    ) {
        self.network = network
        self.type = type
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.host = host
        self.dnsMode = dnsMode
        self.processPath = processPath
    }

    private enum CodingKeys: String, CodingKey {
        case network, type, sourceIP, destinationIP, sourcePort, destinationPort
        case host, dnsMode, processPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent(String.self, forKey: .network) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        sourceIP = try container.decodeIfPresent(String.self, forKey: .sourceIP) ?? ""
        destinationIP = try container.decodeIfPresent(String.self, forKey: .destinationIP) ?? ""
        sourcePort = try container.decodeIfPresent(String.self, forKey: .sourcePort) ?? ""
        destinationPort = try container.decodeIfPresent(String.self, forKey: .destinationPort) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        dnsMode = try container.decodeIfPresent(String.self, forKey: .dnsMode) ?? "normal"
        processPath = try container.decodeIfPresent(String.self, forKey: .processPath) ?? ""
    }

    /// Display target: `host:destinationPort` when a host is known, otherwise
    /// `destinationIP:destinationPort`.
    public var destinationDisplay: String {
        let target = host.isEmpty ? destinationIP : host
        return destinationPort.isEmpty ? target : "\(target):\(destinationPort)"
    }
}

// MARK: - Traffic

/// One per-second traffic tick from the `/traffic` WebSocket: bytes transferred
/// during the elapsed interval (a delta, not a cumulative total).
///
/// Wire shape: `{ "up": 1024, "down": 4096 }`.
public struct ClashTrafficTick: Decodable, Equatable, Sendable {
    /// Bytes uploaded during the interval.
    public let up: Int64
    /// Bytes downloaded during the interval.
    public let down: Int64

    public init(up: Int64, down: Int64) {
        self.up = up
        self.down = down
    }

    private enum CodingKeys: String, CodingKey {
        case up, down
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        up = try container.decodeIfPresent(Int64.self, forKey: .up) ?? 0
        down = try container.decodeIfPresent(Int64.self, forKey: .down) ?? 0
    }
}

// MARK: - Logs

/// One log line from the `/logs` WebSocket.
///
/// Wire shape: `{ "type": "info", "payload": "..." }`.
public struct ClashLogEntry: Decodable, Equatable, Sendable {
    /// Severity label as reported by the core: `debug`/`info`/`warning`/`error`.
    public let type: String
    /// The log message text.
    public let payload: String

    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        payload = try container.decodeIfPresent(String.self, forKey: .payload) ?? ""
    }
}

/// Log severity levels accepted by the `/logs?level=` query parameter.
public enum ClashLogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}
