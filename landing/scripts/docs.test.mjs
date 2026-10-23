import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { loadLocales, siteOrigin, validateLocale } from './i18n.mjs';
import { loadDocs, renderDocs } from './docs.mjs';
const locales = await loadLocales();
const docs = await loadDocs();
const template = await readFile(new URL('../src/docs.html', import.meta.url), 'utf8');
const render = (lang, id = '', options) => renderDocs(template, locales[lang], docs[lang], lang, id, 'test', options);

test('guides have complete bilingual content, stable anchors and route-specific metadata', () => {
  for (const lang of ['ru', 'en']) for (const id of ['', ...docs[lang].articles.map(a => a.id)]) {
    const html = render(lang, id);
    const route = `docs/${id ? `${id}/` : ''}`;
    assert.ok(html.includes(`<link rel="canonical" href="${siteOrigin}/${lang}/${route}">`));
    for (const other of ['ru', 'en']) assert.ok(html.includes(`hreflang="${other}" href="${siteOrigin}/${other}/${route}"`));
    assert.ok(html.includes(`hreflang="x-default" href="${siteOrigin}/${route}"`));
    assert.doesNotMatch(html, /\{\{[\w.]+\}\}|language-redirect/);
    assert.ok(html.includes(`href="/${lang}/docs/${id ? `${id}/` : ''}" aria-current="page"`));
    if (lang === 'en') assert.doesNotMatch(html, /[А-Яа-яЁё]/);
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length);
    for (const [, anchor] of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.includes(anchor), `missing anchor ${anchor}`);
  }
});

test('neutral docs URLs select a language and retain the article, query and anchor', () => {
  for (const id of ['', 'privacy', 'agents']) {
    const route = `/docs/${id ? `${id}/` : ''}`;
    const script = render('en', id, { isRoot: true }).match(/id="language-redirect">([^]*?)<\/script>/)[1];
    for (const [preferences, expected] of [[['ru-RU'], 'ru'], [['de', 'en-GB'], 'en']]) {
      const calls = [];
      runInNewContext(script, { navigator: { languages: preferences }, location: { pathname: route, search: '?from=site', hash: '#secrets', replace: url => calls.push(url) } });
      assert.deepEqual(calls, [`/${expected}${route}?from=site#secrets`]);
    }
    const calls = [];
    runInNewContext(script, { navigator: { languages: ['ru'] }, location: { pathname: `/en${route}`, replace: url => calls.push(url) } });
    assert.deepEqual(calls, []);
  }
});

test('search targets resolve to real articles and sections', () => {
  for (const lang of ['ru', 'en']) {
    const data = JSON.parse(render(lang).match(/id="docs-data" type="application\/json">([^]*?)<\/script>/)[1]);
    assert.ok(data.records.length > 20);
    for (const record of data.records) {
      const url = new URL(record.url, siteOrigin);
      const article = docs[lang].articles.find(a => a.id === url.pathname.split('/')[3]);
      assert.ok(article.sections.some(s => `#${s.id}` === url.hash));
      assert.ok(record.text.trim());
    }
  }
});

test('translated documentation markup is inert and missing content fails validation', () => {
  const edited = structuredClone(docs.en);
  const hostile = '</script><img src=x onerror=alert(1)>';
  edited.articles[0].sections[0].blocks[0].text = hostile;
  const html = renderDocs(template, locales.en, edited, 'en', 'getting-started');
  assert.ok(!html.includes(hostile));
  assert.ok(html.includes('&lt;/script&gt;&lt;img'));
  const data = JSON.parse(html.match(/id="docs-data" type="application\/json">([^]*?)<\/script>/)[1]);
  assert.ok(data.records[0].text.includes(hostile));
  assert.throws(() => render('en', 'missing'), /Unknown documentation article/);
  delete edited.ui.copy;
  assert.throws(() => validateLocale(docs.ru, edited), /keys differ/);
});
