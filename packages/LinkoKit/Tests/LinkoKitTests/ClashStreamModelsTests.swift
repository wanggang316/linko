import XCTest

@testable import LinkoKit

/// Offline decode tests for the dashboard streaming models. Fixtures mirror the
/// exact wire shapes emitted by sing-box's `clashapi` package
/// (`trafficontrol.Snapshot`, `TrackerMetadata`, `Traffic`, log lines). No live
/// socket is opened here.
final class ClashStreamModelsTests: XCTestCase {
    private let decoder = JSONDecoder()

    // MARK: Connections snapshot

    private static let snapshotJSON = #"""
        {
          "downloadTotal": 104857600,
          "uploadTotal": 2097152,
          "memory": 33554432,
          "connections": [
            {
              "id": "f1d2c3b4-0000-4000-8000-000000000001",
              "metadata": {
                "network": "tcp",
                "type": "mixed",
                "sourceIP": "127.0.0.1",
                "destinationIP": "1.1.1.1",
                "sourcePort": "52344",
                "destinationPort": "443",
                "host": "example.com",
                "dnsMode": "normal",
                "processPath": "/Applications/Safari.app/Contents/MacOS/Safari (gump)"
              },
              "upload": 1024,
              "download": 4096,
              "start": "2026-06-10T10:00:00Z",
              "chains": ["proxy", "HK-01"],
              "rule": "final",
              "rulePayload": ""
            }
          ]
        }
        """#

    func testConnectionsSnapshotDecodesFullShape() throws {
        let snapshot = try decoder.decode(
            ClashConnectionsSnapshot.self,
            from: Data(Self.snapshotJSON.utf8)
        )

        XCTAssertEqual(snapshot.downloadTotal, 104_857_600)
        XCTAssertEqual(snapshot.uploadTotal, 2_097_152)
        XCTAssertEqual(snapshot.memory, 33_554_432)
        XCTAssertEqual(snapshot.connections.count, 1)

        let connection = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(connection.id, "f1d2c3b4-0000-4000-8000-000000000001")
        XCTAssertEqual(connection.upload, 1024)
        XCTAssertEqual(connection.download, 4096)
        XCTAssertEqual(connection.start, "2026-06-10T10:00:00Z")
        XCTAssertEqual(connection.chains, ["proxy", "HK-01"])
        XCTAssertEqual(connection.rule, "final")
        XCTAssertEqual(connection.rulePayload, "")

        let metadata = connection.metadata
        XCTAssertEqual(metadata.network, "tcp")
        XCTAssertEqual(metadata.type, "mixed")
        XCTAssertEqual(metadata.sourceIP, "127.0.0.1")
        XCTAssertEqual(metadata.destinationIP, "1.1.1.1")
        // sing-box stringifies ports.
        XCTAssertEqual(metadata.sourcePort, "52344")
        XCTAssertEqual(metadata.destinationPort, "443")
        XCTAssertEqual(metadata.host, "example.com")
        XCTAssertEqual(metadata.dnsMode, "normal")
        XCTAssertEqual(
            metadata.processPath,
            "/Applications/Safari.app/Contents/MacOS/Safari (gump)"
        )
        XCTAssertEqual(metadata.destinationDisplay, "example.com:443")
    }

    func testConnectionsSnapshotTreatsNullConnectionsAsEmpty() throws {
        // sing-box emits `"connections": null` when nothing is open.
        let json = #"{"downloadTotal": 0, "uploadTotal": 0, "connections": null, "memory": 0}"#
        let snapshot = try decoder.decode(ClashConnectionsSnapshot.self, from: Data(json.utf8))

        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertEqual(snapshot.downloadTotal, 0)
        XCTAssertEqual(snapshot.uploadTotal, 0)
    }

    func testConnectionsSnapshotToleratesMissingMemoryAndFields() throws {
        // Older/leaner builds may omit `memory` and per-connection optionals.
        let json = #"""
            {
              "downloadTotal": 5,
              "uploadTotal": 7,
              "connections": [
                {
                  "id": "abc",
                  "metadata": {
                    "network": "udp",
                    "type": "mixed",
                    "sourceIP": "127.0.0.1",
                    "destinationIP": "8.8.8.8",
                    "sourcePort": "5000",
                    "destinationPort": "53",
                    "host": ""
                  },
                  "upload": 0,
                  "download": 0,
                  "start": "2026-06-10T10:00:00Z",
                  "chains": ["direct"],
                  "rule": "final"
                }
              ]
            }
            """#
        let snapshot = try decoder.decode(ClashConnectionsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.memory, 0)
        let connection = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(connection.rulePayload, "")
        XCTAssertEqual(connection.metadata.host, "")
        XCTAssertEqual(connection.metadata.dnsMode, "normal")
        XCTAssertEqual(connection.metadata.processPath, "")
        // No host -> fall back to destination IP.
        XCTAssertEqual(connection.metadata.destinationDisplay, "8.8.8.8:53")
    }

    // MARK: Traffic tick

    func testTrafficTickDecodes() throws {
        let json = #"{"up": 1234, "down": 567890}"#
        let tick = try decoder.decode(ClashTrafficTick.self, from: Data(json.utf8))

        XCTAssertEqual(tick.up, 1234)
        XCTAssertEqual(tick.down, 567_890)
    }

    func testTrafficTickIdleDecodesToZero() throws {
        let json = #"{"up": 0, "down": 0}"#
        let tick = try decoder.decode(ClashTrafficTick.self, from: Data(json.utf8))

        XCTAssertEqual(tick, ClashTrafficTick(up: 0, down: 0))
    }

    // MARK: Log entry

    func testLogEntryDecodes() throws {
        let json = #"{"type": "info", "payload": "inbound/mixed: connection from 127.0.0.1"}"#
        let entry = try decoder.decode(ClashLogEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.type, "info")
        XCTAssertEqual(entry.payload, "inbound/mixed: connection from 127.0.0.1")
    }

    func testLogLevelRawValuesMatchQueryParameter() {
        XCTAssertEqual(ClashLogLevel.debug.rawValue, "debug")
        XCTAssertEqual(ClashLogLevel.info.rawValue, "info")
        XCTAssertEqual(ClashLogLevel.warning.rawValue, "warning")
        XCTAssertEqual(ClashLogLevel.error.rawValue, "error")
        XCTAssertEqual(ClashLogLevel.allCases.count, 4)
    }
}
