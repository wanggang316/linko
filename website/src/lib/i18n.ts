import {
  GITHUB_URL,
  RELEASES_URL,
  SINGBOX_URL,
  repoFileUrl,
} from './site';

export type Lang = 'zh' | 'en';

export const LANGS: readonly Lang[] = ['zh', 'en'] as const;
export const DEFAULT_LANG: Lang = 'zh';

export const HTML_LANG: Record<Lang, string> = { zh: 'zh-Hans', en: 'en' };

const BASE = import.meta.env.BASE_URL.replace(/\/+$/, '');

export type Route = '' | 'changelog';

/** Base-aware, locale-prefixed path — always with a trailing slash. */
export function localePath(lang: Lang, route: Route = ''): string {
  const segments = [BASE];
  if (lang !== DEFAULT_LANG) segments.push(lang);
  if (route) segments.push(route);
  return `${segments.join('/')}/`;
}

/** Path to an asset in `public/`. */
export const assetPath = (file: string): string => `${BASE}/${file.replace(/^\//, '')}`;

interface Copy {
  home: { title: string; description: string };
  changelogMeta: { title: string; description: string };
  nav: { features: string; install: string; changelog: string };
  manCenter: string;
  name: string;
  description: [string, string];
  features: { term: string; text: string }[];
  install: {
    orDmg: string;
    dmgLink: (version: string) => string;
    requirements: string;
    tun: string;
    byo: string;
    uiLang: string | null;
  };
  automation: { lines: { cmd: string; note: string }[]; outro: string };
  seeAlso: { label: string; href: string; external?: boolean }[];
  license: string;
  changelog: {
    intro: string;
    source: (link: string) => string;
    unreleased: string;
    latest: string;
    untranslated: string | null;
    sections: Record<string, string>;
  };
}

const zh: Copy = {
  home: {
    title: 'linko — 菜单栏里的 macOS 原生代理客户端',
    description:
      '开源的 macOS 原生代理客户端，以 sing-box 为内核：系统代理与 TUN、规则分流、连接观测、订阅与配置文件管理。GPL-3.0，全部可审计。',
  },
  changelogMeta: {
    title: '更新日志 — linko',
    description: 'linko 每个版本的变更记录：新增、变更与修复。',
  },
  nav: { features: '特性', install: '安装', changelog: '更新日志' },
  manCenter: 'macOS 用户命令',
  name: 'linko — 把 sing-box 装进菜单栏的开源 macOS 原生代理客户端',
  description: [
    'SwiftUI 菜单栏常驻应用，以 sing-box 为代理内核。配置怎么生成、内核怎么启动、系统代理怎么改，源码里全都看得到——不捆绑、不推荐、不售卖任何节点或订阅。',
    '更新经 Sparkle 分发，仅安装 EdDSA 签名校验通过的包；内核启动前先跑一遍配置预检，坏配置进不去。',
  ],
  features: [
    { term: 'mode', text: '系统代理与 TUN 全局两种接管模式，同一处切换与启停。' },
    {
      term: 'routing',
      text: '完整规则分流：domain / ip-cidr / process / port / geoip / geosite / logical，策略组可嵌套，支持导入 Surge 与 Clash 规则，REJECT 直接拦截。',
    },
    {
      term: 'nodes',
      text: '订阅 URL、分享链接（ss / vmess / vless / trojan / hysteria2 / tuic）或手动添加节点；多配置文件无损切换。',
    },
    {
      term: 'observe',
      text: '实时连接列表（进程 / 目标 / 命中规则），速率与总量、日志导出、按应用流量统计。',
    },
    {
      term: 'dns',
      text: 'typed-server DNS 与 DNS 分流规则、本地 hosts 映射；按子网或网络接口自动切换配置文件。',
    },
  ],
  install: {
    orDmg: '或下载签名并公证的 DMG：',
    dmgLink: (v) => `Linko-${v}.dmg`,
    requirements: 'macOS 14.0+ · Apple Silicon 与 Intel · GPL-3.0',
    tun: 'TUN 全局模式需在「系统设置 › 通用 › 登录项与扩展」中批准系统扩展。',
    byo: '需自备订阅或节点——linko 不内置任何节点。',
    uiLang: null,
  },
  automation: {
    lines: [
      { cmd: 'linko on | off | toggle', note: '开 / 关 / 反转代理' },
      { cmd: 'linko mode tun | system', note: '切换接管模式' },
      { cmd: 'linko select "<node>"', note: '按显示名选择节点' },
      { cmd: 'linko profile "<name>"', note: '切换配置文件' },
      { cmd: 'linko install <url>', note: '导入订阅（应用内确认）' },
      { cmd: 'linko test', note: '全节点延迟测试' },
      { cmd: 'linko status', note: '内核状态与当前节点' },
    ],
    outro:
      '基于 linko:// URL scheme（仓库内附 scripts/linko 封装），可接入 Raycast、Alfred、快捷指令或任何 shell 脚本。',
  },
  seeAlso: [
    { label: 'GitHub', href: GITHUB_URL, external: true },
    { label: 'Releases', href: RELEASES_URL, external: true },
    { label: 'README', href: repoFileUrl('README.md'), external: true },
    { label: '架构', href: repoFileUrl('docs/ARCHITECTURE.md'), external: true },
    { label: '路线图', href: repoFileUrl('docs/ROADMAP.md'), external: true },
    { label: 'sing-box', href: SINGBOX_URL, external: true },
  ],
  license:
    'GPL-3.0，与内核 sing-box 的许可证兼容。sing-box © SagerNet 及其贡献者。',
  changelog: {
    intro: '每个版本下的条目，同样是应用内更新提示里显示的说明。',
    source: (link) => `内容来自仓库中的 ${link}，随发布流程自动同步。`,
    unreleased: '开发中',
    latest: '[最新]',
    untranslated: '该版本暂无中文说明，以下为英文原文。',
    sections: {
      Added: '新增',
      Changed: '变更',
      Deprecated: '废弃',
      Removed: '移除',
      Fixed: '修复',
      Security: '安全',
    },
  },
};

const en: Copy = {
  home: {
    title: 'linko — a native macOS proxy client in your menu bar',
    description:
      'Open-source native macOS proxy client powered by sing-box: system proxy and TUN, rule-based routing, connection insight, subscriptions and profiles. GPL-3.0, fully auditable.',
  },
  changelogMeta: {
    title: 'Changelog — linko',
    description: 'Every linko release: what was added, what changed and what got fixed.',
  },
  nav: { features: 'features', install: 'install', changelog: 'changelog' },
  manCenter: 'macOS User Commands',
  name: 'linko — an open-source native macOS proxy client that puts sing-box in the menu bar',
  description: [
    'A SwiftUI menu bar app with sing-box as its proxy core. How the config is generated, how the core is launched, how the system proxy is changed — it is all right there in the source. No bundled, recommended or resold nodes or subscriptions.',
    'Updates ship through Sparkle and install only after their EdDSA signature verifies; a config pre-flight check runs before the core starts, so a bad config never launches.',
  ],
  features: [
    { term: 'mode', text: 'System proxy and TUN interception, switched and toggled from one place.' },
    {
      term: 'routing',
      text: 'Full rule-based routing: domain / ip-cidr / process / port / geoip / geosite / logical, nestable policy groups, Surge and Clash rule import, REJECT to block outright.',
    },
    {
      term: 'nodes',
      text: 'Subscription URLs, share links (ss / vmess / vless / trojan / hysteria2 / tuic) or hand-added nodes; lossless switching between profiles.',
    },
    {
      term: 'observe',
      text: 'A live connection list (process / destination / matched rule), rates and totals, exportable logs, per-app traffic stats.',
    },
    {
      term: 'dns',
      text: 'Typed-server DNS with routing rules and a local hosts map; profiles switch automatically by subnet or interface.',
    },
  ],
  install: {
    orDmg: 'Or download the signed, notarized DMG:',
    dmgLink: (v) => `Linko-${v}.dmg`,
    requirements: 'macOS 14.0+ · Apple Silicon & Intel · GPL-3.0',
    tun: 'TUN mode needs its system extension approved in System Settings › General › Login Items & Extensions.',
    byo: 'Bring your own subscription or nodes — linko bundles none.',
    uiLang: 'The app interface currently ships in Chinese only.',
  },
  automation: {
    lines: [
      { cmd: 'linko on | off | toggle', note: 'turn the proxy on / off / flip it' },
      { cmd: 'linko mode tun | system', note: 'switch the interception mode' },
      { cmd: 'linko select "<node>"', note: 'select a node by display name' },
      { cmd: 'linko profile "<name>"', note: 'switch the active profile' },
      { cmd: 'linko install <url>', note: 'import a subscription (confirms in-app)' },
      { cmd: 'linko test', note: 'run a delay test across nodes' },
      { cmd: 'linko status', note: 'core state and current node' },
    ],
    outro:
      'Built on the linko:// URL scheme (a scripts/linko wrapper ships in the repo) — wire it into Raycast, Alfred, Shortcuts or any shell script.',
  },
  seeAlso: [
    { label: 'GitHub', href: GITHUB_URL, external: true },
    { label: 'Releases', href: RELEASES_URL, external: true },
    { label: 'README', href: repoFileUrl('README.md'), external: true },
    { label: 'Architecture', href: repoFileUrl('docs/ARCHITECTURE.md'), external: true },
    { label: 'Roadmap', href: repoFileUrl('docs/ROADMAP.md'), external: true },
    { label: 'sing-box', href: SINGBOX_URL, external: true },
  ],
  license:
    'GPL-3.0, compatible with the license of sing-box, the proxy core it uses. sing-box is © SagerNet and its contributors.',
  changelog: {
    intro: "Each release's entries double as the notes shown in the app's update dialog.",
    source: (link) => `Sourced from ${link} in the repository, kept in sync by the release pipeline.`,
    unreleased: 'Unreleased',
    latest: '[latest]',
    untranslated: null,
    sections: {
      Added: 'Added',
      Changed: 'Changed',
      Deprecated: 'Deprecated',
      Removed: 'Removed',
      Fixed: 'Fixed',
      Security: 'Security',
    },
  },
};

const COPY: Record<Lang, Copy> = { zh, en };

export const t = (lang: Lang): Copy => COPY[lang];
