import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * The site is a leaf of the app repository, and the repository — not a copy
 * inside `website/` — is the source of truth for version and release notes.
 * Resolve those files at build time so the site can never drift from them.
 */
function locate(name: string): string {
  const candidates = [
    fileURLToPath(new URL(`../../../${name}`, import.meta.url)),
    resolve(process.cwd(), '..', name),
    resolve(process.cwd(), name),
  ];
  const found = candidates.find((p) => existsSync(p));
  if (!found) {
    throw new Error(
      `[linko-site] cannot locate ${name}; looked in:\n  ${candidates.join('\n  ')}`,
    );
  }
  return found;
}

export function readRepoFile(name: string): string {
  return readFileSync(locate(name), 'utf8');
}
