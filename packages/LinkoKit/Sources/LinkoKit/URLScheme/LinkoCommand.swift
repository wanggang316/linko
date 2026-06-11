import Foundation

/// A control action linko can be driven by, decoded from a `linko://` URL (the
/// app's custom URL scheme) and dispatched against `AppState`. Keeping this a
/// pure value separate from the parser lets the whole scheme be unit-tested
/// without AppKit, and lets the CLI and any future automation reuse the exact
/// same vocabulary.
///
/// Supported URLs (host = action, params via query):
/// - `linko://on` / `linko://off` / `linko://toggle` — proxy on/off
/// - `linko://mode?value=tun` / `?value=system` — switch interception mode
/// - `linko://select?node=<name>` — select a proxy node by display name
/// - `linko://profile?name=<name>` — switch the active profile by name
/// - `linko://install-config?url=<url>&name=<name>` — import a subscription
/// - `linko://test` — run a delay test across nodes
public enum LinkoCommand: Equatable, Sendable {
    case enableProxy
    case disableProxy
    case toggleProxy
    case setMode(ProxyMode)
    case selectNode(name: String)
    case switchProfile(name: String)
    /// Importing a subscription from an arbitrary URL is privileged: a webpage
    /// could trigger it, so the dispatcher must confirm with the user first.
    case installConfig(url: URL, name: String?)
    case testDelays

    /// Whether executing this command has an irreversible / privileged effect
    /// that warrants a user confirmation prompt before it runs. Only
    /// `installConfig` (fetches and trusts a remote config) qualifies; the
    /// on/off/select/mode actions are reversible and low-harm.
    public var requiresConfirmation: Bool {
        if case .installConfig = self { return true }
        return false
    }
}

/// Parses `linko://` URLs into `LinkoCommand`s. The single source of truth for
/// the scheme grammar, shared by the app's URL handler and the `scripts/linko`
/// CLI (which emits these same URLs).
public enum LinkoURLScheme {
    /// The registered custom scheme (also declared in the app's Info.plist).
    public static let scheme = "linko"

    /// Decodes a `linko://…` URL into a command, or `nil` when the scheme,
    /// action, or required parameters are missing/unrecognized.
    public static func command(from url: URL) -> LinkoCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // The action is the URL "host" (e.g. linko://toggle). An empty authority
        // (linko:///toggle) yields an empty host, so fall back to the first path
        // segment in that case.
        let hostAction = components.host.flatMap { $0.isEmpty ? nil : $0 }
        let action = (hostAction ?? components.path.split(separator: "/").first.map(String.init) ?? "")
            .lowercased()

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        switch action {
        case "on", "enable", "start":
            return .enableProxy
        case "off", "disable", "stop":
            return .disableProxy
        case "toggle":
            return .toggleProxy
        case "test", "test-delays", "testdelays":
            return .testDelays
        case "mode":
            guard let mode = parseMode(query["value"] ?? query["mode"]) else { return nil }
            return .setMode(mode)
        case "select", "select-node":
            guard let name = nonEmpty(query["node"] ?? query["name"]) else { return nil }
            return .selectNode(name: name)
        case "profile", "switch-profile":
            guard let name = nonEmpty(query["name"] ?? query["profile"]) else { return nil }
            return .switchProfile(name: name)
        case "install-config", "install", "import":
            guard let raw = nonEmpty(query["url"]), let target = URL(string: raw),
                  let scheme = target.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return .installConfig(url: target, name: nonEmpty(query["name"]))
        default:
            return nil
        }
    }

    private static func parseMode(_ value: String?) -> ProxyMode? {
        switch value?.lowercased() {
        case "tun", "global", "tun_global":
            return .tun
        case "system", "system_proxy", "system-proxy", "proxy":
            return .systemProxy
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
