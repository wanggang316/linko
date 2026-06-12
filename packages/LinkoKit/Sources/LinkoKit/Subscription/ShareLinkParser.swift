import Foundation

/// Parses individual `scheme://…` proxy share links — the format carried by
/// V2Ray-style subscriptions (a Base64 blob of newline-separated links) and by
/// "copy node link" buttons — into `ProxyNode`s.
///
/// Supported schemes: `ss`, `vmess`, `vless`, `trojan`, `hysteria2` (+ `hy2`),
/// `tuic`. WireGuard and SSH have no widely-used share-link form and arrive via
/// Clash YAML instead. Unsupported or malformed links are skipped with a
/// warning, never a throw — one bad line never sinks the whole subscription.
public struct ShareLinkParser {
    public init() {}

    /// A skip reason bubbled out of a per-link parser.
    struct EntryError: Error { let message: String }

    /// Schemes that look like a proxy share link, for format detection. A
    /// superset of what we can parse (e.g. `ssr` is detected so it routes here
    /// and is reported as unsupported rather than mis-detected as something else).
    static let knownSchemes: Set<String> = [
        "ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2", "tuic",
    ]

    /// Whether `text` holds at least one line that starts with a known share-link
    /// scheme. Used by the format detector to route a payload here.
    public static func containsShareLink(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            scheme(of: line.trimmingCharacters(in: .whitespaces)).map(knownSchemes.contains) ?? false
        }
    }

    /// The lowercased scheme of a `scheme://…` string, or `nil` if it has none.
    private static func scheme(of link: String) -> String? {
        guard let range = link.range(of: "://") else { return nil }
        let scheme = link[link.startIndex..<range.lowerBound].lowercased()
        return scheme.isEmpty ? nil : scheme
    }

    // MARK: - Bulk

    /// Parses newline-separated share links. Blank lines are ignored; each
    /// unparseable or unsupported link is skipped with a warning. `format`
    /// tags the result for the UI (Base64 subscription vs. bare links).
    public func parseLinks(
        _ text: String,
        format: SubscriptionFormat = .shareLinks
    ) -> SubscriptionParseResult {
        var nodes: [ProxyNode] = []
        var warnings: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("://") else { continue }
            do {
                nodes.append(try node(fromShareLink: line))
            } catch let error as EntryError {
                warnings.append(error.message)
            } catch {
                warnings.append("跳过一条链接：\(error.localizedDescription)")
            }
        }
        return SubscriptionParseResult(nodes: nodes, warnings: warnings, format: format)
    }

    // MARK: - Single link dispatch

    /// Parses one share link into a node, or throws `EntryError` with a reason.
    public func node(fromShareLink link: String) throws -> ProxyNode {
        guard let scheme = Self.scheme(of: link) else {
            throw EntryError(message: "跳过链接「\(preview(link))」：缺少协议前缀。")
        }
        switch scheme {
        case "ss": return try shadowsocksNode(link)
        case "vmess": return try vmessNode(link)
        case "vless": return try vlessNode(link)
        case "trojan": return try trojanNode(link)
        case "hysteria2", "hy2": return try hysteria2Node(link)
        case "tuic": return try tuicNode(link)
        default:
            throw EntryError(message: "跳过链接「\(preview(link))」：暂不支持 \(scheme) 协议。")
        }
    }

    // MARK: - shadowsocks

    private func shadowsocksNode(_ link: String) throws -> ProxyNode {
        var body = String(link.dropFirst("ss://".count))
        let name = Self.takeFragment(&body)
        let query = Self.takeQuery(&body)

        let method: String
        let password: String
        let host: String
        let port: Int

        if let atIndex = body.lastIndex(of: "@") {
            // SIP002: base64url(method:password)@host:port  (userinfo may also
            // be a plain, percent-encoded `method:password`).
            let userinfo = String(body[..<atIndex])
            let hostPort = String(body[body.index(after: atIndex)...])
            let creds: String
            if let decoded = Self.decodeBase64String(userinfo), decoded.contains(":") {
                creds = decoded
            } else {
                creds = userinfo.removingPercentEncoding ?? userinfo
            }
            (method, password) = try Self.splitCredentials(creds, scheme: "ss")
            (host, port) = try Self.splitHostPort(hostPort)
        } else {
            // Legacy: base64(method:password@host:port).
            guard let decoded = Self.decodeBase64String(body) else {
                throw EntryError(message: "跳过 ss 链接「\(preview(link))」：内容不是合法的 Base64。")
            }
            guard let atIndex = decoded.lastIndex(of: "@") else {
                throw EntryError(message: "跳过 ss 链接「\(preview(link))」：缺少 host。")
            }
            (method, password) = try Self.splitCredentials(String(decoded[..<atIndex]), scheme: "ss")
            (host, port) = try Self.splitHostPort(String(decoded[decoded.index(after: atIndex)...]))
        }

        let (plugin, pluginOpts) = Self.shadowsocksPlugin(query)
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            protocolType: .shadowsocks,
            server: host,
            port: port,
            password: password,
            method: method,
            plugin: plugin,
            pluginOpts: pluginOpts
        )
    }

    /// Flattens the SIP002 `plugin=<name>;<opts…>` value into `(plugin, opts)`,
    /// normalizing `simple-obfs`/`obfs` to sing-box's `obfs-local`.
    private static func shadowsocksPlugin(_ query: [String: String]) -> (String?, String?) {
        guard let raw = query["plugin"], !raw.isEmpty else { return (nil, nil) }
        let parts = raw.split(separator: ";").map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        let name = (first == "obfs" || first == "simple-obfs") ? "obfs-local" : first
        let opts = parts.dropFirst().joined(separator: ";")
        return (name, opts.isEmpty ? nil : opts)
    }

    // MARK: - vmess (v2rayN Base64 JSON)

    private func vmessNode(_ link: String) throws -> ProxyNode {
        let blob = String(link.dropFirst("vmess://".count))
        guard
            let json = Self.decodeBase64String(blob),
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw EntryError(message: "跳过 vmess 链接「\(preview(link))」：内容不是 Base64 JSON。")
        }
        guard let server = Self.str(object["add"]), !server.isEmpty else {
            throw EntryError(message: "跳过 vmess 链接：缺少 \"add\"。")
        }
        guard let port = Self.int(object["port"]), (1...65535).contains(port) else {
            throw EntryError(message: "跳过 vmess 链接「\(server)」：缺少或非法的 \"port\"。")
        }
        guard let uuid = Self.str(object["id"]), !uuid.isEmpty else {
            throw EntryError(message: "跳过 vmess 链接「\(server)」：缺少 \"id\"。")
        }

        let tlsEnabled = (Self.str(object["tls"]) ?? "").lowercased() == "tls"
        let host = Self.str(object["host"])
        let sni = Self.str(object["sni"]) ?? (tlsEnabled ? host : nil)
        let transport = Self.transport(
            network: Self.str(object["net"]),
            host: host,
            path: Self.str(object["path"]),
            serviceName: Self.str(object["path"])
        )
        let tls = TLSOptions(
            enabled: tlsEnabled,
            serverName: sni,
            insecure: false,
            alpn: Self.csv(object["alpn"]),
            utlsFingerprint: Self.fingerprint(Self.str(object["fp"]))
        )
        let name = Self.str(object["ps"]).flatMap { $0.isEmpty ? nil : $0 } ?? "\(server):\(port)"
        return ProxyNode(
            name: name,
            protocolType: .vmess,
            server: server,
            port: port,
            uuid: uuid,
            alterId: Self.int(object["aid"]) ?? 0,
            tlsEnabled: tlsEnabled,
            sni: sni,
            tls: tls,
            transport: transport
        )
    }

    // MARK: - vless

    private func vlessNode(_ link: String) throws -> ProxyNode {
        let (uuid, host, port, query, name) = try Self.urlParts(link, scheme: "vless")
        guard let uuid, !uuid.isEmpty else {
            throw EntryError(message: "跳过 vless 链接「\(host):\(port)」：缺少 UUID。")
        }
        let security = (query["security"] ?? "none").lowercased()
        let sni = query["sni"] ?? query["peer"]
        let reality: RealityOptions? = security == "reality"
            ? RealityOptions(publicKey: query["pbk"] ?? "", shortID: query["sid"] ?? "")
            : nil
        let tls = TLSOptions(
            enabled: security != "none",
            serverName: sni,
            insecure: Self.boolFlag(query["allowinsecure"] ?? query["insecure"]),
            alpn: Self.csv(query["alpn"]),
            utlsFingerprint: Self.fingerprint(query["fp"]),
            reality: reality
        )
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            protocolType: .vless,
            server: host,
            port: port,
            uuid: uuid,
            flow: query["flow"].flatMap { $0.isEmpty ? nil : $0 },
            tlsEnabled: tls.enabled,
            sni: sni,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: Self.transport(
                network: query["type"],
                host: query["host"],
                path: query["path"],
                serviceName: query["servicename"]
            )
        )
    }

    // MARK: - trojan

    private func trojanNode(_ link: String) throws -> ProxyNode {
        let (password, host, port, query, name) = try Self.urlParts(link, scheme: "trojan")
        guard let password, !password.isEmpty else {
            throw EntryError(message: "跳过 trojan 链接「\(host):\(port)」：缺少密码。")
        }
        let sni = query["sni"] ?? query["peer"]
        let tls = TLSOptions(
            enabled: true,
            serverName: sni,
            insecure: Self.boolFlag(query["allowinsecure"] ?? query["insecure"]),
            alpn: Self.csv(query["alpn"]),
            utlsFingerprint: Self.fingerprint(query["fp"])
        )
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            protocolType: .trojan,
            server: host,
            port: port,
            password: password,
            tlsEnabled: true,
            sni: sni,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: Self.transport(
                network: query["type"],
                host: query["host"],
                path: query["path"],
                serviceName: query["servicename"]
            )
        )
    }

    // MARK: - hysteria2

    private func hysteria2Node(_ link: String) throws -> ProxyNode {
        let (password, host, port, query, name) = try Self.urlParts(link, scheme: "hysteria2")
        guard let password, !password.isEmpty else {
            throw EntryError(message: "跳过 hysteria2 链接「\(host):\(port)」：缺少密码。")
        }
        let tls = TLSOptions(
            enabled: true,
            serverName: query["sni"],
            insecure: Self.boolFlag(query["insecure"]),
            alpn: Self.csv(query["alpn"])
        )
        var extras: [String] = []
        if let obfs = query["obfs"], !obfs.isEmpty {
            extras.append("obfs=\(obfs)")
            if let pw = query["obfs-password"] { extras.append("obfs-password=\(pw)") }
        }
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            protocolType: .hysteria2,
            server: host,
            port: port,
            password: password,
            tlsEnabled: true,
            sni: query["sni"],
            allowInsecure: tls.insecure,
            tls: tls,
            pluginOpts: extras.isEmpty ? nil : extras.joined(separator: ";")
        )
    }

    // MARK: - tuic

    private func tuicNode(_ link: String) throws -> ProxyNode {
        // tuic://uuid:password@host:port?…
        let (user, host, port, query, name) = try Self.urlParts(link, scheme: "tuic")
        guard let user, !user.isEmpty else {
            throw EntryError(message: "跳过 tuic 链接「\(host):\(port)」：缺少 UUID。")
        }
        let tls = TLSOptions(
            enabled: true,
            serverName: query["sni"],
            insecure: Self.boolFlag(query["allow_insecure"] ?? query["insecure"]),
            alpn: Self.csv(query["alpn"])
        )
        var extras: [String] = []
        if let cc = query["congestion_control"] { extras.append("congestion-control=\(cc)") }
        if let mode = query["udp_relay_mode"] { extras.append("udp-relay-mode=\(mode)") }
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            protocolType: .tuic,
            server: host,
            port: port,
            password: query["password"],   // overridden below if carried in userinfo
            uuid: user,
            tlsEnabled: true,
            sni: query["sni"],
            allowInsecure: tls.insecure,
            tls: tls,
            pluginOpts: extras.isEmpty ? nil : extras.joined(separator: ";")
        )
    }

    // MARK: - URL-shaped link parsing

    /// Splits a URL-shaped link (`scheme://user[:password]@host:port?query#tag`)
    /// into its parts. Returns `user` as the raw userinfo username (uuid /
    /// password depending on protocol); for `tuic` the `password` query slot is
    /// reused below. `name` is the percent-decoded fragment.
    private static func urlParts(
        _ link: String,
        scheme: String
    ) throws -> (user: String?, host: String, port: Int, query: [String: String], name: String) {
        var head = link
        let name = takeFragment(&head)
        guard let comps = URLComponents(string: head) else {
            throw EntryError(message: "跳过 \(scheme) 链接：URL 格式无法解析。")
        }
        guard let host = comps.host, !host.isEmpty else {
            throw EntryError(message: "跳过 \(scheme) 链接：缺少 host。")
        }
        guard let port = comps.port, (1...65535).contains(port) else {
            throw EntryError(message: "跳过 \(scheme) 链接「\(host)」：缺少或非法的端口。")
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }
        // tuic carries uuid:password in userinfo; surface password via the query
        // map so the caller reads it uniformly.
        if scheme == "tuic", let password = comps.password { query["password"] = password }
        return (comps.user, host, port, query, name)
    }

    // MARK: - Shared value helpers

    /// Builds a `TransportOptions` from a share link's `network` + ws/grpc/http
    /// fields, mirroring the Clash parser's transport mapping.
    private static func transport(
        network: String?,
        host: String?,
        path: String?,
        serviceName: String?
    ) -> TransportOptions {
        switch (network ?? "tcp").lowercased() {
        case "ws":
            return TransportOptions(
                type: .ws,
                path: path,
                host: host.flatMap { $0.isEmpty ? nil : [$0] } ?? []
            )
        case "grpc":
            return TransportOptions(type: .grpc, serviceName: serviceName ?? path)
        case "h2", "http":
            return TransportOptions(
                type: .http,
                path: path,
                host: host.flatMap { $0.isEmpty ? nil : [$0] } ?? []
            )
        case "httpupgrade":
            return TransportOptions(
                type: .httpUpgrade,
                path: path,
                host: host.flatMap { $0.isEmpty ? nil : [$0] } ?? []
            )
        default:
            return .tcp
        }
    }

    private static func splitCredentials(_ creds: String, scheme: String) throws -> (String, String) {
        guard let colon = creds.firstIndex(of: ":") else {
            throw EntryError(message: "跳过 \(scheme) 链接：凭据缺少 \"method:password\"。")
        }
        return (String(creds[..<colon]), String(creds[creds.index(after: colon)...]))
    }

    private static func splitHostPort(_ raw: String) throws -> (String, Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            // [ipv6]:port
            guard let close = trimmed.firstIndex(of: "]") else {
                throw EntryError(message: "无法解析 host:port「\(raw)」。")
            }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else {
                throw EntryError(message: "无法解析端口「\(raw)」。")
            }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":"),
              let port = Int(trimmed[trimmed.index(after: colon)...]) else {
            throw EntryError(message: "无法解析 host:port「\(raw)」。")
        }
        return (String(trimmed[..<colon]), port)
    }

    /// Removes and returns the percent-decoded `#fragment` from `body`, leaving
    /// `body` as everything before the `#`.
    private static func takeFragment(_ body: inout String) -> String {
        guard let hash = body.firstIndex(of: "#") else { return "" }
        let fragment = String(body[body.index(after: hash)...])
        body = String(body[..<hash])
        return fragment.removingPercentEncoding ?? fragment
    }

    /// Removes the `?query` from `body` and returns it parsed into a map (values
    /// percent-decoded, keys lowercased). Used by `ss` where URLComponents can't
    /// be relied on because the userinfo is Base64.
    private static func takeQuery(_ body: inout String) -> [String: String] {
        guard let mark = body.firstIndex(of: "?") else { return [:] }
        let query = String(body[body.index(after: mark)...])
        body = String(body[..<mark])
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).lowercased()
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[key] = value.removingPercentEncoding ?? value
        }
        return result
    }

    private static func decodeBase64String(_ raw: String) -> String? {
        guard let data = decodeBase64(raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes standard or URL-safe Base64, tolerating missing padding and
    /// embedded whitespace/newlines.
    static func decodeBase64(_ raw: String) -> Data? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    /// Coerces a JSON value (String/Int) to String.
    private static func str(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(Int(d)) }
        return nil
    }

    /// Coerces a JSON value (Int/String/Double) to Int.
    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Splits a comma-separated value (e.g. `alpn=h2,http/1.1`) into a list,
    /// dropping empties.
    private static func csv(_ value: Any?) -> [String] {
        guard let raw = str(value), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Interprets a query flag (`1`/`true`/`yes`) as a Bool.
    private static func boolFlag(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    /// Maps a `fp`/`client-fingerprint` value to a `UTLSFingerprint`.
    private static func fingerprint(_ raw: String?) -> UTLSFingerprint? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        return UTLSFingerprint(rawValue: raw)
    }

    /// A short, log-safe preview of a link for warning messages.
    private func preview(_ link: String) -> String {
        link.count <= 32 ? link : String(link.prefix(32)) + "…"
    }
}
