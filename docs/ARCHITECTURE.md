# linko Architecture

## Overview

linko is a monorepo containing a SwiftUI menu bar app (`apps/LinkoApp`) and a
local Swift package (`packages/LinkoKit`) that holds all non-UI logic. The
proxy core is [sing-box](https://github.com/SagerNet/sing-box), run as a child
process in milestone 1. The app project is generated with XcodeGen
(`project.yml`); LinkoKit is consumed as a local SPM package dependency.

- Deployment target: macOS 14.0
- Bundle id: `com.gumpw.linko`, `LSUIElement = YES` (menu bar only, no Dock icon)
- LinkoKit: swift-tools-version 6.0, Swift language mode v5
- License: GPL-3.0

## Module map

```
apps/LinkoApp/Sources/            SwiftUI MenuBarExtra app: status header,
                                  system-proxy toggle, node list with delay
                                  badges, subscription import, settings window

packages/LinkoKit/Sources/LinkoKit/
  Models/        ProxyNode, NodeProtocol, Subscription, AppPreferences
  Subscription/  SubscriptionParser — Clash YAML (Yams) -> [ProxyNode]
  SingBox/       SingBoxConfigBuilder — nodes + prefs -> sing-box 1.x JSON
                 CoreRunner — sing-box subprocess lifecycle (Foundation Process)
  System/        SystemProxyManager — macOS system proxy via networksetup
  ClashAPI/      ClashAPIClient — URLSession client for experimental.clash_api
  Contracts.swift  protocols shared across modules (CoreRunning,
                   SystemProxyRunning, ClashAPIProviding, ShellRunning, ...)

scripts/fetch-singbox.sh          downloads the sing-box release binary into
                                  vendor/sing-box/ (gitignored)
```

Testability rule: LinkoKit unit tests never require the sing-box binary or the
network. External process execution is abstracted behind `ShellRunning`, HTTP
behind URLSession (stubbed with `URLProtocol` in tests), and config generation
and parsing are pure functions over value types.

## Data flow

```
subscription URL
      │  download (URLSession)
      ▼
Clash YAML ──SubscriptionParser──▶ [ProxyNode] ──persist──▶ ~/Library/Application Support/linko/*.json
                                        │
                                        ▼
                          SingBoxConfigBuilder (+ AppPreferences)
                                        │  sing-box 1.x JSON
                                        ▼
                          CoreRunner: sing-box run -c <config>
                          (stdout/stderr -> log file under Application Support)
                              │                         │
                              ▼                         ▼
            SystemProxyManager                 ClashAPIClient (127.0.0.1:<apiPort>)
            networksetup: point web/secure-     GET /version, GET /proxies,
            web/SOCKS proxies of all enabled    PUT /proxies/proxy {"name": ...},
            services at 127.0.0.1:<mixedPort>;  GET /proxies/{name}/delay
            restore previous state on disable
```

Generated config shape (milestone 1): one `mixed` inbound on
`127.0.0.1:<mixedPort>`, one outbound per node, a `selector` outbound tagged
`proxy` containing all node tags plus `direct`, a `direct` outbound,
`route.final = "proxy"`, and `experimental.clash_api` on
`127.0.0.1:<clashAPIPort>`. The DNS block is kept minimal/omitted. On node or
preference changes the config is regenerated and the core restarted; node
*selection* while running goes through the Clash API instead (no restart).

## Core lifecycle (milestone 1: subprocess)

`CoreRunner` launches the binary via Foundation `Process`, redirects
stdout/stderr to a log file under `~/Library/Application Support/linko/`, and
terminates the child cleanly on toggle-off and app quit. Binary discovery
order: user override path → `vendor/sing-box/sing-box` (repo dev) →
`/opt/homebrew/bin/sing-box` → `/usr/local/bin/sing-box`; if none is found the
UI points at `scripts/fetch-singbox.sh` or `brew install sing-box`.

## Routing semantics established in plan add-rule-for-current-page (M1)

- **Reject targets are a rule action, not an outbound.** sing-box 1.11+ models
  reject as `{action: "reject"}` with no `outbound` key. `BuiltinReject`
  (`packages/LinkoKit/Sources/LinkoKit/SingBox/RouteBuilder.swift`, public) is
  the single predicate for reject-target detection — case-insensitive,
  covering Surge's REJECT-DROP / REJECT-TINYGIF / REJECT-NO-DROP variants. UI
  and import layers must reuse it instead of re-matching strings. `reject` is
  a reserved node tag (deduplicated case-insensitively); `route.final`, group
  members, and detours must never carry it (the builder falls back with a
  validate() warning; DNS server *tags* are an exempt namespace).
- **Routing edits reload the running core through a debounce.**
  `AppState.updatePreferences` arms a 1.2s trailing-edge `Debouncer`
  (LinkoKit) on a `routing` diff; persistence is always immediate, only the
  core reload coalesces. Port/binary-path deltas reload immediately and
  cancel a pending routing reload; mode/profile switches and shutdown cancel
  it too. Non-preferences reload paths (node edits) are never debounced.
- **App-layer unit tests are host-free.** `apps/LinkoApp/Tests` compiles into
  the LinkoAppTests bundle together with the app sources (no Linko.app test
  host — the LSUIElement launch path would resume the developer's real proxy
  session). Run via `make test-app`; system effects stay behind the
  `AppDependencies` protocols (e.g. `TunnelControlling`).

## Milestone 2 plan: NetworkExtension / TUN (not in current scope)

Replaces the system-proxy approach with an enhanced (TUN) mode so that all
traffic, not just proxy-aware apps, is captured:

- A NetworkExtension **System Extension** (packet tunnel provider) hosting the
  sing-box core via **libbox** (sing-box's library build) instead of a child
  process.
- Requires the `packet-tunnel-provider-systemextension` entitlement on the
  extension target.
- Distribution prerequisite: Developer ID signing + notarization pipeline,
  since system extensions cannot run meaningfully unsigned outside of
  development machines.
- The milestone-1 module boundaries anticipate this: config generation,
  subscription parsing, and the Clash API client are core-hosting-agnostic;
  only `CoreRunner` (subprocess) and `SystemProxyManager` (networksetup) are
  expected to be replaced/augmented by the extension-based mode.
