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
    headline: '把 sing-box 装进菜单栏',
    sub: '开源的 macOS 原生代理客户端 · 系统代理与 TUN · 规则分流 · 连接观测',
  },
  {
    file: 'og-en.png',
    lang: 'en',
    headline: 'sing-box, right in your menu bar',
    sub: 'Open-source native macOS proxy client · System proxy & TUN · Rule-based routing',
  },
];

const page = ({ lang, headline, sub }) => `<!doctype html>
<html lang="${lang}"><meta charset="utf-8">
<style>
  * { margin: 0; box-sizing: border-box; }
  body {
    width: 1200px; height: 630px; display: flex; flex-direction: column;
    justify-content: space-between; padding: 72px 76px;
    background: #090b10; color: #e9edf5; position: relative; overflow: hidden;
    font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  body::before {
    content: ''; position: absolute; inset: -40% -20% auto -20%; height: 700px;
    background: radial-gradient(50% 60% at 30% 40%, rgba(34,197,94,.18), transparent 70%);
  }
  .row { display: flex; align-items: center; gap: 16px; position: relative; }
  .mark { width: 52px; height: 52px; border-radius: 14px; background: #12161f;
          display: grid; place-items: center; }
  .word { font-size: 34px; font-weight: 600; letter-spacing: -.02em; }
  .headline { position: relative; font-size: 76px; font-weight: 600; line-height: 1.1;
              letter-spacing: -.035em; max-width: 20ch; }
  .accent { color: #4ade80; }
  .sub { position: relative; margin-top: 26px; font-size: 25px; color: #9aa5b8;
         letter-spacing: -.01em; }
  .meta { position: relative; display: flex; align-items: center; gap: 14px;
          font-size: 21px; color: #78849a; }
  .dot { width: 5px; height: 5px; border-radius: 50%; background: #3a4354; }
  .rule { position: absolute; left: 0; right: 0; bottom: 0; height: 6px;
          background: linear-gradient(90deg, #22c55e, rgba(34,197,94,0)); }
</style>
<div class="row">
  <span class="mark">
    <svg width="30" height="30" viewBox="0 0 32 32" fill="none">
      <path d="M11.4 20.6 20.6 11.4" stroke="#22c55e" stroke-width="2.6" stroke-linecap="round"/>
      <circle cx="10.1" cy="21.9" r="3.4" stroke="#22c55e" stroke-width="2.6"/>
      <circle cx="21.9" cy="10.1" r="3.4" stroke="#22c55e" stroke-width="2.6"/>
    </svg>
  </span>
  <span class="word">linko</span>
</div>
<div>
  <h1 class="headline">${headline}</h1>
  <p class="sub">${sub}</p>
</div>
<div class="meta">
  <span>v${version}</span><span class="dot"></span>
  <span>macOS 14.0+</span><span class="dot"></span>
  <span>GPL-3.0</span><span class="dot"></span>
  <span>github.com/wanggang316/linko</span>
</div>
<div class="rule"></div>
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
