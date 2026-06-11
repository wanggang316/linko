#!/usr/bin/env bash
#
# make-dmg.sh — package a signed Linko.app into a Developer-ID-signed
# DMG using only hdiutil + codesign (no brew create-dmg dependency).
#
# Deliberately simplified vs. a fancy installer DMG: no custom volume
# icon, no rendered background, no chevron art. The DMG ships a single
# Finder layout — Linko.app on the left, an /Applications symlink on the
# right — which is enough to drag-install. The emphasis is on producing
# a reproducible, signed, checksummed artifact.
#
# Usage:
#   ./scripts/make-dmg.sh <path-to-app> <output-dmg> <signing-identity>
#
set -euo pipefail

app_path="${1:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
dmg_path="${2:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
identity="${3:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"

[ -d "${app_path}" ] || { echo "error: ${app_path} is not a directory" >&2; exit 1; }

vol_name="Linko"

# Refuse to wrap an unsigned (or improperly-signed) .app in a signed
# DMG. codesign --strict --deep walks the entire bundle and catches
# unsigned helpers (e.g., a stale embedded core or system extension)
# that would otherwise sail through to a notarization failure later.
echo "==> verifying ${app_path} signature before staging"
codesign --verify --deep --strict --verbose=2 "${app_path}"

work_dir="$(mktemp -d -t linko-dmg)"
stage_dir="${work_dir}/stage"
mkdir -p "${stage_dir}"

cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

echo "==> staging DMG contents"
/bin/cp -R "${app_path}" "${stage_dir}/"
ln -s /Applications "${stage_dir}/Applications"

mkdir -p "$(dirname "${dmg_path}")"
rm -f "${dmg_path}"

echo "==> hdiutil create compressed UDZO ${dmg_path}"
hdiutil create \
  -volname "${vol_name}" \
  -srcfolder "${stage_dir}" \
  -ov \
  -format UDZO \
  "${dmg_path}" \
  >/dev/null

echo "==> signing DMG"
# A DMG is a flat container, not a runnable bundle — no hardened runtime
# (-o runtime) needed; just a Developer ID signature + secure timestamp.
codesign --force --sign "${identity}" --timestamp "${dmg_path}"
codesign --verify --verbose=2 "${dmg_path}"

echo "==> writing checksum"
# Standard `shasum -a 256` output (hash + filename). This MUST match the
# format notarize.sh regenerates after stapling, so the sidecar stays
# coherent through the notarize step.
sha256_path="${dmg_path}.sha256"
( cd "$(dirname "${dmg_path}")" && shasum -a 256 "$(basename "${dmg_path}")" > "$(basename "${sha256_path}")" )
cat "${sha256_path}"

echo "==> ${dmg_path}"
