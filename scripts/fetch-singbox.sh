#!/bin/sh
# fetch-singbox.sh — download the latest sing-box darwin release binary
# into vendor/sing-box/sing-box (gitignored). Idempotent: re-running when
# the installed binary already matches the latest release is a no-op.
#
# Requires: curl, tar, and either jq or python3 (for JSON parsing).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/vendor/sing-box"
DEST_BIN="$DEST_DIR/sing-box"
API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# --- arch detection -------------------------------------------------------
case "$(uname -m)" in
    arm64 | aarch64) ARCH="arm64" ;;
    x86_64)          ARCH="amd64" ;;
    *)
        echo "error: unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

# --- fetch release metadata ----------------------------------------------
echo "Querying latest sing-box release (darwin-$ARCH)..."
RELEASE_JSON="$(curl -fsSL "$API_URL")"

if command -v jq >/dev/null 2>&1; then
    TAG="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
    ASSET_URL="$(printf '%s' "$RELEASE_JSON" | jq -r \
        --arg suffix "darwin-$ARCH.tar.gz" \
        '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' \
        | head -n 1)"
elif command -v python3 >/dev/null 2>&1; then
    TAG="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
print(json.load(sys.stdin)["tag_name"])
')"
    ASSET_URL="$(printf '%s' "$RELEASE_JSON" | ARCH="$ARCH" python3 -c '
import json, os, sys
suffix = "darwin-%s.tar.gz" % os.environ["ARCH"]
for asset in json.load(sys.stdin)["assets"]:
    if asset["name"].endswith(suffix):
        print(asset["browser_download_url"])
        break
')"
else
    echo "error: need jq or python3 to parse the GitHub releases API response" >&2
    exit 1
fi

if [ -z "$TAG" ] || [ "$TAG" = "null" ] || [ -z "$ASSET_URL" ]; then
    echo "error: could not resolve a darwin-$ARCH asset in the latest release" >&2
    exit 1
fi

VERSION="${TAG#v}"

# --- idempotency check ----------------------------------------------------
if [ -x "$DEST_BIN" ]; then
    INSTALLED="$("$DEST_BIN" version 2>/dev/null | head -n 1 || true)"
    case "$INSTALLED" in
        *"$VERSION"*)
            echo "Already up to date: $DEST_BIN ($INSTALLED)"
            exit 0
            ;;
    esac
fi

# --- download and extract -------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

TARBALL="$TMP_DIR/sing-box.tar.gz"
echo "Downloading sing-box $TAG..."
curl -fL --progress-bar -o "$TARBALL" "$ASSET_URL"

tar -xzf "$TARBALL" -C "$TMP_DIR"

EXTRACTED_BIN="$(find "$TMP_DIR" -type f -name sing-box | head -n 1)"
if [ -z "$EXTRACTED_BIN" ]; then
    echo "error: sing-box binary not found inside the downloaded tarball" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
mv -f "$EXTRACTED_BIN" "$DEST_BIN"
chmod +x "$DEST_BIN"

echo "Installed: $DEST_BIN"
"$DEST_BIN" version | head -n 1
