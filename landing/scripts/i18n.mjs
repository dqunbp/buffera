import { readFile } from 'node:fs/promises';
import { renderAnalytics } from './analytics.mjs';

export const languages = ['ru', 'en'];
export const siteOrigin = 'https://buffera.app';
const src = new URL('../src/', import.meta.url);
const placeholders = value => [...value.matchAll(/\{([a-zA-Z]\w*)\}/g)].map(match => match[1]).sort();

export function validateLocale(reference, candidate, path = 'locale') {
  if (typeof reference === 'string') {
    if (typeof candidate !== 'string' || !candidate.trim()) throw new Error(`Missing text: ${path}`);
    if (JSON.stringify(placeholders(reference)) !== JSON.stringify(placeholders(candidate))) {
      throw new Error(`Message placeholders differ: ${path}`);
    }
    return;
  }
  if (reference === null || typeof reference !== 'object') {
    if (reference !== candidate) throw new Error(`Invalid value: ${path}`);
    return;
  }
  if (!candidate || typeof candidate !== 'object' || Array.isArray(reference) !== Array.isArray(candidate)) {
    throw new Error(`Invalid structure: ${path}`);
  }
  const keys = Object.keys(reference).sort();
  if (JSON.stringify(keys) !== JSON.stringify(Object.keys(candidate).sort())) {
    throw new Error(`Translation keys differ: ${path}`);
  }
  for (const key of keys) validateLocale(reference[key], candidate[key], `${path}.${key}`);
}

export async function loadLocales() {
  const locales = Object.fromEntries(await Promise.all(languages.map(async lang => [
    lang, JSON.parse(await readFile(new URL(`locales/${lang}.json`, src), 'utf8')),
  ])));
  for (const lang of languages) {
    const locale = locales[lang];
    validateLocale(locales.ru, locale, lang);
    locale.runtime.samples.forEach((sample, index) => {
      const reference = locales.ru.runtime.samples[index];
      if (sample.id !== reference.id || sample.kind !== reference.kind) {
        throw new Error(`Demo identity differs: ${lang}.samples.${index}`);
      }
    });
  }
  return locales;
}

export const escapeHtml = value => value.replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[char]));

// Only language-neutral routes redirect; explicit locale URLs never redirect.
function redirectToPreferredLanguage(supported, route = '') {
  if (location.pathname !== `/${route}`) return;
  const preferences = Array.isArray(navigator.languages) && navigator.languages.length
    ? navigator.languages : [navigator.language];
  const language = preferences
    .map(value => typeof value === 'string' ? value.toLowerCase().split('-')[0] : '')
    .find(value => supported.includes(value)) || 'en';
  location.replace(`/${language}/${route}${location.search}${location.hash}`);
}

export function renderPage(template, locale, lang, assetVersion = 'local', { isRoot = false, route = '', fragments = {} } = {}) {
  if (!languages.includes(lang)) throw new Error(`Unsupported locale: ${lang}`);
  if (isRoot && lang !== 'en') throw new Error('The root page must use the English fallback');
  const values = {
    lang,
    assetVersion,
    supportUrl: 'https://web.tribute.tg/d/SHI',
    assetPrefix: route ? '/' : isRoot ? './' : '../',
    homeUrl: `/${lang}/`,
    docsUrl: `/${lang}/docs/`,
    mcpDocsUrl: `/${lang}/docs/agents/`,
    canonical: `${siteOrigin}/${lang}/${route}`,
    defaultUrl: `${siteOrigin}/${route}`,
    ruUrl: `${siteOrigin}/ru/${route}`,
    enUrl: `${siteOrigin}/en/${route}`,
    ogLocale: lang === 'ru' ? 'ru_RU' : 'en_US',
    ogAlternate: lang === 'ru' ? 'en_US' : 'ru_RU',
    ogImage: `${siteOrigin}/og/${lang}.png`,
  };
  return template.replace(/\{\{([\w.]+)\}\}/g, (_, key) => {
    if (key === 'analytics') return renderAnalytics({ isRoot });
    if (Object.hasOwn(fragments, key)) return fragments[key];
    if (key === 'languageRedirect') {
      return isRoot
        ? `<script id="language-redirect">(${redirectToPreferredLanguage.toString()})(${JSON.stringify(languages)},${JSON.stringify(route)});</script>`
        : '';
    }
    if (key === 'runtimeJson') {
      // Keep translated demo text inert, including a literal closing script tag.
      return JSON.stringify(locale.runtime).replace(/[<>&\u2028\u2029]/g, char =>
        `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`);
    }
    const value = key.startsWith('page.') ? locale.page[key.slice(5)] : values[key];
    if (typeof value !== 'string' || !value) throw new Error(`Unresolved template key: ${key} (${lang})`);
    return escapeHtml(value);
  });
}
