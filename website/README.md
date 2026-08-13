# linko website

Marketing site for linko: a landing page and a changelog page, in Chinese and
English. Built with [Astro](https://astro.build) and deployed to GitHub Pages by
`.github/workflows/pages.yml`.

```sh
npm install
npm run dev      # http://localhost:4321/linko/
npm run check    # astro check (types)
npm run build    # -> dist/
npm run preview  # serve dist/
```

From the repository root the same steps are available as `make site-dev`,
`make site` and `make site-preview`.

## The repository is the source of truth

Nothing about the product is duplicated into this directory:

| Fact | Read from | Where it shows |
|---|---|---|
| Shipping version | `../project.yml` (`MARKETING_VERSION`) | hero, download card, footer |
| Release notes | `../CHANGELOG.md` | the whole changelog page |

Both are read at build time by `src/lib/repo.ts`. A release commit that bumps
the version and promotes `[Unreleased]` therefore republishes the site with no
edits here — which is why the Pages workflow also watches those two files.

## Bilingual copy

Chinese is the default locale and lives at `/`; English lives at `/en/`. All
page copy is in `src/lib/i18n.ts` as two mirrored objects — the `Copy` interface
is what keeps them from drifting apart.

Changelog entries are the exception. They come from `CHANGELOG.md`, which is
English, so `src/data/changelog.zh.json` carries a hand-written Chinese overlay
keyed by version. A version missing from that file falls back to the English
text (and the page says so), so a release never blocks on a translation.
After adding a release to `CHANGELOG.md`, add its Chinese entries there too.

## Structure

```
src/lib/          repo.ts (root files), site.ts (links, version),
                  changelog.ts (Keep-a-Changelog parser), i18n.ts (all copy)
src/data/         changelog.zh.json — Chinese overlay for release notes
src/components/   HomePage / ChangelogPage + shared chrome
src/layouts/      Base.astro — head, theme boot, header, footer, page scripts
src/styles/       global.css — design tokens for both themes
scripts/          make-og.mjs — regenerates the social cards (see below)
```

## Deployment

The default build targets the project page
`https://wanggang316.github.io/linko/`. To move to a custom domain, override
both variables and add a `CNAME` file to `public/`:

```sh
SITE_URL=https://example.com SITE_BASE=/ npm run build
```

## Social preview images

`public/og.png` and `public/og-en.png` are committed, and regenerated locally
with `npm run og` (needs Chrome and macOS system fonts — hence not part of CI).
Re-run it when the card wording or the version on it should change.
