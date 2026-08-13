// Renders the social preview cards into `public/`.
//
// Run locally (`npm run og`) whenever the wording or the version on the card
// changes; the PNGs are committed. Deliberately not part of `npm run build`:
// CI has neither Chrome nor the CJK system fonts this uses, so generating
// there would silently produce a card with missing glyphs.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const version =
  readFileSync(resolve(root, '..', 'project.yml'), 'utf8').match(
    /^[ \t]*MARKETING_VERSION:[ \t]*"?([0-9][^"\s]*)"?/m,
  )?.[1] ?? '0.0.0';

const chrome =
  process.env.CHROME_BIN ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const cards = [
  {
    file: 'og.png',
    lang: 'zh-Hans',
    headline: '菜单栏里的代理客户端',
    sub: '粘贴订阅，选好节点，一键开启。智能分流、流量观测、自动切换。',
  },
  {
    file: 'og-en.png',
    lang: 'en',
    headline: 'A proxy client in your menu bar',
    sub: 'Paste a subscription, pick a node, switch it on. Smart routing and a live traffic view.',
  },
];

const page = ({ lang, headline, sub }) => `<!doctype html>
<html lang="${lang}"><meta charset="utf-8">
<style>
  * { margin: 0; box-sizing: border-box; }
  body {
    width: 1200px; height: 630px; display: flex; flex-direction: column;
    justify-content: center; align-items: center; text-align: center;
    gap: 26px; padding: 60px;
    background: #ffffff; color: #1d1d1f;
    font-family: -apple-system, "SF Pro Display", "PingFang SC",
      "Helvetica Neue", sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .brand { font-size: 30px; font-weight: 700; }
  h1 { font-size: 72px; font-weight: 650; line-height: 1.15;
       letter-spacing: -.02em; max-width: 16em; }
  .sub { font-size: 30px; color: #6e6e73; max-width: 30em; line-height: 1.5; }
  .meta { position: absolute; bottom: 44px; font-size: 22px; color: #a1a1a6; }
</style>
<div class="brand">linko</div>
<h1>${headline}</h1>
<p class="sub">${sub}</p>
<div class="meta">v${version} · macOS 14+ · ${lang === 'en' ? 'free & open source' : '免费开源'} · github.com/wanggang316/linko</div>
`;

const work = mkdtempSync(join(tmpdir(), 'linko-og-'));

for (const card of cards) {
  const html = join(work, `${card.file}.html`);
  const out = resolve(root, 'public', card.file);
  writeFileSync(html, page(card));
  execFileSync(
    chrome,
    [
      '--headless=new',
      '--disable-gpu',
      '--hide-scrollbars',
      '--force-device-scale-factor=1',
      '--window-size=1200,630',
      `--screenshot=${out}`,
      '--virtual-time-budget=3000',
      `file://${html}`,
    ],
    { stdio: 'ignore' },
  );
  console.log(`wrote public/${card.file}`);
}
