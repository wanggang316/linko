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
  kicker: string;
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
    notes: string[];
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
    title: 'linko — 简单可靠的 macOS 代理客户端',
    description:
      '简单可靠的 macOS 代理客户端：粘贴订阅、选好节点、一键开启。智能分流、流量观测、自动切换，免费开源。',
  },
  changelogMeta: {
    title: '更新日志 — linko',
    description: 'linko 每个版本更新了什么：新增功能、体验改进与问题修复。',
  },
  nav: { features: '功能', download: '下载', changelog: '更新日志' },
  hero: {
    title: '代理，本该\n这么简单',
    lede: '粘贴订阅，选好节点，一键开启。分流规则、流量观测、自动切换，都在一个干净的 macOS 原生应用里。',
    download: '免费下载',
    github: '查看源代码',
    fine: (v) => `v${v} · macOS 14 及以上 · Apple 芯片与 Intel · 免费开源`,
    shotTitle: 'linko 主面板（示意）',
  },
  features: [
    {
      kicker: '一键开启',
      title: '点一下，就开好了',
      body: '从菜单栏一键开关。普通模式接管浏览器等常见应用；全局模式连命令行和不走系统设置的应用也一并接管。重启电脑自动恢复上次的状态，不用每次重新设置。',
    },
    {
      kicker: '智能分流',
      title: '该走的走，该直连的直连',
      body: '用规则决定每个网站、每个应用怎么走：国外服务走代理，国内网站直连，广告域名直接拦截。改动立即生效；正在浏览的网站还能一键加规则，不用打开主界面。',
    },
    {
      kicker: '流量观测',
      title: '谁在联网，一目了然',
      body: '哪个应用连去了哪里、命中了哪条规则、用了多少流量，实时看到。节点一键测速，慢了随时换。',
    },
    {
      kicker: '订阅即用',
      title: '订阅一贴就能用',
      body: '粘贴订阅链接或节点分享链接，自动识别格式，节点立刻可用；也可以手动添加。多套配置随意切换，换个 Wi-Fi 还能按网络自动切换。',
    },
  ],
  download: {
    title: '免费下载，开源可信',
    lede: 'linko 完全免费、代码公开，不内置任何付费节点或推广。装好后应用会自动保持最新。',
    cta: '下载 macOS 版',
    allReleases: '全部版本',
    brewLabel: '也可以用 Homebrew 安装：',
    notes: [
      '需要 macOS 14 及以上，Apple 芯片与 Intel 都支持。',
      '全局模式首次使用时，需在系统设置中批准一次扩展。',
      '需要自备订阅或节点，linko 不提供任何节点。',
    ],
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
    title: 'linko — the simple, reliable proxy client for macOS',
    description:
      'A simple, reliable macOS proxy client: paste a subscription, pick a node, switch it on. Smart routing, live traffic view, automatic switching. Free and open source.',
  },
  changelogMeta: {
    title: 'Changelog — linko',
    description: "What changed in each linko release: new features, improvements and fixes.",
  },
  nav: { features: 'Features', download: 'Download', changelog: 'Changelog' },
  hero: {
    title: 'A proxy client,\nmade simple',
    lede: 'Paste a subscription, pick a node, switch it on. Routing rules, a live traffic view and automatic switching — in one clean, native macOS app.',
    download: 'Download free',
    github: 'View the source',
    fine: (v) => `v${v} · macOS 14 or later · Apple silicon & Intel · free and open source`,
    shotTitle: 'The linko panel (illustration)',
  },
  features: [
    {
      kicker: 'One click',
      title: 'Flip a switch, and you are through',
      body: 'Turn the proxy on and off right from the menu bar. Standard mode covers browsers and most apps; global mode also catches terminals and apps that ignore system settings. After a reboot, linko restores itself — no re-setup.',
    },
    {
      kicker: 'Smart routing',
      title: 'The right traffic takes the right path',
      body: 'Rules decide how each site and app connects: foreign services through the proxy, local sites directly, ad domains blocked. Changes apply instantly — and you can add a rule for the site you are on with one click.',
    },
    {
      kicker: 'Live traffic',
      title: 'See exactly who is online',
      body: 'Which app is connecting where, which rule it matched, how much data it used — all live. Test node speed with one click and switch whenever one slows down.',
    },
    {
      kicker: 'Paste and go',
      title: 'Your subscription just works',
      body: 'Paste a subscription or share link and the format is recognized — nodes are ready at once, or add them by hand. Keep several profiles and switch freely; linko can even switch by Wi-Fi network.',
    },
  ],
  download: {
    title: 'Free, and open to inspection',
    lede: 'linko is completely free with its source in the open — no bundled paid nodes, no promotions. Once installed it keeps itself up to date.',
    cta: 'Download for macOS',
    allReleases: 'All releases',
    brewLabel: 'Or install with Homebrew:',
    notes: [
      'Requires macOS 14 or later, on Apple silicon and Intel.',
      'Global mode asks you to approve an extension in System Settings, once.',
      'Bring your own subscription or nodes — linko provides none.',
      'The app interface currently ships in Chinese.',
    ],
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
