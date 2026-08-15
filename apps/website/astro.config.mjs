// @ts-check
import { defineConfig } from 'astro/config';

// Deployed to GitHub Pages as a project site by default:
// https://wanggang316.github.io/linko/
// Override both when moving to a custom domain, e.g.
//   SITE_URL=https://linko.app SITE_BASE=/ npm run build
const site = process.env.SITE_URL ?? 'https://wanggang316.github.io';
const base = process.env.SITE_BASE ?? '/linko';

// https://astro.build/config
export default defineConfig({
  site,
  base,
  trailingSlash: 'always',
  i18n: {
    defaultLocale: 'zh',
    locales: ['zh', 'en'],
    routing: { prefixDefaultLocale: false },
  },
  build: { format: 'directory' },
  devToolbar: { enabled: false },
});
