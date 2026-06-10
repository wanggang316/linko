import XCTest
@testable import LinkoKit

/// Covers the pure per-app traffic aggregation over a connections snapshot.
final class AppTrafficAggregatorTests: XCTestCase {

    func testAggregatesByProcessAndSumsBytes() {
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 100, down: 900),
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 50, down: 450),
                conn(path: "/usr/bin/curl", up: 10, down: 20),
            ]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.count, 2)

        // Safari aggregates 2 connections, 150 up / 1350 down.
        let safari = stats.first { $0.processName == "Safari" }
        XCTAssertEqual(safari?.connectionCount, 2)
        XCTAssertEqual(safari?.upload, 150)
        XCTAssertEqual(safari?.download, 1350)
        XCTAssertEqual(safari?.totalBytes, 1500)
    }

    func testThreeProcessSnapshotPerAppTotalsCountsAndOrder() {
        // 5 connections across 3 processes: Safari (x2), node (x2), curl (x1).
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 200, down: 800),
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 300, down: 1200),
                conn(path: "/usr/local/bin/node", up: 40, down: 60),
                conn(path: "/usr/local/bin/node", up: 10, down: 90),
                conn(path: "/usr/bin/curl", up: 5, down: 5),
            ]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.count, 3)

        // Pre-sorted by descending total bytes: Safari (2500) > node (200) > curl (10).
        XCTAssertEqual(stats.map(\.processName), ["Safari", "node", "curl"])

        let safari = stats[0]
        XCTAssertEqual(safari.connectionCount, 2)
        XCTAssertEqual(safari.upload, 500)
        XCTAssertEqual(safari.download, 2000)
        XCTAssertEqual(safari.totalBytes, 2500)

        let node = stats[1]
        XCTAssertEqual(node.connectionCount, 2)
        XCTAssertEqual(node.upload, 50)
        XCTAssertEqual(node.download, 150)
        XCTAssertEqual(node.totalBytes, 200)

        let curl = stats[2]
        XCTAssertEqual(curl.connectionCount, 1)
        XCTAssertEqual(curl.upload, 5)
        XCTAssertEqual(curl.download, 5)
        XCTAssertEqual(curl.totalBytes, 10)
    }

    func testEqualTotalsTieBreakByNameAscending() {
        // Two apps with identical totals must order by case-insensitive name asc.
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [
                conn(path: "/Applications/Zoom.app/Contents/MacOS/Zoom", up: 50, down: 50),
                conn(path: "/Applications/Arc.app/Contents/MacOS/Arc", up: 50, down: 50),
            ]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.map(\.processName), ["Arc", "Zoom"])
    }

    func testSortedByTotalBytesDescending() {
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [
                conn(path: "/usr/bin/curl", up: 1, down: 1),
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 100, down: 100),
            ]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.map(\.processName), ["Safari", "curl"])
    }

    func testEmptyProcessPathBucketsUnderUnknown() {
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [conn(path: "", up: 5, down: 5)]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].processPath, AppTrafficStat.unknownProcessPath)
        XCTAssertEqual(stats[0].processName, AppTrafficStat.unknownProcessName)
    }

    func testUserSuffixIsStrippedSoSameAppMerges() {
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0,
            connections: [
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari (gump)", up: 1, down: 1),
                conn(path: "/Applications/Safari.app/Contents/MacOS/Safari", up: 1, down: 1),
            ]
        )
        let stats = AppTrafficAggregator.aggregate(snapshot)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].connectionCount, 2)
    }

    func testDisplayNameFallsBackToLastComponentForNonAppPaths() {
        XCTAssertEqual(
            AppTrafficAggregator.displayName(forProcessPath: "/usr/local/bin/node"),
            "node"
        )
    }

    func testEmptySnapshotYieldsNoRows() {
        let snapshot = ClashConnectionsSnapshot(
            downloadTotal: 0, uploadTotal: 0, connections: []
        )
        XCTAssertTrue(AppTrafficAggregator.aggregate(snapshot).isEmpty)
    }

    // MARK: - Fixtures

    private func conn(path: String, up: Int64, down: Int64) -> ClashConnection {
        ClashConnection(
            id: UUID().uuidString,
            metadata: ClashConnectionMetadata(
                network: "tcp", type: "mixed",
                sourceIP: "127.0.0.1", destinationIP: "1.1.1.1",
                sourcePort: "1", destinationPort: "443",
                host: "example.com", processPath: path
            ),
            upload: up, download: down,
            start: "2026-06-10T10:00:00Z", chains: ["proxy"], rule: "final"
        )
    }
}
