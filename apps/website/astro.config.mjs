// @ts-check
import { defineConfig } from 'astro/config';

// Deployed to GitHub Pages under the project's custom domain
// https://linko.gumpw.com/ (set in the repo's Pages settings; the
// *.github.io URL redirects there). Override for another domain, e.g.
//   SITE_URL=https://linko.app npm run build
const site = process.env.SITE_URL ?? 'https://linko.gumpw.com';
const base = process.env.SITE_BASE ?? '/';

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
