#!/usr/bin/env bash
#
# render-cask.sh <version> <sha256> [output]
#
# Substitute the version + sha256 into the Casks/linko.rb template (the
# in-repo source of truth) and write the result to <output> (defaults to the
# template itself). update-cask.yml renders into a clone of the Homebrew tap.
#
set -euo pipefail

version="${1:?usage: render-cask.sh <version> <sha256> [output]}"
sha="${2:?usage: render-cask.sh <version> <sha256> [output]}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
template="${srcroot}/Casks/linko.rb"
output="${3:-${template}}"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: bad version '${version}'" >&2; exit 1; }
[[ "${sha}" =~ ^[a-f0-9]{64}$ ]] || { echo "error: bad sha256 '${sha}'" >&2; exit 1; }
[ -f "${template}" ] || { echo "error: ${template} not found" >&2; exit 1; }

/usr/bin/env python3 - "${template}" "${output}" "${version}" "${sha}" <<'PY'
import re, sys
tmpl, out, version, sha = sys.argv[1:5]
s = open(tmpl, encoding="utf-8").read()
s, n1 = re.subn(r'version "[^"]*"', 'version "%s"' % version, s, count=1)
s, n2 = re.subn(r'sha256 "[^"]*"', 'sha256 "%s"' % sha, s, count=1)
assert n1 == 1, "no version line in cask template"
assert n2 == 1, "no sha256 line in cask template"
open(out, "w", encoding="utf-8").write(s)
print("rendered %s -> version %s sha256 %s" % (out, version, sha))
PY
