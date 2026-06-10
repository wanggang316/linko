import Foundation

/// Per-application traffic totals, aggregated from a `ClashConnectionsSnapshot`
/// by originating process. Each value rolls up every connection that shares a
/// process into cumulative up/down byte counters plus a live-connection count,
/// for a native sortable per-app view (beating Surge's per-app stats).
///
/// `Identifiable` by `processPath` so SwiftUI lists are stable across snapshots;
/// `Comparable` defaults to descending total bytes (the most-active app first).
public struct AppTrafficStat: Codable, Hashable, Identifiable, Sendable {
    /// The originating process's path, as reported in connection metadata. The
    /// stable identity. Empty when sing-box could not attribute the process —
    /// folded under the `unknownProcessPath` sentinel by the aggregator.
    public var processPath: String
    /// Display name derived from `processPath`: the bundle/app name when the
    /// path points inside an `.app`, otherwise the last path component.
    public var processName: String
    /// Cumulative uploaded bytes across this app's connections in the snapshot.
    public var upload: Int64
    /// Cumulative downloaded bytes across this app's connections in the snapshot.
    public var download: Int64
    /// Number of currently-open connections attributed to this app.
    public var connectionCount: Int

    public var id: String { processPath }

    /// Combined up + down bytes; the default sort key.
    public var totalBytes: Int64 { upload &+ download }

    /// Sentinel `processPath` used to bucket connections sing-box could not
    /// attribute to a process (empty `processPath`).
    public static let unknownProcessPath = "(unknown)"
    /// Display name for the unknown bucket.
    public static let unknownProcessName = "未知进程"

    public init(
        processPath: String,
        processName: String,
        upload: Int64,
        download: Int64,
        connectionCount: Int
    ) {
        self.processPath = processPath
        self.processName = processName
        self.upload = upload
        self.download = download
        self.connectionCount = connectionCount
    }
}

/// Pure, offline-testable aggregation of a connections snapshot into per-app
/// rows. No actor isolation, no I/O — the app's view model calls this on every
/// `/connections` frame.
public enum AppTrafficAggregator {
    /// Rolls `snapshot.connections` up by originating process and returns rows
    /// sorted by descending total bytes, then ascending name for stable ties.
    /// Connections with an empty `processPath` are bucketed under
    /// `AppTrafficStat.unknownProcessPath`.
    public static func aggregate(_ snapshot: ClashConnectionsSnapshot) -> [AppTrafficStat] {
        aggregate(connections: snapshot.connections)
    }

    /// Aggregates an explicit connection list (used directly by fixture tests).
    public static func aggregate(connections: [ClashConnection]) -> [AppTrafficStat] {
        var byPath: [String: AppTrafficStat] = [:]
        for connection in connections {
            let path = normalizedPath(connection.metadata.processPath)
            var stat = byPath[path] ?? AppTrafficStat(
                processPath: path,
                processName: displayName(forProcessPath: path),
                upload: 0,
                download: 0,
                connectionCount: 0
            )
            stat.upload &+= connection.upload
            stat.download &+= connection.download
            stat.connectionCount += 1
            byPath[path] = stat
        }
        return byPath.values.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
        }
    }

    /// Strips an optional ` (user)` suffix sing-box appends to `processPath` and
    /// maps an empty path to the unknown sentinel, so the same app under one
    /// user does not split into multiple rows.
    public static func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if let range = path.range(of: " (", options: .backwards), path.hasSuffix(")") {
            path = String(path[path.startIndex..<range.lowerBound])
        }
        return path.isEmpty ? AppTrafficStat.unknownProcessPath : path
    }

    /// Derives a friendly app name from a process path: the `*.app` bundle name
    /// when the path is inside a macOS app bundle, otherwise the final path
    /// component. The unknown sentinel maps to its Chinese label.
    public static func displayName(forProcessPath path: String) -> String {
        if path == AppTrafficStat.unknownProcessPath {
            return AppTrafficStat.unknownProcessName
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let appComponent = components.last(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(".app".count))
        }
        return components.last ?? path
    }
}
