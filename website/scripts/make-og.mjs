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
    headline: 'linko — 把 sing-box 装进菜单栏',
    sub: '开源的 macOS 原生代理客户端 · 系统代理与 TUN · 规则分流 · 连接观测',
  },
  {
    file: 'og-en.png',
    lang: 'en',
    headline: 'linko — sing-box in your menu bar',
    sub: 'Open-source native macOS proxy client · System proxy & TUN · Rule-based routing',
  },
];

const page = ({ lang, headline, sub }) => `<!doctype html>
<html lang="${lang}"><meta charset="utf-8">
<style>
  * { margin: 0; box-sizing: border-box; }
  body {
    width: 1200px; height: 630px; display: flex; flex-direction: column;
    justify-content: space-between; padding: 64px 72px;
    background: #fcfcfa; color: #1c1c1c;
    font-family: "SF Mono", Menlo, Consolas, monospace;
    -webkit-font-smoothing: antialiased;
  }
  .manline { display: flex; justify-content: space-between; font-size: 24px;
             color: #6e6e6a; }
  .manline b { color: #1c1c1c; }
  .label { font-size: 26px; font-weight: 700; letter-spacing: .08em; }
  .headline { margin-top: 14px; padding-left: 56px; font-size: 44px;
              font-weight: 700; line-height: 1.35; max-width: 24ch; }
  .sub { margin-top: 22px; padding-left: 56px; font-size: 25px; color: #6e6e6a;
         line-height: 1.6; }
  .meta { font-size: 22px; color: #6e6e6a; border-top: 2px solid #dcdcd6;
          padding-top: 28px; }
</style>
<div class="manline"><b>LINKO(1)</b><span>${lang === 'en' ? 'macOS User Commands' : 'macOS 用户命令'}</span><b>LINKO(1)</b></div>
<div>
  <div class="label">NAME</div>
  <h1 class="headline">${headline}</h1>
  <p class="sub">${sub}</p>
</div>
<div class="meta">v${version} · macOS 14.0+ · GPL-3.0 · github.com/wanggang316/linko</div>
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
