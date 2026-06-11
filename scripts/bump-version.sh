#!/usr/bin/env bash
#
# bump-version.sh — set MARKETING_VERSION + CURRENT_PROJECT_VERSION in
# the top-level `settings.base` of project.yml (XcodeGen).
#
# project.yml is the single source of truth for the app version, shared
# by every target so the app and its embedded system extension stay in
# lockstep. After this file is updated we run `xcodegen generate` so the
# regenerated project (and its synthesized Info.plist) reflects the new
# version immediately.
#
# Build-number scheme: YYYYMMDD + 3-digit sequence (e.g. 20260510001).
# Each release queries the published appcast for the highest existing
# build number, then increments by 1. A new calendar day resets the
# sequence to 001.
#   20260510001
#   20260510002
#   20260511001  (new day, sequence resets)
#
# Usage:
#   bump-version.sh <X.Y.Z>          # marketing version; build = today (or todayN if same day)
#   bump-version.sh <X.Y.Z> <BUILD>  # set both explicitly (BUILD must be > current)
#   bump-version.sh --print          # show current values + suggested next bump
#   bump-version.sh --help
#
# Examples:
#   bump-version.sh 0.1.6               # build becomes e.g. 20260511001
#   bump-version.sh 0.1.7               # later same day → build becomes 20260511002
#   bump-version.sh 0.2.0 20260601001   # explicit override
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
project_yml="${srcroot}/project.yml"

appcast_url="https://github.com/wanggang316/linko/releases/latest/download/appcast.xml"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
bump-version.sh — bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml.

Usage:
  bump-version.sh <X.Y.Z>          set marketing version, increment build by 1
  bump-version.sh <X.Y.Z> <BUILD>  set both explicitly
  bump-version.sh --print          show current values + suggested patch bump
  bump-version.sh --help
EOF
}

# Read a `    KEY: "value"` line from the top-level settings.base block.
# Matches the leading-whitespace + KEY:, strips surrounding quotes and
# whitespace, returns the bare value.
read_field() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
      sub(/^[[:space:]]*[A-Za-z_]+[[:space:]]*:[[:space:]]*/, "", $0)
      gsub(/"/, "", $0)
      gsub(/[ \t\r]/, "", $0)
      print $0
      exit
    }' "$project_yml"
}

semver_check() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '$1' must match X.Y.Z (digits only)"
}

# Returns 0 (true) if $1 is strictly greater than $2 (both X.Y.Z).
semver_gt() {
  local a="$1" b="$2"
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  (( a1 != b1 )) && { (( a1 > b1 )); return; }
  (( a2 != b2 )) && { (( a2 > b2 )); return; }
  (( a3 >  b3 ))
}

next_patch() {
  local v="$1"
  IFS=. read -r x y z <<<"$v"
  echo "$x.$y.$((z + 1))"
}

# Query the published appcast for the highest build number. Returns
# empty on the first release (no appcast yet) or any network error —
# never fail the script over an unreachable feed.
max_published_build() {
  curl -fsSL --max-time 10 "${appcast_url}" 2>/dev/null \
    | grep -oE '<sparkle:version>[^<]+' \
    | sed 's/<sparkle:version>//' \
    | sort -n \
    | tail -1 || true
}

# Compute the next YYYYMMDDNNN build number. Takes the current project.yml
# value as a floor, queries the published appcast for the highest build,
# and increments. A new calendar day starts at NNN=001.
next_build() {
  local cur="$1"
  local today
  today="$(date +%Y%m%d)"
  local today_base="${today}000"

  local max_pub
  max_pub="$(max_published_build)"

  local base="$cur"
  if [[ -n "$max_pub" ]] && (( max_pub > base )); then
    base="$max_pub"
  fi

  if (( base >= today_base )); then
    # Same day (or TZ-skewed future): increment from base
    printf '%d\n' $((base + 1))
  else
    # New day: start at today + 001
    printf '%s001\n' "$today"
  fi
}

cmd_print() {
  local mv pv next_mv next_pv max_pub
  mv="$(read_field MARKETING_VERSION)"
  pv="$(read_field CURRENT_PROJECT_VERSION)"
  next_mv="$(next_patch "$mv")"
  max_pub="$(max_published_build)"
  next_pv="$(next_build "$pv")"
  cat <<EOF
project.yml: $project_yml

  MARKETING_VERSION       = $mv
  CURRENT_PROJECT_VERSION = $pv
  Published max build     = ${max_pub:-<none>}

next patch: $next_mv (build $next_pv)
EOF
}

cmd_bump() {
  local new_mv="$1" new_pv="${2:-}"
  semver_check "$new_mv"

  [[ -f "$project_yml" ]] || die "$project_yml not found"

  local cur_mv cur_pv
  cur_mv="$(read_field MARKETING_VERSION)"
  cur_pv="$(read_field CURRENT_PROJECT_VERSION)"
  [[ -n "$cur_mv" ]] || die "MARKETING_VERSION not found in $project_yml"
  [[ -n "$cur_pv" ]] || die "CURRENT_PROJECT_VERSION not found in $project_yml"

  if [[ "$new_mv" == "$cur_mv" ]]; then
    die "new MARKETING_VERSION ($new_mv) == current; nothing to bump"
  fi
  if ! semver_gt "$new_mv" "$cur_mv"; then
    die "new MARKETING_VERSION ($new_mv) is not greater than current ($cur_mv); use a forward-rolling version"
  fi

  if [[ -z "$new_pv" ]]; then
    new_pv="$(next_build "$cur_pv")"
    if (( new_pv <= cur_pv )); then
      die "computed date-based build ($new_pv) is not > current ($cur_pv); pass an explicit BUILD override"
    fi
  else
    [[ "$new_pv" =~ ^[0-9]+$ ]] || die "build number '$new_pv' must be a positive integer"
    (( new_pv > cur_pv )) || die "new build ($new_pv) must be > current ($cur_pv)"
  fi

  log "MARKETING_VERSION:       $cur_mv -> $new_mv"
  log "CURRENT_PROJECT_VERSION: $cur_pv -> $new_pv"

  # Two anchored substitutions — use a tmpfile so we never half-write.
  # Preserve the original leading indentation and re-quote the value to
  # keep project.yml's `    KEY: "value"` style intact.
  local tmp
  tmp="$(mktemp "${project_yml}.bump.XXXXXX")"
  awk -v mv="$new_mv" -v pv="$new_pv" '
    /^[[:space:]]*MARKETING_VERSION[[:space:]]*:/ {
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
      print indent "MARKETING_VERSION: \"" mv "\""; next
    }
    /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*:/ {
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
      print indent "CURRENT_PROJECT_VERSION: \"" pv "\""; next
    }
    { print }
  ' "$project_yml" >"$tmp"

  # Sanity: post-condition matches what we asked for. Re-read both
  # fields out of the staged tmpfile using the same parser.
  local check_mv check_pv
  check_mv="$(awk -v k="MARKETING_VERSION" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
      sub(/^[[:space:]]*[A-Za-z_]+[[:space:]]*:[[:space:]]*/, "", $0)
      gsub(/"/, "", $0); gsub(/[ \t\r]/, "", $0); print $0; exit
    }' "$tmp")"
  check_pv="$(awk -v k="CURRENT_PROJECT_VERSION" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
      sub(/^[[:space:]]*[A-Za-z_]+[[:space:]]*:[[:space:]]*/, "", $0)
      gsub(/"/, "", $0); gsub(/[ \t\r]/, "", $0); print $0; exit
    }' "$tmp")"
  if [[ "$check_mv" != "$new_mv" || "$check_pv" != "$new_pv" ]]; then
    rm -f "$tmp"
    die "post-write verification failed (mv=$check_mv, pv=$check_pv); project.yml left unchanged"
  fi

  mv "$tmp" "$project_yml"
  log "wrote $project_yml"

  # Regenerate the Xcode project so the new version lands in the
  # synthesized Info.plist right away.
  log "regenerating project (xcodegen)"
  ( cd "$srcroot" && xcodegen generate )
}

main() {
  case "${1-}" in
    ""|-h|--help)
      print_usage
      ;;
    --print)
      cmd_print
      ;;
    *)
      cmd_bump "$@"
      ;;
  esac
}

main "$@"
