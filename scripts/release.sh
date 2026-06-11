#!/usr/bin/env bash
#
# release.sh — orchestrate Linko's Developer ID release pipeline.
#
# Subcommands:
#   archive     xcodegen generate + xcodebuild archive + extract the signed
#               .app from the xcarchive + re-sign nested ad-hoc helpers
#   notarize    submit a path (.app or .dmg) to Apple notary, wait, staple
#   dmg         package the exported .app into a signed DMG
#   release     archive -> notarize app -> dmg -> notarize dmg
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
release_dir="${srcroot}/.build/release"
archive_path="${release_dir}/Linko.xcarchive"
export_dir="${release_dir}/export"
app_path="${export_dir}/Linko.app"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
  log "release ready: ${dmg_path}"
}

main() {
  case "${1:-}" in
    archive) shift; cmd_archive "$@" ;;
    notarize) shift; cmd_notarize "$@" ;;
    dmg) shift; cmd_dmg "$@" ;;
    release) shift; cmd_release "$@" ;;
    -h | --help | help | "") print_usage ;;
    *) die "unknown subcommand: ${1}. Run release.sh --help." ;;
  esac
}

main "$@"
