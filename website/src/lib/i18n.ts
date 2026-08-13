export type Lang = 'zh' | 'en';

export const LANGS: readonly Lang[] = ['zh', 'en'] as const;
export const DEFAULT_LANG: Lang = 'zh';

export const HTML_LANG: Record<Lang, string> = { zh: 'zh-Hans', en: 'en' };
export const LANG_LABEL: Record<Lang, string> = { zh: '中文', en: 'English' };

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

export function formatDate(iso: string, lang: Lang): string {
  const date = new Date(`${iso}T00:00:00Z`);
  return new Intl.DateTimeFormat(lang === 'zh' ? 'zh-CN' : 'en-US', {
    year: 'numeric',
    month: lang === 'zh' ? 'long' : 'short',
    day: 'numeric',
    timeZone: 'UTC',
  }).format(date);
}

interface Feature {
  icon: string;
  title: string;
  body: string;
}

interface Copy {
  home: { title: string; description: string };
  changelogMeta: { title: string; description: string };
  nav: { features: string; automation: string; download: string; changelog: string; docs: string; github: string; menu: string; language: string; theme: string };
  hero: {
    whatsNew: (version: string) => string;
    titleLead: string;
    titleAccent: string;
    subtitle: string;
    primaryCta: string;
    secondaryCta: string;
    meta: (version: string) => string;
    brewLabel: string;
  };
  mock: { caption: string };
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] };
  trust: { eyebrow: string; title: string; body: string; items: string[] };
  automation: { eyebrow: string; title: string; body: string; hint: string; lines: { cmd: string; note: string }[] };
  download: {
    eyebrow: string;
    title: string;
    subtitle: string;
    direct: { title: string; body: string; cta: string; hint: (version: string) => string };
    brew: { title: string; body: string; hint: string };
    requirements: string[];
    allReleases: string;
  };
  changelog: {
    title: string;
    subtitle: string;
    source: string;
    unreleased: string;
    latest: string;
    releasesNav: string;
    untranslated: string | null;
    allReleases: string;
    sections: Record<string, string>;
  };
  footer: { tagline: string; product: string; docs: string; openSource: string; license: string; legal: string };
  common: { copy: string; copied: string; backToTop: string };
}

const zh: Copy = {
  home: {
    title: 'linko — 菜单栏里的 macOS 原生代理客户端',
    description:
      '开源的 macOS 原生代理客户端，以 sing-box 为内核：系统代理与 TUN 两种接管模式、完整规则分流、实时连接观测、订阅与配置文件管理。GPL-3.0，全部可审计。',
  },
  changelogMeta: {
    title: '更新日志 — linko',
    description: 'linko 每个版本的变更记录：新增功能、行为变更与修复。',
  },
  nav: {
    features: '特性',
    automation: '自动化',
    download: '下载',
    changelog: '更新日志',
    docs: '文档',
    github: 'GitHub',
    menu: '菜单',
    language: '切换语言',
    theme: '切换主题',
  },
  hero: {
    whatsNew: (v) => `v${v} 已发布 · 看看更新了什么`,
    titleLead: '把 sing-box',
    titleAccent: '装进菜单栏',
    subtitle:
      'linko 是一款开源的 macOS 原生代理客户端：SwiftUI 菜单栏常驻，以 sing-box 为内核。规则分流、连接观测、订阅与配置文件管理全部开源可审计——不捆绑任何订阅服务。',
    primaryCta: '下载 macOS 版',
    secondaryCta: '在 GitHub 上查看',
    meta: (v) => `macOS 14.0+ · Apple Silicon 与 Intel · GPL-3.0 · v${v}`,
    brewLabel: '或使用 Homebrew',
  },
  mock: { caption: '菜单栏面板 · 示意' },
  features: {
    eyebrow: '特性',
    title: '一个客户端，管住全部出网流量',
    subtitle: '从流量接管到规则分流、从订阅解析到连接观测，全部在原生 SwiftUI 里完成。',
    items: [
      {
        icon: 'shuffle',
        title: '两种接管模式',
        body: '「系统代理」一键写入 macOS 的 HTTP / SOCKS 代理设置；「TUN 全局」经系统扩展接管整机流量。同一张卡片里切换与启停，状态一目了然。',
      },
      {
        icon: 'route',
        title: '完整的规则分流',
        body: 'DOMAIN / SUFFIX / KEYWORD / REGEX、IP-CIDR、PROCESS、PORT、GEOIP / GEOSITE / RULE-SET 与 LOGICAL 全量规则，配合 select、url-test 与可嵌套的策略组；可导入 Surge 与 Clash 规则集，也能直接 REJECT 拦截。',
      },
      {
        icon: 'link',
        title: '订阅、节点与配置文件',
        body: '订阅 URL、本地文件或粘贴的分享链接（ss / vmess / vless / trojan / hysteria2 / tuic）自动识别格式；支持手动建节点，多份配置文件之间无损切换。',
      },
      {
        icon: 'activity',
        title: '看得见的流量',
        body: '实时连接列表带进程、目标、命中规则与链路，可搜索、过滤、单条或全部关闭；速率、总量、日志导出与按应用的流量统计一并提供。',
      },
      {
        icon: 'server',
        title: 'DNS 与网络自适应',
        body: 'sing-box 1.12+ 的 typed-server DNS 配置、DNS 分流规则与本地 hosts 映射；换到不同 Wi-Fi 时按子网或网络接口自动切换配置文件，且不需要定位权限。',
      },
      {
        icon: 'terminal',
        title: '可脚本化控制',
        body: '注册 linko:// URL scheme，并附带一个薄封装的 shell CLI：开关代理、切换模式、选节点、换配置、跑延迟测试，都能写进你的脚本与快捷指令。',
      },
    ],
  },
  trust: {
    eyebrow: '为什么可信',
    title: '轻量、透明、可审计',
    body: '代理客户端握着你的全部流量。linko 的做法是把每一处都摊开：配置怎么生成、内核怎么启动、系统代理怎么改，源码里全都看得到。',
    items: [
      'GPL-3.0 开源，配置生成与内核管理全部可审计',
      '启动前先跑 sing-box 配置预检，坏配置进不去',
      '更新包只在 EdDSA 签名校验通过后才安装',
      '不内置、不推荐、不售卖任何节点或订阅',
    ],
  },
  automation: {
    eyebrow: '自动化',
    title: '也能不打开界面就用',
    body: 'linko 注册了 linko:// URL scheme，仓库里的 scripts/linko 是它的一层薄封装。适合接进 Raycast、Alfred、快捷指令或任何 shell 脚本。',
    hint: '等价于直接打开 URL，例如 open "linko://toggle"。导入订阅始终会在应用内弹窗确认。',
    lines: [
      { cmd: 'linko on | off | toggle', note: '开 / 关 / 反转代理' },
      { cmd: 'linko mode tun | system', note: '切换接管模式' },
      { cmd: 'linko select "<node name>"', note: '按显示名选择节点' },
      { cmd: 'linko profile "<name>"', note: '按名称切换配置文件' },
      { cmd: 'linko install <url> ["name"]', note: '导入订阅（会弹窗确认）' },
      { cmd: 'linko test', note: '对所有节点跑一次延迟测试' },
      { cmd: 'linko status', note: '内核可达性与当前节点' },
    ],
  },
  download: {
    eyebrow: '下载',
    title: '装上，然后导入你的订阅',
    subtitle: '签名并公证的 DMG，安装后由 Sparkle 负责后续更新。',
    direct: {
      title: '直接下载',
      body: '从 GitHub Releases 获取签名并公证过的 DMG，拖进「应用程序」即可。',
      cta: '下载 macOS 版',
      hint: (v) => `当前版本 v${v} · DMG`,
    },
    brew: {
      title: 'Homebrew',
      body: '偏好命令行的话，用官方 tap 安装，后续同样由应用内更新接管。',
      hint: '安装后仍由 Sparkle 负责更新，brew upgrade 不会重复升级。',
    },
    requirements: [
      'macOS 14 Sonoma 或更高版本，Apple Silicon 与 Intel 均支持',
      '开启 TUN 全局模式需在「系统设置 › 通用 › 登录项与扩展」中批准系统扩展',
      '需要自备订阅或节点信息——linko 不内置、不附带任何节点',
    ],
    allReleases: '查看全部版本',
  },
  changelog: {
    title: '更新日志',
    subtitle: '每个版本下的条目，同样是应用内更新提示里显示的说明。',
    source: '内容来自仓库中的 CHANGELOG.md，随发布流程自动同步。',
    unreleased: '开发中',
    latest: '最新',
    releasesNav: '版本',
    untranslated: '该版本暂无中文说明，以下为英文原文。',
    allReleases: '在 GitHub 上查看全部版本',
    sections: {
      Added: '新增',
      Changed: '变更',
      Deprecated: '废弃',
      Removed: '移除',
      Fixed: '修复',
      Security: '安全',
    },
  },
  footer: {
    tagline: '开源的 macOS 原生代理客户端，以 sing-box 为内核。',
    product: '产品',
    docs: '文档',
    openSource: '开源',
    license: 'GPL-3.0 许可证',
    legal:
      'linko 以 GPL-3.0 授权，与其代理内核 sing-box 的许可证兼容。sing-box © SagerNet 及其贡献者。',
  },
  common: { copy: '复制', copied: '已复制', backToTop: '回到顶部' },
};

const en: Copy = {
  home: {
    title: 'linko — a native macOS proxy client in your menu bar',
    description:
      'Open-source native macOS proxy client powered by the sing-box core: system proxy and TUN modes, full rule-based routing, live connection insight, subscription and profile management. GPL-3.0, fully auditable.',
  },
  changelogMeta: {
    title: 'Changelog — linko',
    description: 'Every linko release: what was added, what changed and what got fixed.',
  },
  nav: {
    features: 'Features',
    automation: 'Automation',
    download: 'Download',
    changelog: 'Changelog',
    docs: 'Docs',
    github: 'GitHub',
    menu: 'Menu',
    language: 'Switch language',
    theme: 'Switch theme',
  },
  hero: {
    whatsNew: (v) => `v${v} is out · see what changed`,
    titleLead: 'sing-box, right in',
    titleAccent: 'your menu bar',
    subtitle:
      'linko is an open-source, native macOS proxy client — a SwiftUI menu bar app powered by the sing-box core. Rule-based routing, connection insight, subscriptions and profiles, all auditable, with no bundled subscription service.',
    primaryCta: 'Download for macOS',
    secondaryCta: 'View on GitHub',
    meta: (v) => `macOS 14.0+ · Apple Silicon & Intel · GPL-3.0 · v${v}`,
    brewLabel: 'or install with Homebrew',
  },
  mock: { caption: 'Menu bar panel — illustration; the app UI ships in Chinese' },
  features: {
    eyebrow: 'Features',
    title: 'One client for everything that leaves your Mac',
    subtitle:
      'From traffic interception to rule-based routing, from subscription parsing to live connection insight — all in native SwiftUI.',
    items: [
      {
        icon: 'shuffle',
        title: 'Two ways to intercept',
        body: 'System proxy mode writes the macOS HTTP / SOCKS proxy settings for you. TUN mode takes over the whole machine through a system extension. Switch modes and start or stop the tunnel from one card, with the state always in view.',
      },
      {
        icon: 'route',
        title: 'Rule-based routing, in full',
        body: 'DOMAIN / SUFFIX / KEYWORD / REGEX, IP-CIDR, PROCESS, PORT, GEOIP / GEOSITE / RULE-SET and LOGICAL rules, paired with select, url-test and nestable policy groups. Import Surge and Clash rule sets, or block outright with REJECT.',
      },
      {
        icon: 'link',
        title: 'Subscriptions, nodes and profiles',
        body: 'Paste a subscription URL, pick a file, or drop in share links (ss / vmess / vless / trojan / hysteria2 / tuic) — the format is detected for you. Add nodes by hand, and switch between profiles losslessly.',
      },
      {
        icon: 'activity',
        title: 'Traffic you can actually see',
        body: 'A live connection list with process, destination, matched rule and chain — searchable, filterable, closable one by one or all at once. Plus rates, totals, exportable logs and per-application traffic stats.',
      },
      {
        icon: 'server',
        title: 'DNS and network awareness',
        body: 'sing-box 1.12+ typed-server DNS, DNS routing rules and a local hosts map. Move between networks and linko switches profiles by subnet or interface — no location permission required.',
      },
      {
        icon: 'terminal',
        title: 'Scriptable control',
        body: 'linko registers a linko:// URL scheme with a thin shell CLI on top. Toggle the proxy, switch modes, pick a node, change profile or run a delay test — from Raycast, Alfred, Shortcuts or any script.',
      },
    ],
  },
  trust: {
    eyebrow: 'Why trust it',
    title: 'Light, transparent, auditable',
    body: 'A proxy client holds all of your traffic. linko answers that by leaving nothing hidden: how the config is generated, how the core is launched, how the system proxy is changed — it is all right there in the source.',
    items: [
      'GPL-3.0 open source — config generation and core management are fully auditable',
      'A sing-box config pre-flight check runs before the core starts, so a bad config never launches',
      'Updates install only after their EdDSA signature verifies',
      'No bundled, recommended or resold nodes or subscriptions',
    ],
  },
  automation: {
    eyebrow: 'Automation',
    title: 'Drive it without opening the UI',
    body: 'linko registers a linko:// URL scheme, and scripts/linko in the repository is a thin wrapper around it. Wire it into Raycast, Alfred, Shortcuts or any shell script.',
    hint: 'Equivalent to opening the URL directly, e.g. open "linko://toggle". Importing a subscription always asks for confirmation in-app.',
    lines: [
      { cmd: 'linko on | off | toggle', note: 'turn the proxy on / off / flip it' },
      { cmd: 'linko mode tun | system', note: 'switch the interception mode' },
      { cmd: 'linko select "<node name>"', note: 'select a node by display name' },
      { cmd: 'linko profile "<name>"', note: 'switch the active profile' },
      { cmd: 'linko install <url> ["name"]', note: 'import a subscription (asks to confirm)' },
      { cmd: 'linko test', note: 'run a delay test across nodes' },
      { cmd: 'linko status', note: 'core reachability + current node' },
    ],
  },
  download: {
    eyebrow: 'Download',
    title: 'Install it, then bring your own subscription',
    subtitle: 'A signed and notarized DMG; Sparkle takes over for updates once installed.',
    direct: {
      title: 'Direct download',
      body: 'Grab the signed, notarized DMG from GitHub Releases and drag it into Applications.',
      cta: 'Download for macOS',
      hint: (v) => `Current release v${v} · DMG`,
    },
    brew: {
      title: 'Homebrew',
      body: 'Prefer the terminal? Install from the official tap — in-app updates still apply.',
      hint: 'Sparkle keeps it updated afterwards, so brew upgrade will not double-update it.',
    },
    requirements: [
      'macOS 14 Sonoma or later, on Apple Silicon and Intel',
      'TUN mode needs its system extension approved in System Settings › General › Login Items & Extensions',
      'Bring your own subscription or nodes — linko bundles none',
      'The app interface currently ships in Chinese only',
    ],
    allReleases: 'Browse all releases',
  },
  changelog: {
    title: 'Changelog',
    subtitle: "Each release's entries double as the notes shown in the app's update dialog.",
    source: 'Sourced from CHANGELOG.md in the repository and kept in sync by the release pipeline.',
    unreleased: 'Unreleased',
    latest: 'Latest',
    releasesNav: 'Releases',
    untranslated: null,
    allReleases: 'See all releases on GitHub',
    sections: {
      Added: 'Added',
      Changed: 'Changed',
      Deprecated: 'Deprecated',
      Removed: 'Removed',
      Fixed: 'Fixed',
      Security: 'Security',
    },
  },
  footer: {
    tagline: 'Open-source native macOS proxy client, powered by the sing-box core.',
    product: 'Product',
    docs: 'Docs',
    openSource: 'Open source',
    license: 'GPL-3.0 license',
    legal:
      'linko is licensed under GPL-3.0, compatible with the license of sing-box, the proxy core it uses. sing-box is © SagerNet and its contributors.',
  },
  common: { copy: 'Copy', copied: 'Copied', backToTop: 'Back to top' },
};

const COPY: Record<Lang, Copy> = { zh, en };

export const t = (lang: Lang): Copy => COPY[lang];
