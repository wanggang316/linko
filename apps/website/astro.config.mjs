// @ts-check
import { defineConfig } from 'astro/config';

// Deployed to GitHub Pages as a project site. The account carries the
// custom domain gumpw.com, so the project page is served at
// https://gumpw.com/linko/ (the *.github.io URL redirects there).
// Override both when moving to a dedicated domain, e.g.
//   SITE_URL=https://linko.app SITE_BASE=/ npm run build
const site = process.env.SITE_URL ?? 'https://gumpw.com';
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
