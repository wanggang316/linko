#!/bin/sh
# Build Libbox.xcframework (sing-box embedded as a library) for the macOS
# NetworkExtension TUN provider. Output: vendor/libbox/Libbox.xcframework
# (gitignored; a fetched build artifact like the sing-box binary).
#
# Why build from a sing-box checkout instead of a fresh module: sing-box pins
# a specific sing-tun version in its go.mod, and resolving it independently
# picks an incompatible one (missing interface methods). Building inside the
# tagged checkout uses the correct pinned dependency graph.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The libbox core and the bundled sing-box binary must be the same version:
# the app validates configs with the binary that the extension then runs.
SING_BOX_VERSION="${SING_BOX_VERSION:-$(cat "$REPO_ROOT/scripts/sing-box-version")}"
# Client-focused tags: gVisor TUN stack, QUIC (Hysteria2/TUIC), WireGuard,
# uTLS (Reality client), Clash API (dashboard).
TAGS="${TAGS:-with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api}"

OUT="$REPO_ROOT/vendor/libbox/Libbox.xcframework"
WORK="$(mktemp -d)"
GOPATH="$(go env GOPATH)"
export PATH="$PATH:$GOPATH/bin"

echo "==> Installing gomobile/gobind"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

echo "==> Cloning sing-box $SING_BOX_VERSION"
git clone --depth 1 --branch "$SING_BOX_VERSION" \
  https://github.com/SagerNet/sing-box.git "$WORK/sing-box"
cd "$WORK/sing-box"

echo "==> Adding gomobile bind dependency (sing-tun stays pinned by go.mod)"
GOFLAGS=-mod=mod go get golang.org/x/mobile/bind@latest

echo "==> Building Libbox.xcframework (tags: $TAGS)"
rm -rf "$OUT"
mkdir -p "$REPO_ROOT/vendor/libbox"
GOFLAGS=-mod=mod gomobile bind -target macos -tags "$TAGS" \
  -o "$OUT" ./experimental/libbox

echo "==> Done: $OUT"
du -sh "$OUT"
rm -rf "$WORK"
