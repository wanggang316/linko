import { readRepoFile } from './repo';
import zhOverlay from '../data/changelog.zh.json';
import type { Lang } from './i18n';

export interface ChangelogSection {
  /** Keep a Changelog section name, kept in English so it can be localized. */
  title: string;
  /** Entries as inline HTML (bold / code / links resolved). */
  entries: string[];
}

export interface Release {
  version: string;
  /** ISO date from the heading; `null` for `[Unreleased]`. */
  date: string | null;
  unreleased: boolean;
  /** Free-form paragraph between the version heading and the first section. */
  note: string | null;
  sections: ChangelogSection[];
  /** True when the Chinese page falls back to the English source text. */
  translated: boolean;
}

interface OverlayRelease {
  note?: string | null;
  sections?: { title: string; entries: string[] }[];
}

const HEADING = /^##\s+\[([^\]]+)\](?:\s+-\s+(\d{4}-\d{2}-\d{2}))?\s*$/;
const SECTION = /^###\s+(.+?)\s*$/;
const BULLET = /^-\s+(.*)$/;

const escapeHtml = (raw: string): string =>
  raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

/**
 * Renders the small Markdown subset the changelog actually uses: links, inline
 * code and bold. Everything is escaped first, so unknown syntax degrades to
 * plain text rather than to markup.
 */
export function renderInline(raw: string): string {
  return escapeHtml(raw)
    .replace(
      /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
      '<a href="$2" rel="noopener noreferrer" target="_blank">$1</a>',
    )
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
}

function pushEntry(section: ChangelogSection | null, buffer: string[]): void {
  if (!section || buffer.length === 0) return;
  section.entries.push(renderInline(buffer.join(' ')));
  buffer.length = 0;
}

function parse(markdown: string): Release[] {
  const releases: Release[] = [];
  let release: Release | null = null;
  let section: ChangelogSection | null = null;
  let buffer: string[] = [];
  let note: string[] = [];

  const closeSection = (): void => {
    pushEntry(section, buffer);
    if (section && section.entries.length > 0) release?.sections.push(section);
    section = null;
  };

  const closeRelease = (): void => {
    closeSection();
    if (release) {
      release.note = note.length > 0 ? renderInline(note.join(' ')) : null;
      const empty = release.sections.length === 0 && release.note === null;
      if (!(release.unreleased && empty)) releases.push(release);
    }
    note = [];
    release = null;
  };

  for (const line of markdown.split('\n')) {
    const heading = HEADING.exec(line);
    if (heading) {
      closeRelease();
      const version = heading[1];
      release = {
        version,
        date: heading[2] ?? null,
        unreleased: version.toLowerCase() === 'unreleased',
        note: null,
        sections: [],
        translated: false,
      };
      continue;
    }
    if (!release) continue;

    const sectionHeading = SECTION.exec(line);
    if (sectionHeading) {
      closeSection();
      section = { title: sectionHeading[1], entries: [] };
      continue;
    }

    const bullet = BULLET.exec(line);
    if (bullet) {
      pushEntry(section, buffer);
      buffer.push(bullet[1].trim());
      continue;
    }

    const text = line.trim();
    if (text === '') {
      pushEntry(section, buffer);
      continue;
    }
    // Wrapped continuation of the previous bullet, or the free-form intro
    // paragraph that sits between a version heading and its first section.
    if (section) buffer.push(text);
    else note.push(text);
  }
  closeRelease();

  return releases;
}

const overlay = zhOverlay as Record<string, OverlayRelease>;

/** Applies the hand-written Chinese overlay, falling back per release. */
function localize(releases: Release[], lang: Lang): Release[] {
  if (lang !== 'zh') return releases;
  return releases.map((release) => {
    const zh = overlay[release.version];
    if (!zh) return release;
    return {
      ...release,
      note: zh.note ? renderInline(zh.note) : release.note,
      sections: zh.sections
        ? zh.sections.map((s) => ({
            title: s.title,
            entries: s.entries.map(renderInline),
          }))
        : release.sections,
      translated: true,
    };
  });
}

export function getReleases(lang: Lang): Release[] {
  return localize(parse(readRepoFile('CHANGELOG.md')), lang);
}
