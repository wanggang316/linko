#!/usr/bin/env bash
#
# resign-nested.sh — re-sign ad-hoc nested code inside Linko.app with the
# Developer ID identity, deepest-first, so Apple's notary service accepts the
# bundle.
#
# Why this exists: `xcodebuild archive` deep-signs the bundle but leaves
# framework-bundled XPC services (Sparkle's Installer.xpc / Downloader.xpc)
# with their original ad-hoc signatures. Notarization rejects ad-hoc inner
# code under a Developer-ID outer bundle. Re-signing deepest-first keeps each
# parent's CodeResources hashes consistent.
#
# Deliberately NOT re-signed:
#   - Contents/Library/SystemExtensions/*.systemextension — already signed at
#     archive time with Developer ID, its own provisioning profile, and the
#     profile-gated `packet-tunnel-provider-systemextension` entitlement.
#     Re-signing here risks stripping that entitlement, so we leave it intact
#     (it is not under any root we walk).
#   - Contents/MacOS/<main executable> — sealed by the final outer-app re-sign.
#
# Usage: DEVELOPER_ID_IDENTITY_SHA=<sha1> resign-nested.sh <app-path>

set -euo pipefail

app_path="${1:?usage: resign-nested.sh <app-path>}"
identity="${DEVELOPER_ID_IDENTITY_SHA:?DEVELOPER_ID_IDENTITY_SHA not set}"
[ -d "$app_path" ] || { echo "error: $app_path is not a bundle" >&2; exit 1; }

log() { echo "==> $*"; }

# Roots within the bundle that can hold nested code. SystemExtensions and
# Contents/MacOS are intentionally excluded (see header).
roots=(
  "Contents/Frameworks"
  "Contents/PlugIns"
  "Contents/XPCServices"
  "Contents/Library/LoginItems"
  "Contents/Resources"
)

# Entitlement-bearing bundles keep their metadata; plain Mach-O (dylibs, the
# vendored sing-box, helper tools) get a clean hardened-runtime re-sign.
needs_preserve() {
  case "$1" in
    *.app | *.appex | *.xpc) return 0 ;;
    *) return 1 ;;
  esac
}

sign_one() {
  local path="$1"
  local args=(-f -s "$identity" -o runtime --timestamp -v)
  needs_preserve "$path" && args+=(--preserve-metadata=entitlements,requirements,flags)
  codesign "${args[@]}" "$path" 2>&1 | sed 's/^/    /'
}

# Collect nested bundles + loose Mach-O, then sort deepest-first (most path
# separators first) so children are signed before their containers.
collected=()
while IFS= read -r path; do
  collected+=("$path")
done < <(
  for r in "${roots[@]}"; do
    [ -d "$app_path/$r" ] || continue
    find "$app_path/$r" \( -name "*.app" -o -name "*.appex" -o -name "*.framework" -o -name "*.xpc" \) -type d
    find "$app_path/$r" \( -name "*.dylib" -o -perm -111 \) -type f
  done | sort -u | awk '{ n = gsub(/\//, "/"); print n "\t" $0 }' | sort -rn -k1,1 | cut -f2-
)

log "re-signing ${#collected[@]} nested item(s) under $(basename "$app_path")"
for path in "${collected[@]}"; do
  sign_one "$path"
done

log "sealing the outer bundle"
codesign -f -s "$identity" -o runtime --timestamp \
  --preserve-metadata=entitlements,requirements,flags -v "$app_path" 2>&1 | sed 's/^/    /'

log "verifying (--strict --deep)"
codesign --verify --strict --deep --verbose=2 "$app_path"
log "nested re-sign complete"
