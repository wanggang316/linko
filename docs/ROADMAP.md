# linko Roadmap

## M1 — MVP: menu bar client with subprocess core (current)

- [x] Monorepo scaffold: XcodeGen app project + local SPM package LinkoKit
- [x] Models: `ProxyNode`, `NodeProtocol`, `Subscription`, `AppPreferences`
- [x] Subscription import: Clash YAML parsing (ss / vmess / trojan / vless / hysteria2 / tuic), skip-with-warning for unknown/invalid entries
- [x] sing-box 1.x config generation: mixed inbound, per-node outbounds, `proxy` selector, direct outbound, `route.final = "proxy"`, Clash API
- [x] Core lifecycle: `sing-box run` subprocess, log capture, restart on config change, clean termination
- [x] Binary discovery (override → vendor → Homebrew) + `scripts/fetch-singbox.sh`
- [x] System proxy toggle via `networksetup` with previous-state restoration
- [x] Clash API client: version, proxies, selector switch, delay test
- [x] Menu bar UI: status header, 系统代理 toggle, node list with delay badges, subscription import, settings window, quit
- [x] JSON persistence under `~/Library/Application Support/linko/`
- [x] Unit tests without network or sing-box binary (config builder, YAML fixtures, API request building, networksetup argument construction)

## M2 — TUN / enhanced mode

- [ ] NetworkExtension System Extension (packet tunnel provider) hosting the core via libbox
- [ ] `packet-tunnel-provider-systemextension` entitlement and extension target
- [ ] Mode switch in UI: system proxy mode ↔ TUN mode
- [ ] Developer ID signing required for system extension development/distribution

## M3 — Rule management

- [ ] Routing rule management UI (domain/IP/process based rules)
- [ ] `rule_set` support (remote/local rule sets) in config generation
- [ ] Per-rule outbound targets (proxy / direct / block)

## M4 — Distribution

- [ ] Sparkle-based in-app updates
- [ ] Developer ID signing + notarization pipeline (CI)
- [ ] Release packaging (dmg) and GitHub Releases automation
