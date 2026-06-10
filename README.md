# linko

linko is an open-source macOS menu bar proxy client built with SwiftUI, using
[sing-box](https://github.com/SagerNet/sing-box) as the proxy core. It supports
Clash YAML subscription import, node selection with latency testing, and
one-click macOS system proxy toggling.

- macOS 14.0+, Apple Silicon & Intel
- Menu bar only (no Dock icon)
- Milestone 1 runs sing-box as a subprocess; TUN/NetworkExtension mode is
  planned for milestone 2 — see [docs/ROADMAP.md](docs/ROADMAP.md)

## Screenshots

> Coming soon.

## Quickstart

Requirements: macOS 14+, Xcode 26.5+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make fetch-core   # download the sing-box binary into vendor/sing-box/
                  # (alternatively: brew install sing-box)
make gen          # generate Linko.xcodeproj with XcodeGen
make build        # unsigned verification build (CODE_SIGNING_ALLOWED=NO)
make test         # run LinkoKit unit tests (swift test, no network needed)
make run          # build and launch the app
```

Then in the menu bar: import a subscription URL (Clash YAML format), pick a
node, and flip the 系统代理 (system proxy) toggle. Settings let you change the
mixed port (default 7890), the Clash API port (default 9090), and override the
sing-box binary path.

linko looks for the sing-box binary in this order: settings override →
`vendor/sing-box/sing-box` → `/opt/homebrew/bin/sing-box` →
`/usr/local/bin/sing-box`.

## Repository layout

```
apps/LinkoApp/        SwiftUI menu bar app
packages/LinkoKit/    Swift package: models, subscription parsing, config
                      generation, core lifecycle, system proxy, Clash API
scripts/              fetch-singbox.sh (downloads the core binary)
docs/                 PRODUCT.md / ARCHITECTURE.md / ROADMAP.md
```

## Documentation

- [docs/PRODUCT.md](docs/PRODUCT.md) — product positioning and MVP scope (中文)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map and data flow
- [docs/ROADMAP.md](docs/ROADMAP.md) — milestones

## License

linko is licensed under [GPL-3.0](LICENSE), compatible with the license of
sing-box, which it uses as its proxy core.

sing-box is © SagerNet and its contributors, also distributed under GPL-3.0
with an additional clause requiring that derived projects not use "sing-box"
in their name without authorization — linko complies by using its own name and
downloading official, unmodified sing-box release binaries rather than
shipping a fork.
