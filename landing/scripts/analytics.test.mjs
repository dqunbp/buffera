import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { loadLocales, renderPage, languages } from './i18n.mjs';
import { loadDocs, renderDocs } from './docs.mjs';

const locales = await loadLocales();
const docs = await loadDocs();
const landingTemplate = await readFile(new URL('../src/index.html', import.meta.url), 'utf8');
const docsTemplate = await readFile(new URL('../src/docs.html', import.meta.url), 'utf8');

test('all localized routes include one counter; language redirects only include the noscript fallback', () => {
  for (const [lang, isRoot] of [...languages.map(lang => [lang, false]), ['en', true]]) {
    const pages = [renderPage(landingTemplate, locales[lang], lang, 'test', { isRoot })];
    for (const id of ['', ...docs[lang].articles.map(article => article.id)]) {
      pages.push(renderDocs(docsTemplate, locales[lang], docs[lang], lang, id, 'test', { isRoot }));
    }
    for (const html of pages) {
      assert.equal((html.match(/ym\(113828609, 'init'/g) || []).length, isRoot ? 0 : 1);
      assert.equal((html.match(/https:\/\/mc.yandex.ru\/watch\/113828609/g) || []).length, 1);
      assert.match(html, /<body[^>]*>\s*<!-- Yandex.Metrika counter -->/);
      assert.doesNotMatch(html, /\{\{analytics\}\}/);
    }
  }
});

test('counter loads asynchronously and queues the supplied configuration without waiting for Yandex', () => {
  const html = renderPage(landingTemplate, locales.en, 'en');
  const code = html.match(/<!-- Yandex.Metrika counter -->\s*<script[^>]*>([^]*?)<\/script>/)[1];
  const inserted = [];
  const anchor = { parentNode: { insertBefore: element => inserted.push(element) } };
  const window = {};
  const document = {
    scripts: [], referrer: 'https://example.com/',
    createElement: () => ({}), getElementsByTagName: () => [anchor],
  };
  const context = { window, document, location: { href: 'https://buffera.app/en/' } };
  Object.defineProperty(context, 'ym', { get: () => window.ym });
  runInNewContext(code, context);
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].async, 1);
  assert.equal(inserted[0].src, 'https://mc.yandex.ru/metrika/tag.js?id=113828609');
  const [id, command, options] = window.ym.a[0];
  assert.equal(id, 113828609);
  assert.equal(command, 'init');
  assert.deepEqual(JSON.parse(JSON.stringify(options)), {
    ssr: true, webvisor: true, clickmap: true, ecommerce: 'dataLayer',
    referrer: document.referrer, url: context.location.href, accurateTrackBounce: true, trackLinks: true,
  });
});
