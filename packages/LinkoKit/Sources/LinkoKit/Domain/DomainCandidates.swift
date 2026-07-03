import Foundation

/// A single routing-rule candidate derived from user input by
/// `DomainCandidateParser`.
///
/// The kind set is deliberately closed to the four rule shapes the
/// "add rule for current page" flow can produce; `ruleType` maps each kind to
/// the `RuleType` it compiles to. IPv6 candidates use `.ipCIDR` as well —
/// sing-box `ip_cidr` accepts both families.
public struct DomainCandidate: Hashable, Sendable {
    /// The closed set of rule kinds a candidate can carry.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        /// Matches the registrable domain and every subdomain (`DOMAIN-SUFFIX`).
        case suffix
        /// Matches the full hostname exactly (`DOMAIN`).
        case host
        /// Matches any hostname containing the label (`DOMAIN-KEYWORD`).
        case keyword
        /// Matches one IP address (`IP-CIDR`, `/32` for IPv4, `/128` for IPv6).
        case ipCIDR

        /// The `RuleType` this kind compiles to.
        public var ruleType: RuleType {
            switch self {
            case .suffix: return .domainSuffix
            case .host: return .domain
            case .keyword: return .domainKeyword
            case .ipCIDR: return .ipCIDR
            }
        }
    }

    public let kind: Kind
    /// A bare lowercase ASCII hostname, a keyword label, or a CIDR literal —
    /// never a URL fragment (no scheme, port, credentials, path or brackets).
    public let value: String

    /// The `RuleType` this candidate compiles to.
    public var ruleType: RuleType { kind.ruleType }

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A successful candidate extraction. The two cases let callers distinguish
/// hostname inputs from IP-literal inputs without inspecting candidate kinds;
/// failure is a separate `Result` branch, so the three states never blur.
public enum DomainCandidateOutcome: Hashable, Sendable {
    /// Domain-family candidates in fixed order: `DOMAIN-SUFFIX` (when the host
    /// has a registrable domain), then `DOMAIN` (when the full host differs
    /// from it), then `DOMAIN-KEYWORD` (when not suppressed). Never empty and
    /// never holds two candidates of the same kind; the first element is the
    /// default.
    case domain([DomainCandidate])
    /// Exactly one `IP-CIDR` candidate (`/32` for IPv4, `/128` for IPv6).
    case ip(DomainCandidate)

    /// All candidates in their fixed presentation order.
    public var candidates: [DomainCandidate] {
        switch self {
        case .domain(let list): return list
        case .ip(let candidate): return [candidate]
        }
    }

    /// The pre-selected candidate — always the first, by construction.
    public var defaultCandidate: DomainCandidate { candidates[0] }
}

/// Why an input produced no candidates. Failure is always distinguishable
/// from success — a successful outcome is never empty.
///
/// Payload discipline (mirrors `BrowserPageReadError`): associated values
/// carry only a category — a scheme or a static shape description — never
/// the authority, host, or any other substring derived from the input URL,
/// so an error can reach a log line without leaking where the user browsed.
public enum DomainCandidateError: Error, Hashable, Sendable {
    /// The input is empty or whitespace-only.
    case emptyInput
    /// The input carries a non-http(s) scheme (`file`, `chrome`, ...).
    case unsupportedScheme(String)
    /// The authority contains no host (`http://`, `http://:8080`).
    case missingHost
    /// The authority is malformed: a non-numeric port (`about:blank` lands
    /// here — `blank` fails the port test), userinfo in schemeless input, or
    /// unbalanced IPv6 brackets. The payload is a fixed reason string, never
    /// a fragment of the input.
    case malformedAuthority(String)
    /// The host is neither a valid domain name nor an IP literal. The
    /// payload is a fixed shape description, never the host itself.
    case invalidHost(String)
}

/// Derives routing-rule candidates from a URL or schemeless host-like input —
/// the pure core of the "add rule for current page" flow. No IO, no AppKit.
///
/// The input grammar is closed by design:
/// - `http(s)://…`: the authority is cut at the first `/`, `?` or `#` and
///   userinfo is stripped. Any other `scheme://…` fails as unsupported.
/// - Schemeless input: the authority is cut the same way, but userinfo is
///   rejected. A `[`-prefixed authority must be a bracketed IPv6 literal; an
///   authority with two or more colons must be a bare IPv6 literal; otherwise
///   the text after the last colon must be a numeric port (`nas:5000` is
///   host + port, `about:blank` is a failure).
///
/// Candidates only depend on the host. Hosts are lowercased, FQDN trailing
/// dots stripped, NFC-normalized, and IDN labels punycode-encoded, so a
/// Unicode host (composed or decomposed) and its ACE form produce identical
/// results. Dotted all-numeric hosts must be
/// canonical IPv4 literals (no leading zeros) or fail. Hosts breaching the
/// RFC 1035 length limits (63 bytes per label, 253 total, on the ASCII form)
/// fail closed.
public struct DomainCandidateParser {
    public init() {}

    public func parse(_ input: String) -> Result<DomainCandidateOutcome, DomainCandidateError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }

        let authority: Substring
        let allowsUserInfo: Bool
        if let (scheme, rest) = Self.splitScheme(trimmed) {
            guard scheme == "http" || scheme == "https" else {
                return .failure(.unsupportedScheme(scheme))
            }
            authority = Self.authority(of: rest)
            allowsUserInfo = true
        } else {
            authority = Self.authority(of: trimmed[...])
            allowsUserInfo = false
        }

        switch Self.splitHostPort(authority, allowsUserInfo: allowsUserInfo) {
        case .failure(let error):
            return .failure(error)
        case .success(.ipv6(let literal)):
            return .success(.ip(DomainCandidate(kind: .ipCIDR, value: literal + "/128")))
        case .success(.name(let host)):
            return Self.classify(host: host)
        }
    }

    // MARK: - Authority

    /// A host extracted from the authority: either a validated IPv6 literal or
    /// a name that may still turn out to be a domain or an IPv4 literal.
    private enum HostToken {
        case name(String)
        case ipv6(String)
    }

    /// Splits `scheme://rest`, returning the lowercased scheme. Inputs without
    /// `://` (including `about:blank`-style ones) are treated as schemeless.
    private static func splitScheme(_ input: String) -> (scheme: String, rest: Substring)? {
        guard let range = input.range(of: "://") else { return nil }
        let scheme = input[input.startIndex..<range.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return (scheme.lowercased(), input[range.upperBound...])
    }

    /// The authority component: everything up to the first `/`, `?`, `#` or
    /// `\`. WHATWG URL parsing treats a backslash like a slash in http(s)
    /// URLs, so `http://evil.com\@good.com/` must derive `evil.com` — cutting
    /// only at `/` would strip `evil.com\` as userinfo and derive the host the
    /// browser never navigates to.
    private static func authority(of text: Substring) -> Substring {
        text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != "\\" }
    }

    private static func splitHostPort(
        _ authority: Substring,
        allowsUserInfo: Bool
    ) -> Result<HostToken, DomainCandidateError> {
        var host = authority
        if let at = host.lastIndex(of: "@") {
            guard allowsUserInfo else {
                return .failure(.malformedAuthority("userinfo is not allowed without a scheme"))
            }
            host = host[host.index(after: at)...]
        }
        guard !host.isEmpty else { return .failure(.missingHost) }

        if host.hasPrefix("[") {
            // Bracketed IPv6: `[addr]` or `[addr]:port`.
            guard let close = host.firstIndex(of: "]") else {
                return .failure(.malformedAuthority("unbalanced IPv6 brackets"))
            }
            let literal = host[host.index(after: host.startIndex)..<close].lowercased()
            let remainder = host[host.index(after: close)...]
            if !remainder.isEmpty {
                guard remainder.first == ":", isNumericPort(remainder.dropFirst()) else {
                    return .failure(.malformedAuthority("invalid text after IPv6 brackets"))
                }
            }
            guard isValidIPv6(literal) else { return .failure(.invalidHost("invalid IPv6 literal")) }
            return .success(.ipv6(literal))
        }

        // A domain-family `host:port` holds at most one colon, so two or more
        // can only be a bare IPv6 literal.
        if host.filter({ $0 == ":" }).count >= 2 {
            let literal = host.lowercased()
            guard isValidIPv6(literal) else { return .failure(.invalidHost("invalid IPv6 literal")) }
            return .success(.ipv6(literal))
        }

        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard isNumericPort(port) else {
                return .failure(.malformedAuthority("non-numeric port"))
            }
            host = host[..<colon]
            guard !host.isEmpty else { return .failure(.missingHost) }
        }
        return .success(.name(String(host)))
    }

    private static func isNumericPort(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Host classification

    private static func classify(host raw: String) -> Result<DomainCandidateOutcome, DomainCandidateError> {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() } // FQDN trailing dot
        guard !host.isEmpty else { return .failure(.missingHost) }

        // NFC before any per-label work: IDNA operates on the precomposed
        // form, so a decomposed input ("cafe" + COMBINING ACUTE) must
        // converge on the same ACE label as its precomposed spelling.
        // Composition never crosses a "." (a starter with no composition
        // entries), so normalizing the whole host is equivalent to
        // normalizing each label.
        host = host.precomposedStringWithCanonicalMapping

        // Cheap scalar-count pre-check before the punycode encoder runs. The
        // wire form is never shorter than the (NFC) scalar count — pure-ASCII
        // labels are byte-for-byte, encoded labels are "xn--" plus at least
        // one digit per scalar — so input past 253 scalars can only fail the
        // post-encoding check anyway. Rejecting it here keeps hostile bulk
        // (tens of thousands of distinct scalars in one label) from burning
        // seconds of CPU in the encoder first.
        guard host.unicodeScalars.count <= 253 else {
            return .failure(.invalidHost("host longer than 253 bytes"))
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else {
            return .failure(.invalidHost("empty label"))
        }

        // A dotted all-numeric host must be a valid IPv4 literal or nothing.
        if labels.allSatisfy({ label in label.allSatisfy { $0.isASCII && $0.isNumber } }) {
            guard let octets = ipv4Octets(labels) else {
                return .failure(.invalidHost("not a valid IPv4 literal"))
            }
            let literal = octets.map(String.init).joined(separator: ".")
            return .success(.ip(DomainCandidate(kind: .ipCIDR, value: literal + "/32")))
        }

        // IDN labels become punycode; ASCII labels pass through unchanged, so
        // Unicode and ACE inputs converge on the same candidates.
        var asciiLabels: [String] = []
        for label in labels {
            guard let ascii = asciiLabel(String(label)) else {
                return .failure(.invalidHost("disallowed character in label"))
            }
            asciiLabels.append(ascii)
        }
        let asciiHost = asciiLabels.joined(separator: ".")

        // RFC 1035 length limits, checked on the ASCII (wire) form: 63 octets
        // per label, 253 for the full host. Oversized input fails closed — no
        // resolver could ever match a rule derived from it, and passing it on
        // would let hostile input smuggle arbitrary bulk into rule values.
        guard asciiLabels.allSatisfy({ $0.utf8.count <= 63 }) else {
            return .failure(.invalidHost("label longer than 63 bytes"))
        }
        guard asciiHost.utf8.count <= 253 else {
            return .failure(.invalidHost("host longer than 253 bytes"))
        }

        // Single-label hosts (localhost, nas) and hosts that are exactly a
        // public-suffix entry (co.uk) have no registrable domain: fall back to
        // an exact DOMAIN candidate with no suffix or keyword.
        guard let registrable = registrableDomain(of: asciiLabels) else {
            return .success(.domain([DomainCandidate(kind: .host, value: asciiHost)]))
        }

        var candidates = [DomainCandidate(kind: .suffix, value: registrable)]
        if asciiHost != registrable {
            candidates.append(DomainCandidate(kind: .host, value: asciiHost))
        }
        if let keyword = keyword(ofRegistrable: registrable) {
            candidates.append(DomainCandidate(kind: .keyword, value: keyword))
        }
        return .success(.domain(candidates))
    }

    /// ASCII form of one already-lowercased host label, or nil when the result
    /// contains characters a hostname label cannot hold. Underscores are
    /// tolerated — they appear in the wild for service hosts.
    private static func asciiLabel(_ label: String) -> String? {
        let ascii: String
        if label.unicodeScalars.allSatisfy(\.isASCII) {
            ascii = label
        } else {
            guard let encoded = Punycode.encode(label) else { return nil }
            ascii = "xn--" + encoded
        }
        guard ascii.allSatisfy(isAllowedHostCharacter) else { return nil }
        return ascii
    }

    private static func isAllowedHostCharacter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character)
            || character == "-" || character == "_"
    }

    /// The registrable domain (public suffix plus one label) of a host, or nil
    /// when the host is a single label or exactly a suffix entry itself.
    ///
    /// Matching uses the built-in table of two-label public suffixes; any
    /// multi-label suffix not in the table falls back to the last two labels.
    private static func registrableDomain(of labels: [String]) -> String? {
        guard labels.count >= 2 else { return nil }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            guard labels.count >= 3 else { return nil } // the host IS the suffix
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// The keyword candidate: the leftmost label of the registrable domain.
    /// Suppressed when shorter than 4 characters (too generic to keyword-match
    /// safely) or punycode-encoded (an ACE string is meaningless as a keyword).
    private static func keyword(ofRegistrable registrable: String) -> String? {
        guard let label = registrable.split(separator: ".").first,
              label.count >= 4, !label.hasPrefix("xn--")
        else { return nil }
        return String(label)
    }

    // MARK: - IP literals

    /// The four octets of a dotted-quad IPv4 literal, or nil. Each octet must
    /// be the canonical decimal spelling (the round-trip check rejects
    /// leading zeros, signs and non-decimal digits): WHATWG/inet_aton parse
    /// `010` as octal, so accepting it decimally would derive a rule for an
    /// address the browser never connects to.
    private static func ipv4Octets(_ labels: [Substring]) -> [Int]? {
        guard labels.count == 4 else { return nil }
        var octets: [Int] = []
        for label in labels {
            guard (1...3).contains(label.count),
                  let value = Int(label), (0...255).contains(value),
                  String(value) == label
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Validates a bracket-free, lowercased IPv6 literal. Accepts `::`
    /// compression and an embedded IPv4 tail (`::ffff:1.2.3.4`).
    private static func isValidIPv6(_ literal: String) -> Bool {
        guard literal.allSatisfy({ $0.isASCII }) else { return false }
        let sections = literal.components(separatedBy: "::")
        guard sections.count <= 2 else { return false }

        func groupCount(_ section: String, allowsIPv4Tail: Bool) -> Int? {
            if section.isEmpty { return 0 }
            let parts = section.components(separatedBy: ":")
            var count = 0
            for (index, part) in parts.enumerated() {
                if part.contains(".") {
                    guard allowsIPv4Tail, index == parts.count - 1,
                          ipv4Octets(part.split(separator: ".", omittingEmptySubsequences: false)) != nil
                    else { return nil }
                    count += 2 // an IPv4 tail spans two 16-bit groups
                } else {
                    guard (1...4).contains(part.count), part.allSatisfy(\.isHexDigit) else { return nil }
                    count += 1
                }
            }
            return count
        }

        if sections.count == 2 {
            guard let head = groupCount(sections[0], allowsIPv4Tail: false),
                  let tail = groupCount(sections[1], allowsIPv4Tail: true)
            else { return false }
            return head + tail <= 7 // `::` stands for at least one zero group
        }
        return groupCount(sections[0], allowsIPv4Tail: true) == 8
    }

    /// Two-label public suffixes under which registered domains sit at the
    /// third label (`example.com.cn`). Deliberately small and closed — any
    /// multi-label suffix not listed here falls back to the last two labels.
    private static let multiLabelSuffixes: Set<String> = [
        // cn
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        // uk
        "co.uk", "org.uk", "net.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "sch.uk",
        // jp
        "co.jp", "ne.jp", "or.jp", "ac.jp", "ad.jp", "ed.jp", "go.jp", "gr.jp", "lg.jp",
        // hk
        "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk", "idv.hk",
        // tw
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw", "idv.tw",
        // au
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        // kr
        "co.kr", "ne.kr", "or.kr", "re.kr", "go.kr", "ac.kr", "pe.kr",
        // nz
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz",
        // in
        "co.in", "net.in", "org.in", "ac.in", "edu.in", "gov.in",
        // br / mx / ar
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.mx", "org.mx", "net.mx", "gob.mx", "edu.mx",
        "com.ar", "net.ar", "org.ar", "gob.ar", "edu.ar",
        // sg / my / id / th / vn / ph
        "com.sg", "edu.sg", "gov.sg", "net.sg", "org.sg",
        "com.my", "net.my", "org.my", "gov.my", "edu.my",
        "co.id", "or.id", "ac.id", "go.id", "web.id",
        "co.th", "in.th", "or.th", "ac.th", "go.th",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn",
        "com.ph", "net.ph", "org.ph",
        // tr / sa / za / il / eg
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.sa", "org.sa", "net.sa", "gov.sa", "edu.sa",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.eg", "org.eg", "net.eg", "gov.eg", "edu.eg",
    ]
}

/// Minimal RFC 3492 punycode encoder — just enough to ACE-encode IDN host
/// labels. Foundation exposes no public IDNA API, and Unicode and
/// already-encoded inputs must produce identical candidates.
private enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// Encodes one label (without the `xn--` prefix), or nil for degenerate
    /// input (empty, or containing no non-ASCII code points).
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        guard !input.isEmpty else { return nil }

        var output = ""
        for scalar in label.unicodeScalars where scalar.isASCII {
            output.unicodeScalars.append(scalar)
        }
        let basicCount = output.unicodeScalars.count
        guard basicCount < input.count else { return nil } // nothing to encode
        if basicCount > 0 { output.append("-") }

        var n = initialN
        var delta = 0
        var bias = initialBias
        var handled = basicCount
        while handled < input.count {
            guard let m = input.lazy.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for codePoint in input {
                if codePoint < n {
                    delta += 1
                } else if codePoint == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = min(max(k - bias, tMin), tMax)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, numPoints: handled + 1, firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    /// Values stay within 0...35 by construction in `encode`.
    private static func digit(_ value: Int) -> Character {
        value < 26
            ? Character(UnicodeScalar(UInt8(97 + value)))      // 'a' + value
            : Character(UnicodeScalar(UInt8(48 + value - 26))) // '0' + (value - 26)
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }
}
