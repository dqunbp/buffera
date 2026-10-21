import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { loadLocales, renderPage, validateLocale, siteOrigin } from './i18n.mjs';

const locales = await loadLocales();
const template = await readFile(new URL('../src/index.html', import.meta.url), 'utf8');

const rootPage = () => renderPage(template, locales.en, 'en', 'local', { isRoot: true });
const rootScript = () => rootPage().match(/<script id="language-redirect">([^]*?)<\/script>/)[1];

function redirectsFor(navigator, { pathname = '/', search = '', hash = '' } = {}) {
  const destinations = [];
  runInNewContext(rootScript(), {
    navigator,
    location: { pathname, search, hash, replace: value => destinations.push(value) },
  }, { timeout: 1_000 });
  return destinations;
}

function assertAlternateUrls(html) {
  for (const [lang, path] of [['ru', '/ru/'], ['en', '/en/'], ['x-default', '/']]) {
    assert.ok(html.includes(`<link rel="alternate" hreflang="${lang}" href="${siteOrigin}${path}">`));
  }
}

function assertAssetsResolve(html, pageUrl) {
  const assets = [
    [html.match(/rel="stylesheet" href="([^"]+)"/)[1], '/styles.css'],
    [html.match(/<script src="([^"]+)"/)[1], '/app.js'],
    [html.match(/rel="icon" href="([^"]+)"/)[1], '/favicon.svg'],
  ];
  for (const [reference, expected] of assets) {
    assert.equal(new URL(reference, pageUrl).pathname, expected);
  }
}

test('explicit language URLs render complete static pages without redirecting', () => {
  for (const lang of ['ru', 'en']) {
    const html = renderPage(template, locales[lang], lang);
    const url = `${siteOrigin}/${lang}/`;
    assert.ok(html.includes(`<html lang="${lang}">`));
    assert.ok(html.includes(`<link rel="canonical" href="${url}">`));
    assert.ok(html.includes(`<meta property="og:url" content="${url}">`));
    assert.ok(html.includes(`content="${siteOrigin}/og/${lang}.png"`));
    assert.ok(html.includes('name="twitter:card" content="summary_large_image"'));
    assert.ok(html.includes(`property="og:locale" content="${lang === 'ru' ? 'ru_RU' : 'en_US'}"`));
    assert.ok(html.includes(`property="og:locale:alternate" content="${lang === 'ru' ? 'en_US' : 'ru_RU'}"`));
    assertAlternateUrls(html);
    assertAssetsResolve(html, url);
    assert.ok(html.includes('https://t.me/crypto_and_pug'));
    assert.ok(html.includes('made by <a href="https://github.com/dqunbp">@dqunbp</a>'));
    assert.doesNotMatch(html, /\{\{[\w.]+\}\}/);
    assert.doesNotMatch(html, /language-redirect|language-switch|header-actions/);
    const runtime = JSON.parse(html.match(/id="locale-data" type="application\/json">([^]*?)<\/script>/)[1]);
    assert.equal(runtime.samples.length, 4);
    assert.equal(runtime.count, locales[lang].runtime.count);
    if (lang === 'en') assert.doesNotMatch(html, /[А-Яа-яЁё]/);
  }
});

test('root has complete English fallback content and metadata without JavaScript', () => {
  const html = rootPage();
  assert.ok(html.includes('<html lang="en">'));
  assert.ok(html.includes(`<link rel="canonical" href="${siteOrigin}/en/">`));
  assert.ok(html.includes(`<meta property="og:url" content="${siteOrigin}/en/">`));
  assert.ok(html.includes('<meta property="og:locale" content="en_US">'));
  assert.ok(html.includes(`<meta property="og:image" content="${siteOrigin}/og/en.png">`));
  assert.ok(html.includes(locales.en.page.hero_title_text));
  assert.ok(html.includes(locales.en.page.demo_fallback_text));
  assertAlternateUrls(html);
  assertAssetsResolve(html, `${siteOrigin}/`);
  assert.doesNotMatch(html, /language-switch|header-actions|\{\{[\w.]+\}\}/);
  assert.throws(() => renderPage(template, locales.ru, 'ru', 'local', { isRoot: true }), /English fallback/);
});

test('root chooses the first supported preferred browser language including regional tags', () => {
  assert.deepEqual(redirectsFor({ languages: ['ru-RU', 'en-US'] }), ['/ru/']);
  assert.deepEqual(redirectsFor({ languages: ['en-GB', 'ru'] }), ['/en/']);
  assert.deepEqual(redirectsFor({ languages: ['de-DE', 'RU-ru', 'en'] }), ['/ru/']);
  assert.deepEqual(redirectsFor({ languages: ['fr', 'EN-us', 'ru'] }), ['/en/']);
});

test('root falls back to navigator.language or English when browser preferences are missing or unsupported', () => {
  assert.deepEqual(redirectsFor({ language: 'ru-RU' }), ['/ru/']);
  assert.deepEqual(redirectsFor({ languages: [], language: 'ru' }), ['/ru/']);
  assert.deepEqual(redirectsFor({ languages: ['de-DE', 'fr'] }), ['/en/']);
  assert.deepEqual(redirectsFor({ languages: [null, 1, '', 'ru'] }), ['/ru/']);
  assert.deepEqual(redirectsFor({}), ['/en/']);
});

test('root preserves the complete query string and hash during language selection', () => {
  const search = '?q=%D0%BC%D0%B0%D0%BA&next=%2Fen%2F&tag=a&tag=b';
  const hash = '#features';
  assert.deepEqual(redirectsFor({ languages: ['ru'] }, { search, hash }), [`/ru/${search}${hash}`]);
  assert.deepEqual(redirectsFor({ languages: ['de'] }, { search, hash }), [`/en/${search}${hash}`]);
});

test('the root redirect also guards explicit paths against hosting fallbacks and redirect loops', () => {
  for (const pathname of ['/ru/', '/en/', '/ru/index.html', '/en/index.html', '/unknown']) {
    assert.deepEqual(redirectsFor({ languages: ['ru'] }, { pathname }), []);
    assert.deepEqual(redirectsFor({ languages: ['en'] }, { pathname }), []);
  }
});

test('incomplete translations and lost message variables fail validation', () => {
  const missing = structuredClone(locales.en);
  delete missing.page.hero_title_text;
  assert.throws(() => validateLocale(locales.ru, missing), /keys differ/);
  const wrongVariables = structuredClone(locales.en);
  wrongVariables.runtime.count = '{visible} examples';
  assert.throws(() => validateLocale(locales.ru, wrongVariables), /placeholders differ/);
  const empty = structuredClone(locales.en);
  empty.runtime.empty = '';
  assert.throws(() => validateLocale(locales.ru, empty), /Missing text/);
});

test('translated markup stays text and embedded JSON cannot close its script element', () => {
  const edited = structuredClone(locales.en);
  const text = '</script><script>alert("translated")</script>';
  edited.runtime.samples[0].text = text;
  edited.page.hero_title_text = '<img src=x onerror=alert(1)>';
  const html = renderPage(template, edited, 'en');
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'));
  assert.ok(!html.includes(text));
  const runtime = JSON.parse(html.match(/id="locale-data" type="application\/json">([^]*?)<\/script>/)[1]);
  assert.equal(runtime.samples[0].text, text);
});
