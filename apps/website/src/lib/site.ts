import { readRepoFile } from './repo';

export const REPO = 'wanggang316/linko';
export const GITHUB_URL = `https://github.com/${REPO}`;
export const RELEASES_URL = `${GITHUB_URL}/releases`;
export const LATEST_RELEASE_URL = `${RELEASES_URL}/latest`;
export const ISSUES_URL = `${GITHUB_URL}/issues`;
export const LICENSE_URL = `${GITHUB_URL}/blob/main/LICENSE`;
export const SINGBOX_URL = 'https://github.com/SagerNet/sing-box';

export const BREW_TAP_COMMAND = 'brew install --cask wanggang316/tap/linko';

export const MIN_MACOS = '14.0';
export const MIN_MACOS_NAME = 'Sonoma';

/** Link to a file in the repository, e.g. `docs/ARCHITECTURE.md`. */
export const repoFileUrl = (path: string): string =>
  `${GITHUB_URL}/blob/main/${path}`;

/** Shipping version, read from the single source of truth in `project.yml`. */
export const APP_VERSION: string = (() => {
  const match = readRepoFile('project.yml').match(
    /^[ \t]*MARKETING_VERSION:[ \t]*"?([0-9][^"\s]*)"?/m,
  );
  if (!match) throw new Error('[linko-site] MARKETING_VERSION not found in project.yml');
  return match[1];
})();
