import XCTest

@testable import LinkoKit

// MARK: - URLProtocol stub

/// Intercepts every request on the test session, records it, and serves a
/// canned response. No network access ever happens in these tests.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
    }

    private static let lock = NSLock()
    private static var _stub = Stub(statusCode: 200, body: Data())
    private static var _recordedRequests: [URLRequest] = []

    static var stub: Stub {
        get { lock.withLock { _stub } }
        set { lock.withLock { _stub = newValue } }
    }

    static var recordedRequests: [URLRequest] {
        lock.withLock { _recordedRequests }
    }

    static func reset() {
        lock.withLock {
            _stub = Stub(statusCode: 200, body: Data())
            _recordedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._recordedRequests.append(request) }
        let stub = Self.stub
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession hands the body to URLProtocol as a stream, not `httpBody`.
    var bodyDataForTesting: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Tests

final class ClashAPIClientTests: XCTestCase {
    private var client: ClashAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = ClashAPIClient(port: 9090, session: URLSession(configuration: configuration))
    }

    private var lastRequest: URLRequest? {
        StubURLProtocol.recordedRequests.last
    }

    // MARK: version

    func testVersionBuildsGETRequestAndDecodesResponse() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: Data(#"{"version":"1.9.3","premium":true}"#.utf8)
        )

        let version = try await client.version()

        XCTAssertEqual(version, "1.9.3")
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/version")
    }

    // MARK: proxies

    private static let proxiesJSON = #"""
        {
          "proxies": {
            "proxy": {
              "name": "proxy",
              "type": "Selector",
              "now": "HK-01",
              "all": ["HK-01", "JP-02", "direct"],
              "history": []
            },
            "HK-01": {
              "name": "HK-01",
              "type": "Shadowsocks",
              "udp": true,
              "history": [
                {"time": "2026-06-10T10:00:00Z", "delay": 123},
                {"time": "2026-06-10T10:05:00Z", "delay": 87}
              ]
            },
            "direct": {
              "type": "Direct",
              "history": []
            }
          }
        }
        """#

    func testProxiesDecodesSelectorGroupsAndNodes() async throws {
        StubURLProtocol.stub = .init(statusCode: 200, body: Data(Self.proxiesJSON.utf8))

        let proxies = try await client.proxies()

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/proxies")

        XCTAssertEqual(proxies.count, 3)
        let selector = try XCTUnwrap(proxies["proxy"])
        XCTAssertEqual(selector.type, "Selector")
        XCTAssertEqual(selector.now, "HK-01")
        XCTAssertEqual(selector.all, ["HK-01", "JP-02", "direct"])

        let node = try XCTUnwrap(proxies["HK-01"])
        XCTAssertEqual(node.type, "Shadowsocks")
        XCTAssertNil(node.now)
        XCTAssertNil(node.all)

        // Entries without an explicit "name" fall back to the dictionary key.
        XCTAssertEqual(proxies["direct"]?.name, "direct")
    }

    func testProxyDetailsDecodesDelayHistory() async throws {
        StubURLProtocol.stub = .init(statusCode: 200, body: Data(Self.proxiesJSON.utf8))

        let details = try await client.proxyDetails()

        let node = try XCTUnwrap(details["HK-01"])
        XCTAssertEqual(
            node.history,
            [
                ClashDelayHistoryEntry(time: "2026-06-10T10:00:00Z", delay: 123),
                ClashDelayHistoryEntry(time: "2026-06-10T10:05:00Z", delay: 87),
            ]
        )
        XCTAssertEqual(node.latestDelay, 87)
        XCTAssertEqual(node.udp, true)
        XCTAssertEqual(details["proxy"]?.history, [])
        XCTAssertEqual(details["direct"]?.name, "direct")
    }

    // MARK: select

    func testSelectBuildsPUTRequestWithJSONBody() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        try await client.select(selector: "proxy", nodeName: "HK-01")

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/proxies/proxy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.bodyDataForTesting)
        let payload = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(payload, ["name": "HK-01"])
    }

    func testSelectPercentEncodesSelectorName() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        try await client.select(selector: "节点 选择", nodeName: "HK-01")

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url?.path, "/proxies/节点 选择")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:9090/proxies/%E8%8A%82%E7%82%B9%20%E9%80%89%E6%8B%A9"
        )
    }

    func testSelectEncodesSlashInSelectorAsSingleSegment() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        // A selector name containing '/' must stay one path segment; otherwise
        // `appendingPathComponent` would split it and hit the wrong endpoint.
        try await client.select(selector: "auto/urltest", nodeName: "HK-01")

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        // On the wire the '/' must be escaped so it stays one path segment;
        // `appendingPathComponent` would emit a bare `.../auto/urltest`.
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:9090/proxies/auto%2Furltest"
        )
    }

    func testSelectEncodesUnicodeAndSlashInSelector() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        try await client.select(selector: "香港/中转", nodeName: "HK-01")

        let request = try XCTUnwrap(lastRequest)
        // Both the CJK characters and the embedded '/' are percent-encoded into
        // a single path segment.
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:9090/proxies/%E9%A6%99%E6%B8%AF%2F%E4%B8%AD%E8%BD%AC"
        )
    }

    func testSelectThrowsOnErrorStatusWithMessage() async {
        StubURLProtocol.stub = .init(
            statusCode: 400,
            body: Data(#"{"message":"unknown proxy"}"#.utf8)
        )

        do {
            try await client.select(selector: "proxy", nodeName: "missing")
            XCTFail("Expected ClashAPIError.unexpectedStatus")
        } catch let error as ClashAPIError {
            XCTAssertEqual(error, .unexpectedStatus(code: 400, message: "unknown proxy"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: delay

    func testDelayBuildsQueryAndDecodesResponse() async throws {
        StubURLProtocol.stub = .init(statusCode: 200, body: Data(#"{"delay":42}"#.utf8))

        let delay = try await client.delay(
            nodeName: "HK-01",
            testURL: "http://www.gstatic.com/generate_204",
            timeoutMilliseconds: 5000
        )

        XCTAssertEqual(delay, 42)
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.path, "/proxies/HK-01/delay")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "timeout", value: "5000"),
                URLQueryItem(name: "url", value: "http://www.gstatic.com/generate_204"),
            ]
        )
    }

    func testDelayEncodesSlashInNodeNameKeepingTrailingSegment() async throws {
        StubURLProtocol.stub = .init(statusCode: 200, body: Data(#"{"delay":42}"#.utf8))

        // The node name sits between two fixed segments (`proxies/<name>/delay`);
        // a raw '/' in the name would shift the `delay` segment and break the call.
        _ = try await client.delay(
            nodeName: "auto/urltest",
            testURL: "http://www.gstatic.com/generate_204",
            timeoutMilliseconds: 5000
        )

        let request = try XCTUnwrap(lastRequest)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        // The trailing `delay` segment stays put because the '/' in the node
        // name is escaped rather than treated as a path separator.
        XCTAssertEqual(components.percentEncodedPath, "/proxies/auto%2Furltest/delay")
    }

    func testDelayThrowsOnTimeoutStatus() async {
        StubURLProtocol.stub = .init(
            statusCode: 504,
            body: Data(#"{"message":"Timeout"}"#.utf8)
        )

        do {
            _ = try await client.delay(
                nodeName: "HK-01",
                testURL: "http://www.gstatic.com/generate_204",
                timeoutMilliseconds: 5000
            )
            XCTFail("Expected ClashAPIError.unexpectedStatus")
        } catch let error as ClashAPIError {
            XCTAssertEqual(error, .unexpectedStatus(code: 504, message: "Timeout"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: connections snapshot

    func testConnectionsSnapshotBuildsGETRequestAndDecodes() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: Data(#"""
                {
                  "downloadTotal": 2048,
                  "uploadTotal": 512,
                  "memory": 1024,
                  "connections": [
                    {
                      "id": "conn-1",
                      "metadata": {
                        "network": "tcp",
                        "type": "mixed",
                        "sourceIP": "127.0.0.1",
                        "destinationIP": "1.1.1.1",
                        "sourcePort": "50000",
                        "destinationPort": "443",
                        "host": "example.com",
                        "dnsMode": "normal",
                        "processPath": ""
                      },
                      "upload": 10,
                      "download": 20,
                      "start": "2026-06-10T10:00:00Z",
                      "chains": ["proxy"],
                      "rule": "final",
                      "rulePayload": ""
                    }
                  ]
                }
                """#.utf8)
        )

        let snapshot = try await client.connectionsSnapshot()

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/connections")
        XCTAssertEqual(snapshot.downloadTotal, 2048)
        XCTAssertEqual(snapshot.uploadTotal, 512)
        XCTAssertEqual(snapshot.connections.first?.id, "conn-1")
        XCTAssertEqual(snapshot.connections.first?.metadata.destinationPort, "443")
    }

    // MARK: closeConnection

    func testCloseConnectionByIDBuildsDeleteRequest() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        try await client.closeConnection(id: "conn-1")

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/connections/conn-1")
    }

    func testCloseConnectionWithNilClosesAllConnections() async throws {
        StubURLProtocol.stub = .init(statusCode: 204, body: Data())

        try await client.closeConnection(id: nil)

        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/connections")
    }

    func testNonJSONErrorBodyProducesEmptyMessage() async {
        StubURLProtocol.stub = .init(statusCode: 500, body: Data("boom".utf8))

        do {
            _ = try await client.version()
            XCTFail("Expected ClashAPIError.unexpectedStatus")
        } catch let error as ClashAPIError {
            XCTAssertEqual(error, .unexpectedStatus(code: 500, message: ""))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
