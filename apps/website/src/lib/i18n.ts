import { GITHUB_URL, RELEASES_URL, SINGBOX_URL, repoFileUrl } from './site';

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

interface Feature {
  title: string;
  body: string;
}

interface Copy {
  home: { title: string; description: string };
  changelogMeta: { title: string; description: string };
  nav: { features: string; download: string; changelog: string };
  hero: {
    title: string;
    lede: string;
    download: string;
    github: string;
    fine: (version: string) => string;
    shotTitle: string;
  };
  features: Feature[];
  download: {
    title: string;
    lede: string;
    cta: string;
    allReleases: string;
    brewLabel: string;
  };
  footer: { line: string; docs: string };
  changelog: {
    title: string;
    lede: string;
    unreleased: string;
    latest: string;
    untranslated: string | null;
    sections: Record<string, string>;
  };
}

const zh: Copy = {
  home: {
    title: 'linko — 简单、稳定的全功能 macOS 代理客户端',
    description:
      '简单、稳定的全功能 macOS 代理客户端：订阅导入、规则分流、流量观测、按网络自动切换配置。免费开源。',
  },
  changelogMeta: {
    title: '更新日志 — linko',
    description: 'linko 每个版本更新了什么：新增功能、体验改进与问题修复。',
  },
  nav: { features: '功能', download: '下载', changelog: '更新日志' },
  hero: {
    title: '简单、稳定的\n全功能代理客户端',
    lede: '订阅导入、规则分流、流量观测、按网络自动切换，macOS 原生应用。',
    download: '免费下载',
    github: '查看源代码',
    fine: (v) => `v${v} · macOS 14 及以上 · Apple 芯片与 Intel · 免费开源`,
    shotTitle: 'linko 菜单栏面板',
  },
  features: [
    {
      title: '两种接管模式',
      body: '系统代理接管浏览器等常规应用；TUN 全局接管整机流量，包括命令行。一处切换，重启后恢复上次状态。',
    },
    {
      title: '规则分流',
      body: '按域名、IP、进程、端口匹配，走代理、直连或拦截。改动立即生效，支持导入 Surge 与 Clash 规则。',
    },
    {
      title: '订阅导入',
      body: '粘贴订阅链接或节点分享链接，自动识别格式；也可以手动添加节点。多套配置文件独立保存、随时切换。',
    },
    {
      title: '流量与连接',
      body: '每条连接的进程、目标、命中规则和流量实时可见，可搜索、可关闭。节点延迟一键测试。',
    },
    {
      title: '按网络切换',
      body: '按所在子网或网络接口自动切换配置文件，回家、到公司各用各的，无需定位权限。',
    },
    {
      title: '运行日志',
      body: '完整日志随时查看、过滤、导出，每条连接的去向都有记录。',
    },
  ],
  download: {
    title: '免费下载',
    lede: 'linko 完全免费、代码公开，不内置任何付费节点或推广。装好后应用会自动保持最新。',
    cta: '下载 macOS 版',
    allReleases: '全部版本',
    brewLabel: '也可以用 Homebrew 安装：',
  },
  footer: {
    line: 'linko 是自由软件（GPL-3.0 开源），基于开源内核 sing-box 构建。',
    docs: '文档',
  },
  changelog: {
    title: '更新日志',
    lede: '每个版本更新了什么。应用内的更新提示也显示同样的内容。',
    unreleased: '开发中',
    latest: '最新版本',
    untranslated: '该版本暂无中文说明，以下为英文原文。',
    sections: {
      Added: '新增',
      Changed: '改进',
      Deprecated: '即将移除',
      Removed: '移除',
      Fixed: '修复',
      Security: '安全',
    },
  },
};

const en: Copy = {
  home: {
    title: 'linko — a simple, stable, full-featured proxy client for macOS',
    description:
      'A simple, stable, full-featured macOS proxy client: subscription import, rule-based routing, live traffic view, per-network profile switching. Free and open source.',
  },
  changelogMeta: {
    title: 'Changelog — linko',
    description: "What changed in each linko release: new features, improvements and fixes.",
  },
  nav: { features: 'Features', download: 'Download', changelog: 'Changelog' },
  hero: {
    title: 'A simple, stable,\nfull-featured proxy client',
    lede: 'Subscription import, rule-based routing, a live traffic view and per-network switching — in one native macOS app.',
    download: 'Download free',
    github: 'View the source',
    fine: (v) => `v${v} · macOS 14 or later · Apple silicon & Intel · free and open source`,
    shotTitle: 'The linko menu bar panel',
  },
  features: [
    {
      title: 'Two interception modes',
      body: 'System proxy covers browsers and most apps; TUN takes the whole machine, terminals included. One switch, and the state survives restarts.',
    },
    {
      title: 'Rule-based routing',
      body: 'Match by domain, IP, process or port; proxy, connect directly or block. Changes apply live, and Surge / Clash rules import cleanly.',
    },
    {
      title: 'Subscription import',
      body: 'Paste a subscription or share link — the format is detected. Manual nodes work too, and profiles are kept separately and switch freely.',
    },
    {
      title: 'Traffic & connections',
      body: 'Process, destination, matched rule and throughput for every connection, searchable and closable. One-click latency tests.',
    },
    {
      title: 'Per-network profiles',
      body: 'Profiles switch automatically by subnet or interface as you move between networks. No location permission involved.',
    },
    {
      title: 'Runtime logs',
      body: 'View, filter and export the full log — every connection leaves a trace.',
    },
  ],
  download: {
    title: 'Download',
    lede: 'linko is completely free with its source in the open — no bundled paid nodes, no promotions. Once installed it keeps itself up to date.',
    cta: 'Download for macOS',
    allReleases: 'All releases',
    brewLabel: 'Or install with Homebrew:',
  },
  footer: {
    line: 'linko is free software (GPL-3.0), built on the open-source sing-box core.',
    docs: 'Docs',
  },
  changelog: {
    title: 'Changelog',
    lede: "What changed in each release — the same notes the app shows when it updates.",
    unreleased: 'In development',
    latest: 'Latest',
    untranslated: null,
    sections: {
      Added: 'New',
      Changed: 'Improved',
      Deprecated: 'Deprecated',
      Removed: 'Removed',
      Fixed: 'Fixed',
      Security: 'Security',
    },
  },
};

const COPY: Record<Lang, Copy> = { zh, en };

export const t = (lang: Lang): Copy => COPY[lang];

export const footerLinks = (lang: Lang) => [
  { label: 'GitHub', href: GITHUB_URL },
  { label: 'Releases', href: RELEASES_URL },
  { label: lang === 'zh' ? '使用文档' : 'Documentation', href: repoFileUrl('README.md') },
  { label: 'sing-box', href: SINGBOX_URL },
];
