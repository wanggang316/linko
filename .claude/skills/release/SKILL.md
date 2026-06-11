---
name: release
description: Cut a Linko release. Bump the shared version in project.yml, promote CHANGELOG [Unreleased] to a dated section, commit atomically, build+sign+notarize+package locally via `make release`, tag vX.Y.Z, and publish the signed DMG + appcast.xml to GitHub Releases. Use when shipping a new build to Sparkle clients.
---

# release: Cut a Linko release

## Overview

A Linko release is produced **locally** by the Developer ID pipeline
(`scripts/release.sh`, run via `make release`): it archives, signs with
Developer ID, notarizes, builds a signed DMG, and generates a
Sparkle-signed `appcast.xml`. You then publish those artifacts to a GitHub
Release. Sparkle clients update from the **canonical feed**

> `https://github.com/wanggang316/linko/releases/latest/download/appcast.xml`

which GitHub serves from the most recent **non-prerelease** Release. So the
release contract is:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` in `project.yml` ⇔
> `CHANGELOG.md` has a `## [X.Y.Z] - YYYY-MM-DD` section ⇔ a GitHub Release
> `vX.Y.Z` (not prerelease) carrying `Linko-X.Y.Z.dmg`, its `.sha256`, and
> `appcast.xml`.

This skill walks those artifacts into alignment, builds and signs locally,
tags, pushes, publishes, and verifies the feed is live.

> Forward note: CI automation (`.github/workflows/release.yml`) is planned
> but not yet in place (see `docs/RELEASE.md` §5). Until it lands, releases
> are cut locally with this skill. When CI exists, step 6 (local build) is
> replaced by a tag push that triggers the pipeline; the rest is unchanged.

## When to use

- Ready to ship a new build to GitHub Releases / Sparkle clients.
- `[Unreleased]` in `CHANGELOG.md` has user-visible entries worth a release.

**Don't use** for:
- Fixing the release scripts themselves (no version bump).
- Local-only experiments — never tag without intent to publish.

## One-time prerequisites (verify, don't assume)

These must be set up on the machine before a release can succeed. The skill
checks them in pre-flight and bails with the fix command if any is missing.

| Prerequisite | Check | Fix |
|---|---|---|
| Developer ID Application cert | `security find-identity -v -p codesigning \| grep "Developer ID Application"` | Import the `.p12` into the login keychain |
| Provisioning profiles | `Linko DeveloperID` (app) + `LinkoTunnel DeveloperID` (extension) installed | Download from developer.apple.com; Xcode installs them under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` |
| Notary credentials | `xcrun notarytool history --keychain-profile linko-notary` succeeds | `xcrun notarytool store-credentials linko-notary --apple-id <id> --team-id HC438T2B8P` |
| Vendored core | `vendor/sing-box/sing-box` + `vendor/libbox/Libbox.xcframework` exist | `make fetch-core && ./scripts/build-libbox.sh` (needs Go) |
| Sparkle EdDSA key | private key in login keychain (public key already in `project.yml`) | `generate_keys -f <backup>` to restore |

## Project facts (load before acting)

| Concern | Where it lives |
|---|---|
| Marketing version + build number | `project.yml` → top-level `settings.base` → `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (YYYYMMDDNNN). Shared by the app and the embedded system extension. |
| Bump tool | `scripts/bump-version.sh` (via `make bump-version VERSION=X.Y.Z`) — rewrites project.yml atomically and runs `xcodegen generate` |
| User-visible changelog | `CHANGELOG.md` (repo root) — entries written in **English** |
| Release pipeline | `scripts/release.sh` via `make release` (archive → notarize → DMG → notarize → appcast) |
| Tag format | `vX.Y.Z`, annotated |
| Distribution unit | DMG (notarized + stapled). Sparkle clients update from it. |
| Canonical feed | `releases/latest/download/appcast.xml` (newest non-prerelease release) |
| Bump commit style | `chore(release): bump to X.Y.Z` (project.yml + CHANGELOG.md only). **No attribution trailer** (Linko convention). |

`MARKETING_VERSION` is **not** strict SemVer pre-1.0 — every release is a
developer build (per the `CHANGELOG.md` preamble). Default cadence is patch;
bump minor when behavior is materially different.

## Process

### 0. Pre-flight — refuse to proceed if any check fails

Run via `Bash` (parallelizable):

```bash
git rev-parse --abbrev-ref HEAD                 # expect 'main' (else confirm with user)
git status --porcelain                          # expect empty
git fetch origin --tags                         # refresh
git tag --sort=-creatordate | head -3           # recent tags
./scripts/bump-version.sh --print               # current version + suggested next
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "MISSING cert"
test -f vendor/sing-box/sing-box && test -d vendor/libbox/Libbox.xcframework && echo "vendor OK" || echo "MISSING vendor — run: make fetch-core && ./scripts/build-libbox.sh"
xcrun notarytool history --keychain-profile linko-notary >/dev/null 2>&1 && echo "notary OK" || echo "MISSING notary profile linko-notary"
# both Developer ID profiles must be installed (archive signs the app + extension):
for n in "Linko DeveloperID" "LinkoTunnel DeveloperID"; do
  find ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles -name '*.provisionprofile' 2>/dev/null \
    -exec sh -c 'security cms -D -i "$1" 2>/dev/null | plutil -extract Name raw - 2>/dev/null' _ {} \; \
    | grep -qxF "$n" && echo "profile OK: $n" || echo "MISSING profile: $n"
done
```

Bail with a clear message if any of these are wrong:
- Not on `main` and the user hasn't approved an off-`main` release.
- Working tree dirty.
- A tag for the proposed version already exists.
- Any prerequisite (cert / profiles / notary / vendor) missing — print the
  fix from the table above; profiles and notary credentials require the
  user (they involve Apple credentials and can't be set up unattended).

### 1. Decide the version — ask the user

1. Read current `MARKETING_VERSION` and the `## [Unreleased]` section of `CHANGELOG.md`.
2. Propose **patch** by default (`0.1.0 → 0.1.1`).
3. Show a summary table:

   ```
   Current: 0.1.0 (build 20260611001)
   Next:    0.1.1 (build 20260612001)  <-- patch (default; build from appcast +1 / new day)
   Or:      0.2.0 (build 20260612001)  <-- minor (user-visible scope changed)

   Unreleased highlights:
     Added — ...
     Fixed — ...
   ```

4. Wait for explicit confirmation of `X.Y.Z` before proceeding.
   **Never invent a version silently.**

### 2. Verify the changelog has shippable content

If `[Unreleased]` is empty (only category headers, no entries), **stop** and
ask the user to record what shipped, then resume.

**Writing style — user-facing, in English.** The CHANGELOG follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) — entries are
*for humans*. Rewrite raw commit messages; never paste them. Each entry
doubles as the text shown in Sparkle's update dialog.

Six standard categories: `Added` (new features) / `Changed` (changes to
existing behavior) / `Deprecated` (going away, still works) / `Removed` (gone
this version) / `Fixed` (bug fixes) / `Security` (vulnerability fixes).

Bullet rules, in priority order (earlier wins on conflict):

1. **Describe what the user gets.** Lead with the feature/outcome, or — for
   bugs — the symptom that's now gone. Skip the mechanism.
2. **Clarity beats brevity.** One or two short lines per entry; three means
   it's doing too much.
3. **Skip engineering-only changes.** Refactors, renames, CI tweaks, dep
   bumps — out (git log is their home). Two exceptions always make the cut:
   user-perceivable side effects (min-OS bump, faster startup → `Changed`,
   describe the impact) and deprecations/removals/breaking changes.
4. **Drop developer jargon.** No commit prefixes, PR/issue numbers, hashes,
   module or type names, protocol terms. Refer to features by the UI surface
   the user sees ("Settings → About", "the menu bar").
5. **Consolidate within a release.** Fold commits that chased the same
   bug/feature into one entry naming the end state; bundle tiny polish into
   one bullet.

Sanity check each entry: *would a user who only uses the app care, and could
they understand it?* If either is "no", rewrite or drop.

### 3. Cut the changelog version section

Edit `CHANGELOG.md`:

1. Replace `## [Unreleased]` with **two** sections:
   - A fresh empty `## [Unreleased]` at top with all six headers, left empty.
   - The previous `[Unreleased]` body promoted under
     `## [X.Y.Z] - YYYY-MM-DD` (today's date, user's local TZ — get it from
     `date +%F`, never from memory).
2. If a placeholder `## [X.Y.Z] - 未发布` already exists for this version
   (the first release seeded one), fill in the real date and drop any
   "未发布" marker.
3. Show the diff to the user before writing.

### 4. Bump the version files

```bash
make bump-version VERSION=X.Y.Z
# explicit build override (rarely needed):
make bump-version VERSION=X.Y.Z BUILD=YYYYMMDDNNN
```

`scripts/bump-version.sh` validates semver, refuses a non-increasing
version, computes the next `YYYYMMDDNNN` build from the published appcast,
rewrites `project.yml` atomically (tmpfile + post-write verification), and
runs `xcodegen generate`. **Do not hand-edit** the version in `project.yml`
— the script is the rule.

> Note: this regenerates `Linko.xcodeproj` (gitignored), so the working tree
> stays clean except for `project.yml`.

### 5. Commit — only the two bumped files (atomic)

```bash
git add project.yml CHANGELOG.md
git status            # confirm ONLY those two are staged
git diff --cached     # final eyeball
git commit -m "chore(release): bump to X.Y.Z"
```

Pre-1.0 the version bump and changelog stay in **one** commit. **No
Co-Authored-By / attribution trailer** (Linko convention). Show the staged
diff to the user before committing.

### 6. Build, sign, notarize, package locally

```bash
make release
```

This runs the full pipeline (~10–20 min including the notary wait):
archive → notarize app → signed DMG → notarize DMG → signed appcast. It
emits into `.build/release/`:
- `Linko-X.Y.Z.dmg` (+ `.sha256`)
- `appcast.xml`

If it fails, **stop and diagnose** before tagging — nothing is published
yet, so a failure here is cheap. Common failures: `build-libbox.sh` (Go /
gomobile environment), archive (provisioning profile not installed or
expired), notarization (`xcrun notarytool log <id>` for the reason). See
Failure modes below.

> Building **before** tagging (unlike a CI flow that builds after the tag
> push) is deliberate: a local cut can prove the artifacts are good before
> committing a tag to history.

### 7. Tag — annotated, with release highlights

```bash
git tag -a vX.Y.Z -m "$(cat <<'EOF'
vX.Y.Z

<one short paragraph in user-facing English summarizing the release —
what's new / improved / fixed, pulled from the CHANGELOG, no mechanism>
EOF
)"
git show vX.Y.Z --stat       # let the user eyeball it
```

Always annotated, never lightweight. The annotation message surfaces on the
GitHub Release page.

### 8. Push — commit first, tag second

```bash
git push origin main
git push origin vX.Y.Z
```

### 9. Publish the GitHub Release

```bash
gh release create vX.Y.Z \
  --title vX.Y.Z \
  --notes-file <(sed -n '/^## \[X.Y.Z\]/,/^## \[/p' CHANGELOG.md | sed '$d') \
  .build/release/Linko-X.Y.Z.dmg \
  .build/release/Linko-X.Y.Z.dmg.sha256 \
  .build/release/appcast.xml
```

**Must NOT be a prerelease** — the canonical feed
(`releases/latest/download/appcast.xml`) only resolves to non-prerelease
releases, so a prerelease would not reach clients. Default to publishing
directly; pass `--draft` only if the user wants to eyeball the release page
before it goes live (then `gh release edit vX.Y.Z --draft=false` to ship).

### 10. Verify the feed is live

```bash
gh release view vX.Y.Z
curl -fsSL https://github.com/wanggang316/linko/releases/latest/download/appcast.xml \
  | grep -E "sparkle:version|shortVersionString|enclosure url" | head
```

Confirm the appcast resolves and its top item is the new version with an
`enclosure url` pointing at the just-uploaded DMG. Tell the user the
release is live and clients will see it on their next Sparkle check.

## Failure modes & recovery

| Symptom | Cause | Fix |
|---|---|---|
| `build-libbox.sh` fails | Go/gomobile env, or sing-box tag drift | Ensure Go is installed; re-run; check `SING_BOX_VERSION` |
| Archive: "no profile matching ..." | `Linko DeveloperID` / `LinkoTunnel DeveloperID` profile not installed or expired | Re-download from developer.apple.com into `~/Library/MobileDevice/Provisioning Profiles/` |
| Archive produced ad-hoc signature | Developer ID cert not in keychain | `security find-identity -v -p codesigning`; import the `.p12` |
| Notarization fails | Apple-side flag, or stale embedded helper signed ad-hoc | `xcrun notarytool log <id>`; often the nested re-sign — verify `resign-nested.sh` covered the offending binary |
| Wrong version tagged | Bumped to the wrong number | Roll forward only — supersede with a new tag. **Never** rewrite `main` history. |
| Published release broken/unsafe | Bug or signing issue surfaces post-publish | Mark YANKED, don't delete: edit `CHANGELOG.md` header to `## [X.Y.Z] - YYYY-MM-DD [YANKED]` with a reason, commit on `main`, cut a follow-up fix version. The loud `[YANKED]` is intentional. |
| Feed didn't update after publish | Release marked prerelease, or `appcast.xml` not attached | Un-prerelease the release; ensure `appcast.xml` is among its assets (re-run `release.sh appcast` + `gh release upload --clobber`) |

## Verification checklist

Before reporting "done":

- [ ] `git tag --sort=-creatordate | head -1` shows the new tag.
- [ ] `git log -1 --oneline origin/main` shows `chore(release): bump to X.Y.Z`.
- [ ] `./scripts/bump-version.sh --print` shows `MARKETING_VERSION = X.Y.Z`.
- [ ] `CHANGELOG.md` has `## [X.Y.Z] - YYYY-MM-DD` (non-empty) and a fresh empty `## [Unreleased]` above.
- [ ] The GitHub Release `vX.Y.Z` is **not** prerelease and carries the DMG, its `.sha256`, and `appcast.xml`.
- [ ] `curl …/releases/latest/download/appcast.xml` returns the new version.

## Anti-patterns

- ❌ Bumping `project.yml` and `CHANGELOG.md` in separate commits — keep the bump atomic.
- ❌ `git add -A` / `git add -u` — stage only the release files.
- ❌ Any attribution / Co-Authored-By trailer on the bump commit.
- ❌ Lightweight tag — always annotated.
- ❌ Pushing the tag before the commit.
- ❌ Publishing as a **prerelease** — clients on the canonical feed won't see it.
- ❌ Force-pushing `main` to "fix" a bad bump — roll forward instead.
- ❌ Hand-editing `appcast.xml` — `generate_appcast` (via `release.sh appcast`) is the only writer.
- ❌ Tagging before `make release` succeeds — prove the artifacts first.
