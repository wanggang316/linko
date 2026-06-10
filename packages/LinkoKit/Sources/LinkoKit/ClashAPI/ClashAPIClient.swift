import Foundation

/// URLSession-backed client for the sing-box Clash-compatible API
/// (`experimental.clash_api` on `127.0.0.1:<clashAPIPort>`).
public struct ClashAPIClient: ClashAPIProviding {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Convenience initializer for the common local setup,
    /// e.g. `ClashAPIClient(port: preferences.clashAPIPort)`.
    public init(host: String = "127.0.0.1", port: Int, session: URLSession = .shared) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        // Scheme/host/port components above always form a valid URL.
        self.init(baseURL: components.url!, session: session)
    }

    // MARK: - ClashAPIProviding

    public func version() async throws -> String {
        let data = try await send(request: makeRequest(method: "GET", pathComponents: ["version"]))
        return try decode(VersionResponse.self, from: data).version
    }

    public func proxies() async throws -> [String: ClashProxy] {
        try await proxyDetails().mapValues { detail in
            ClashProxy(
                name: detail.name ?? "",
                type: detail.type,
                now: detail.now,
                all: detail.all
            )
        }
    }

    /// `GET /proxies` keeping the full payload, including selector membership
    /// and per-node delay history. Entries missing a `name` field fall back
    /// to their dictionary key.
    public func proxyDetails() async throws -> [String: ClashProxyDetail] {
        let data = try await send(request: makeRequest(method: "GET", pathComponents: ["proxies"]))
        let response = try decode(ProxiesResponse.self, from: data)
        var details: [String: ClashProxyDetail] = [:]
        details.reserveCapacity(response.proxies.count)
        for (tag, detail) in response.proxies {
            if detail.name == nil {
                details[tag] = ClashProxyDetail(
                    name: tag,
                    type: detail.type,
                    now: detail.now,
                    all: detail.all,
                    history: detail.history,
                    udp: detail.udp
                )
            } else {
                details[tag] = detail
            }
        }
        return details
    }

    public func select(selector: String, nodeName: String) async throws {
        var request = makeRequest(method: "PUT", pathComponents: ["proxies", selector])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SelectRequestBody(name: nodeName))
        _ = try await send(request: request)
    }

    public func delay(nodeName: String, testURL: String, timeoutMilliseconds: Int) async throws -> Int {
        let request = makeRequest(
            method: "GET",
            pathComponents: ["proxies", nodeName, "delay"],
            queryItems: [
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
                URLQueryItem(name: "url", value: testURL),
            ]
        )
        let data = try await send(request: request)
        return try decode(DelayResponse.self, from: data).delay
    }

    // MARK: - Request construction

    private func makeRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem]? = nil
    ) -> URLRequest {
        // appendingPathComponent percent-encodes node/selector names that
        // contain spaces or non-ASCII characters.
        var url = pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
        if let queryItems, !queryItems.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Transport

    private func send(request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClashAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message ?? ""
            throw ClashAPIError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
