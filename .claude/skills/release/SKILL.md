---
name: release
description: Cut a Linko release through a pull request. Write the release notes into CHANGELOG (and its Chinese site overlay), pick the Semantic Versioning bump from them, bump the version in project.yml, open a release PR, and after it merges tag the merged commit vX.Y.Z to trigger the GitHub Actions Developer-ID release pipeline, and publish the release once it passes. Use when shipping a new build to Sparkle and Homebrew clients.
---

# release: Cut a Linko release

A release is **a release PR, then a tag push**. The PR lands the version bump
and the release notes on `main`. The tag `vX.Y.Z` on the merged commit fires
`.github/workflows/release.yml`: it builds Libbox, archives, signs,
notarizes, writes a Sparkle `appcast.xml` with the release notes, and opens a
**draft** GitHub Release, which this skill publishes once the run passes. The
contract CI enforces:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` in `project.yml` ⇔
> `CHANGELOG.md` has `## [X.Y.Z] - YYYY-MM-DD`.

CI copies that CHANGELOG section verbatim into the GitHub Release body and
into Sparkle's update dialog. It is published prose, not a work record.

Sparkle clients update from
`https://github.com/wanggang316/linko/releases/latest/download/appcast.xml`,
which resolves to the newest **published, non-prerelease** release.
Publishing also triggers `update-cask.yml` (Homebrew tap). The site
(`pages.yml`) redeploys when the release PR merges, not on publish.

The release is built **only in CI**. Never run `make release` and
`gh release create` locally for a tagged version: CI also builds the tag, and
the result is two releases for one tag.

Don't use this for fixing the release pipeline itself (no version bump).
Never push to `main` directly; every release change goes through a PR.

## Process

The release PR is the single gate. Run steps 1–6 without stopping: they write
only to a release branch and an open PR, which is the review surface. After
the user approves the merge in step 7, run steps 7–9 without stopping, up to
the published release.

### 1. Pre-flight

```bash
git status --porcelain                  # empty
git fetch origin --tags
./scripts/bump-version.sh --print       # current version, next build, next patch / minor / major
gh pr list --search 'head:release/'     # no open release PR
gh release list --limit 3               # no leftover draft for the target tag
```

Stop if the tree is dirty, a release PR is already open, the target tag
already exists, or a release (draft or published) already exists for it.

### 2. Write the release notes

`[Unreleased]` is **input, not output**: it collects one bullet per PR, so a
single feature arrives with several bullets from different stages. Never
promote it as-is. Always cross-check it against
`git log --no-merges --pretty='%h %s' "$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)..origin/main"`
and keep only what a user can perceive.

**Consolidate.**
- One entry per user-visible surface (a feature area, the menu bar, a
  dashboard page, a Settings pane) per category, however many bullets it had.
- Describe the end state. Superseded work is dropped, not merged.
- Fold small polish on one area into a single bullet.
- A release reads as **1–8 entries**.

**Keep each entry to three lines** (~240 characters, as the file wraps): a
bold lead-in a skimming user can stop at, then at most two sentences. A
one-line fix needs no lead-in.

```markdown
- **Quick rule from the browser.** A menu bar action reads the page in the
  front browser, suggests domain patterns, and saves a routing rule without
  opening the dashboard.
```

**Write for users.**
- Lead with what the user gets or the symptom that's gone, not the mechanism.
- Leave out engineering-only work (refactors, CI, lint, dependency bumps).
  Exceptions that are always listed: user-perceivable side effects
  (minimum-OS bump, a new sing-box core) and anything deprecated, removed,
  or breaking.
- No commit prefixes, PR / issue numbers, hashes, type or module names, or
  protocol jargon. Name the UI surface the user sees.

Categories follow Keep a Changelog 1.1.0: `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, `Security`.

### 3. Choose the version

Versions follow Semantic Versioning 2.0.0. Derive the bump from the notes of
step 2 — they are the user-visible change set — not from commit prefixes:

| The release contains | Bump |
|---|---|
| A breaking change: anything under `Removed`, or a `Changed` entry that breaks a config, subscription, or rule format the user relies on | **major** — but **minor** while the version is `0.y.z` |
| Anything under `Added`, `Changed`, or `Deprecated` | **minor** |
| Only `Fixed` and `Security` | **patch** |

The highest row wins. Take the number from `bump-version.sh --print`. Never
bump to `1.0.0` on your own; going to 1.0 is the user's call.

This step is not a gate: state the version and the row that chose it, and go
on. The user corrects it in the PR if needed.

### 4. Branch, edit the notes, bump

```bash
git switch --no-track -c release/vX.Y.Z origin/main
```

`--no-track` matters: a branch started from `origin/main` otherwise tracks
`main`, and a bare `git push` would push to `main`.

1. In `CHANGELOG.md`, put the notes of step 2 under
   `## [X.Y.Z] - YYYY-MM-DD` (today from `date +%F`, never from memory), drop
   its empty categories, and reseed an empty `## [Unreleased]` above it with
   all six headers.
2. In `apps/website/src/data/changelog.zh.json`, add an `"X.Y.Z"` entry at
   the top with the same sections (English section titles) and the entries
   translated to Chinese. Keep the bold lead-ins.
3. Bump the version:

   ```bash
   make bump-version VERSION=X.Y.Z   # BUILD=N overrides the build number (rare)
   ```

   The script owns the version in `project.yml`: it validates the version,
   takes the next `YYYYMMDDNNN` build from the published appcast, writes
   atomically, and runs `xcodegen generate`. Never hand-edit the version.

Skip a local build; the PR check and the release pipeline build it.

### 5. Commit and push

Stage only the release files, in one commit, with no trailers:

```bash
git add CHANGELOG.md project.yml apps/website/src/data/changelog.zh.json
git commit -m "chore(release): bump to X.Y.Z"
git push -u origin release/vX.Y.Z
```

### 6. Open the release PR

```bash
gh pr create --base main --head release/vX.Y.Z \
  --title "chore(release): bump to X.Y.Z" --body-file - <<'EOF'
Release X.Y.Z (build N): <bump> because <row of step 3>.

<the new CHANGELOG section, verbatim>

Merging this PR does not release. After merge, tag the merged commit
`vX.Y.Z` to start the release pipeline.
EOF
```

Not a draft. No agent names in the title or body. Then wait for the checks:
`gh pr checks <PR> --watch` (`pr-build` runs because `project.yml` changed).

### 7. Merge — the only gate

Report the PR URL, the version, and the check result, and wait for the user
to approve the merge. Edits the user asks for go onto the release branch as
new commits. If `main` gained user-visible changes since step 2, update the
notes (and, if the bump row changed, the version) before the merge.

```bash
gh pr merge <PR> --rebase
git push origin --delete release/vX.Y.Z
```

Rebase keeps the bump commit as is on `main`. Don't pass `--delete-branch`:
it fails when `main` is checked out in another worktree.

### 8. Tag the merged commit and push the tag

The user's merge approval covers this step and step 9.

```bash
SHA=$(gh pr view <PR> --json mergeCommit --jq .mergeCommit.oid)
git fetch origin
git merge-base --is-ancestor "$SHA" origin/main                   # on main
git show "$SHA:project.yml" | grep -E '^[[:space:]]*MARKETING_VERSION: "X\.Y\.Z"$'
git tag -a vX.Y.Z -m "vX.Y.Z" "$SHA"
git push origin vX.Y.Z                                            # triggers release.yml
```

Always an annotated tag on the merged commit — never on the local branch
commit, which the rebase replaced.

### 9. Wait for CI, then publish the release

```bash
RUN=$(gh run list --workflow=release.yml --event push --branch vX.Y.Z \
  --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN" --exit-status
gh release view vX.Y.Z --json isDraft,assets --jq '{isDraft, assets: [.assets[].name]}'
gh release edit vX.Y.Z --draft=false --latest
```

Publish only when the run passed and the draft has all three assets:
`Linko-X.Y.Z.dmg`, `Linko-X.Y.Z.dmg.sha256`, and `appcast.xml`. Otherwise
leave the draft and go to Recovery. Keep the draft only when the user asked
for it. Never mark it a prerelease: the canonical feed skips prereleases.

Publish from this session, not from CI: a release that the workflow's
`GITHUB_TOKEN` publishes does not trigger `update-cask.yml`.

Then verify and report the release URL:

```bash
gh run list --workflow=update-cask.yml --limit 1     # cask run started
curl -fsSL https://github.com/wanggang316/linko/releases/latest/download/appcast.xml \
  | grep -E 'shortVersionString|enclosure url|<description'
```

The feed's top item must be `X.Y.Z`, point at the new DMG, and carry a
`<description>` with the release notes.

## Recovery

Roll forward; never force-push `main` or rewrite its history. Fixes to `main`
go through a PR. Deleting a pushed tag or a release needs explicit user
approval.

| Symptom | Fix |
|---|---|
| CI: tag ≠ `MARKETING_VERSION` | The tag points at the wrong commit: with approval, delete it (`git tag -d vX.Y.Z; git push origin :refs/tags/vX.Y.Z`) and tag the merged bump commit. |
| CI: no CHANGELOG section | Add it in a `docs(changelog): record X.Y.Z` PR, then with approval delete the tag and tag the new merge commit. |
| CI: a release already exists for the tag | A leftover draft: with approval, `gh release delete vX.Y.Z` (keeps the tag), then re-run via `workflow_dispatch` on the tag. |
| Release PR closed without merge | Delete the branch; nothing was released. |
| Libbox build, notarization, or other transient CI failure | `gh run view --log-failed`, fix the cause, delete any draft, and re-run via `workflow_dispatch` on the existing tag. |
| Run passed but an asset is missing | Leave the draft; delete it, then re-run via `workflow_dispatch` on the tag. |
| Feed did not update after publish | The release is a prerelease or still a draft, or lacks `appcast.xml`. Fix the release flags; never upload a hand-made appcast. |
| Wrong version shipped | Supersede it with the next version. |
| Published release is broken | Mark its header `## [X.Y.Z] - YYYY-MM-DD [YANKED]` with a one-line reason; ship the fix as a new version. |

`appcast.xml` is written only by CI — never edit it by hand. The CI secrets
(Developer ID certificate, provisioning profiles, notary API key, Sparkle
key, tap token) are listed in `docs/RELEASE.md`.
