#!/usr/bin/env bash
#
# release.sh — orchestrate Linko's Developer ID release pipeline.
#
# Subcommands:
#   archive     xcodegen generate + xcodebuild archive + extract the signed
#               .app from the xcarchive + re-sign nested ad-hoc helpers
#   notarize    submit a path (.app or .dmg) to Apple notary, wait, staple
#   dmg         package the exported .app into a signed DMG
#   appcast     generate a signed appcast.xml for the built DMG
#   release     archive -> notarize app -> dmg -> notarize dmg -> appcast
#
# Usage:
#   ./scripts/release.sh archive
#   ./scripts/release.sh release
#   ./scripts/release.sh --help
#
# Signing is driven by project.yml (CODE_SIGN_STYLE=Manual, Developer ID
# Application, and the "Linko DeveloperID"/"LinkoTunnel DeveloperID"
# provisioning profiles). Unlike a profile-less Developer ID app we do NOT
# override the identity on the command line, because the system extension's
# `packet-tunnel-provider-systemextension` entitlement is profile-gated and
# the build settings already select the right profile per target. The matching
# profiles must be installed in ~/Library/MobileDevice/Provisioning Profiles/.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"

project="${srcroot}/Linko.xcodeproj"
scheme="LinkoApp"
repo="wanggang316/linko"
release_dir="${srcroot}/.build/release"
archive_path="${release_dir}/Linko.xcarchive"
export_dir="${release_dir}/export"
app_path="${export_dir}/Linko.app"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
release.sh — orchestrate Linko's Developer ID release pipeline.

Subcommands:
  archive     xcodegen generate + xcodebuild archive + extract the signed
              .app from the xcarchive + re-sign nested ad-hoc helpers
  notarize    submit a path (.app or .dmg) to Apple notary, wait, staple
  dmg         package the exported .app into a signed DMG
  appcast     generate a signed appcast.xml for the built DMG
  release     archive -> notarize app -> dmg -> notarize dmg -> appcast

Usage:
  ./scripts/release.sh release            # full pipeline
  ./scripts/release.sh archive            # just build + sign
  ./scripts/release.sh appcast [version]  # regenerate the feed for a DMG

Signing is driven by project.yml (Manual + Developer ID + the
"Linko DeveloperID"/"LinkoTunnel DeveloperID" provisioning profiles).
appcast signs each item with the EdDSA private key in the login Keychain;
override the tools dir with SPARKLE_BIN if generate_appcast isn't found.
EOF
}

# Locate Sparkle's generate_appcast: prefer $SPARKLE_BIN, else the SPM
# artifact resolved into DerivedData.
resolve_generate_appcast() {
  if [ -n "${SPARKLE_BIN:-}" ] && [ -x "${SPARKLE_BIN}/generate_appcast" ]; then
    printf '%s' "${SPARKLE_BIN}/generate_appcast"
    return
  fi
  local tool
  tool="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -path "*artifacts*sparkle*bin/generate_appcast" 2>/dev/null | head -1)"
  [ -n "${tool}" ] || die "generate_appcast not found. Build once (so SPM resolves Sparkle) or set SPARKLE_BIN."
  printf '%s' "${tool}"
}

# Developer ID Application identity SHA-1 (exact fingerprint avoids ambiguity
# when several Developer ID certs are in the keychain). Override via env.
resolve_identity_sha() {
  if [ -n "${DEVELOPER_ID_IDENTITY_SHA:-}" ]; then
    printf '%s' "${DEVELOPER_ID_IDENTITY_SHA}"
    return
  fi
  local sha
  sha="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
  [ -n "${sha}" ] || die "Developer ID Application identity not in keychain (security find-identity -v -p codesigning)."
  printf '%s' "${sha}"
}

read_marketing_version() {
  /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "${app_path}/Contents/Info.plist" 2>/dev/null \
    || die "cannot read CFBundleShortVersionString from ${app_path}"
}

cmd_archive() {
  log "regenerating project (xcodegen)"
  (cd "${srcroot}" && xcodegen generate >/dev/null)

  log "archiving ${scheme} (Release)"
  rm -rf "${archive_path}" "${export_dir}"
  mkdir -p "${release_dir}" "${export_dir}"

  xcodebuild archive \
    -project "${project}" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    SKIP_INSTALL=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO

  # Bypass `xcodebuild -exportArchive`: for Developer ID it would only cp -R
  # the already-signed bundle while dragging in the IDE distribution manager,
  # which fails headless without a logged-in Apple ID. Copy the signed .app
  # straight out of the xcarchive instead, preserving its signature.
  log "extracting signed app from xcarchive"
  /bin/cp -R "${archive_path}/Products/Applications/Linko.app" "${export_dir}/"
  [ -d "${app_path}" ] || die "Linko.app not found inside the xcarchive"

  local identity_sha
  identity_sha="$(resolve_identity_sha)"
  log "re-signing nested helpers (identity ${identity_sha})"
  DEVELOPER_ID_IDENTITY_SHA="${identity_sha}" "${script_dir}/resign-nested.sh" "${app_path}"

  if codesign -dv "${app_path}" 2>&1 | grep -q "Signature=adhoc"; then
    die "archive produced an ad-hoc signature instead of Developer ID."
  fi
  # spctl reports 'rejected: source=Notarization' until notarize runs; expected.
  spctl -a -v -t exec "${app_path}" || true
  log "archive ready: ${app_path}"
}

cmd_notarize() {
  local target="${1:-${app_path}}"
  [ -e "${target}" ] || die "missing ${target}. Run release.sh archive first."
  "${script_dir}/notarize.sh" "${target}"
}

cmd_dmg() {
  [ -d "${app_path}" ] || die "missing ${app_path}. Run release.sh archive first."
  local version="${1:-$(read_marketing_version)}"
  local identity_sha
  identity_sha="$(resolve_identity_sha)"
  local dmg_path="${release_dir}/Linko-${version}.dmg"
  "${script_dir}/make-dmg.sh" "${app_path}" "${dmg_path}" "${identity_sha}"
  printf '%s\n' "${dmg_path}"
}

cmd_appcast() {
  local version="${1:-$(read_marketing_version)}"
  local dmg_path="${release_dir}/Linko-${version}.dmg"
  [ -f "${dmg_path}" ] || die "missing ${dmg_path}. Run release.sh dmg first."
  local tool
  tool="$(resolve_generate_appcast)"

  # Stage just this DMG so generate_appcast emits a single signed item whose
  # enclosure points at the GitHub release asset (the canonical feed served
  # from releases/latest/download/appcast.xml re-attaches this file). The
  # EdDSA signature is produced from the private key in the login Keychain.
  local feed_dir="${release_dir}/feed"
  rm -rf "${feed_dir}"
  mkdir -p "${feed_dir}"
  /bin/cp "${dmg_path}" "${feed_dir}/"
  "${tool}" \
    --download-url-prefix "https://github.com/${repo}/releases/download/v${version}/" \
    --maximum-versions 5 \
    "${feed_dir}"
  /bin/cp "${feed_dir}/appcast.xml" "${release_dir}/appcast.xml"
  log "appcast: ${release_dir}/appcast.xml"
  printf '%s\n' "${release_dir}/appcast.xml"
}

cmd_release() {
  cmd_archive
  log "notarizing app"
  "${script_dir}/notarize.sh" "${app_path}"
  local version
  version="$(read_marketing_version)"
  local dmg_path="${release_dir}/Linko-${version}.dmg"
  log "packaging DMG"
  cmd_dmg "${version}" >/dev/null
  log "notarizing DMG"
  "${script_dir}/notarize.sh" "${dmg_path}"
  log "generating appcast"
  cmd_appcast "${version}" >/dev/null
  log "release ready: ${dmg_path}"
  log "          and: ${release_dir}/appcast.xml"
}

main() {
  case "${1:-}" in
    archive) shift; cmd_archive "$@" ;;
    notarize) shift; cmd_notarize "$@" ;;
    dmg) shift; cmd_dmg "$@" ;;
    appcast) shift; cmd_appcast "$@" ;;
    release) shift; cmd_release "$@" ;;
    -h | --help | help | "") print_usage ;;
    *) die "unknown subcommand: ${1}. Run release.sh --help." ;;
  esac
}

main "$@"
