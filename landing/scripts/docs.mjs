import { readFile } from 'node:fs/promises';
import { languages, validateLocale, escapeHtml as e, renderPage } from './i18n.mjs';

const paths = {
  start: 'M5 12h14m-6-6 6 6-6 6',
  history: 'M6 3h12v18H6zM9 7h6M9 11h6M9 15h3',
  search: 'M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  ask: 'M4 4h16v12H9l-5 4zM8 8h8M8 12h4',
  privacy: 'M12 2 3 6v6c0 5 9 10 9 10s9-5 9-10V6zM8 12l3 3 5-6',
  keys: 'M2 5h20v14H2zM5 9h1m3 0h1m3 0h1m3 0h1M5 13h1m3 0h9',
  agents: 'M8 8 4 12l4 4m8-8 4 4-4 4m-3-11-2 14',
  help: 'M9 8a3 3 0 0 1 6 0c0 2-3 2-3 5m0 3v1M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name]}"/></svg>`;
export const docsUrl = (lang, id = '') => `/${lang}/docs/${id ? `${id}/` : ''}`;
const json = value => JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, char => `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`);
const plain = block => [block.text || '', ...(block.items || []), ...(block.headers || []), ...(block.rows || []).flat()].join(' ');

export async function loadDocs() {
  const docs = Object.fromEntries(await Promise.all(languages.map(async lang => [lang,
    JSON.parse(await readFile(new URL(`../src/locales/docs/${lang}.json`, import.meta.url), 'utf8')),
  ])));
  for (const lang of languages) {
    validateLocale(docs.ru, docs[lang], `docs.${lang}`);
    const used = new Set();
    for (const [index, article] of docs[lang].articles.entries()) {
      const reference = docs.ru.articles[index];
      if (!/^[a-z][a-z-]+$/.test(article.id) || used.has(article.id) || article.id !== reference.id || article.icon !== reference.icon || !paths[article.icon]) {
        throw new Error(`Invalid documentation identity: ${lang}.${article.id}`);
      }
      used.add(article.id);
      const sectionIds = new Set();
      article.sections.forEach((section, i) => {
        if (!/^[a-z][a-z-]+$/.test(section.id) || sectionIds.has(section.id) || section.id !== reference.sections[i].id) {
          throw new Error(`Invalid section identity: ${lang}.${article.id}.${section.id}`);
        }
        sectionIds.add(section.id);
        section.blocks.forEach((block, j) => {
          if (block.type !== reference.sections[i].blocks[j].type) throw new Error('Documentation block types differ');
          renderBlock(block, docs[lang].ui);
        });
      });
    }
  }
  return docs;
}

function renderBlock(block, ui) {
  switch (block.type) {
    case 'paragraph': return `<p>${e(block.text)}</p>`;
    case 'note': return `<aside class="docs-note">${icon('help')}<p>${e(block.text)}</p></aside>`;
    case 'steps': return `<ol class="docs-steps">${block.items.map(text => `<li>${e(text)}</li>`).join('')}</ol>`;
    case 'list': return `<ul>${block.items.map(text => `<li>${e(text)}</li>`).join('')}</ul>`;
    case 'code': return `<div class="docs-code"><div class="docs-code-bar"><span>JSON</span><button type="button" data-copy hidden>${e(ui.copy)}</button></div><pre tabindex="0"><code>${e(block.text)}</code></pre><p class="docs-copy-note" data-copy-feedback hidden>${e(ui.copyFailed)}</p></div>`;
    case 'table': return `<div class="docs-table"><table><thead><tr>${block.headers.map(text => `<th scope="col">${e(text)}</th>`).join('')}</tr></thead><tbody>${block.rows.map(row => `<tr>${row.map((text, i) => `<${i ? 'td' : 'th scope="row"'}>${i ? e(text) : `<code>${e(text)}</code>`}</${i ? 'td' : 'th'}>`).join('')}</tr>`).join('')}</tbody></table></div>`;
    default: throw new Error(`Unknown documentation block: ${block.type}`);
  }
}

function navigation(doc, lang, id) {
  const link = (url, text, current, symbol) => `<a href="${url}"${current ? ' aria-current="page"' : ''}>${icon(symbol)}<span>${e(text)}</span></a>`;
  return `<nav aria-label="${e(doc.ui.menu)}">${link(docsUrl(lang), doc.ui.overview, !id, 'history')}${[doc.articles.slice(0, 2), doc.articles.slice(2)].map((group, i) => `<p class="docs-nav-label">${e(i ? doc.ui.groupMore : doc.ui.groupBasics)}</p>${group.map(a => link(docsUrl(lang, a.id), a.title, id === a.id, a.icon)).join('')}`).join('')}</nav>`;
}

function overview(doc, lang) {
  const o = doc.overview;
  return `<header class="docs-intro"><p class="docs-eyebrow">Buffera / ${e(doc.ui.title)}</p><h1>${e(o.title).replace('\n', '<br>')}</h1><p class="docs-lead">${e(o.description)}</p></header>
  <section class="docs-welcome" aria-labelledby="welcome-title"><div class="docs-welcome-copy"><h2 id="welcome-title">${e(o.quickTitle).replace('\n', '<br>')}</h2><p>${e(o.quickText)}</p><a class="button button-dark" href="${docsUrl(lang, 'getting-started')}">${e(doc.ui.start)}<span aria-hidden="true">↗</span></a></div><div class="docs-key-art"><div class="docs-key-scene" aria-hidden="true"><span class="docs-floating-clip">${icon('history')}<i></i><i></i></span><div class="docs-keys"><kbd>⌘</kbd><kbd>⌥</kbd><kbd>V</kbd></div></div><p>${e(o.keyCaption)}</p><span>${e(o.keyNote)}</span><span class="visually-hidden">⌘⌥V</span></div></section>
  <section class="docs-guides" aria-labelledby="guides-title"><div class="docs-section-heading"><h2 id="guides-title">${e(doc.ui.allGuides)}</h2><p>${e(doc.ui.allGuidesText)}</p></div><div class="docs-guide-grid">${doc.articles.map(a => `<a class="docs-guide" href="${docsUrl(lang, a.id)}"><span class="docs-guide-icon">${icon(a.icon)}</span><div><h3>${e(a.title)}</h3><p>${e(a.description)}</p></div><span class="docs-guide-arrow" aria-hidden="true">↗</span></a>`).join('')}</div></section>`;
}

function articleContent(doc, article, lang) {
  const index = doc.articles.indexOf(article);
  return `<header class="docs-intro"><a class="docs-eyebrow" href="${docsUrl(lang)}">${e(doc.ui.title)}</a><h1>${e(article.title)}</h1><p class="docs-lead">${e(article.description)}</p>${article.id === 'getting-started' ? `<a class="button button-small button-dark docs-install-link" href="https://github.com/dqunbp/buffera/releases/latest/download/Buffera-macOS-arm64.dmg">${e(doc.ui.download)} <span aria-hidden="true">↗</span></a>` : ''}</header>
  <div class="docs-prose">${article.sections.map(section => `<section id="${section.id}"><h2><a href="#${section.id}">${e(section.title)}<span aria-hidden="true">#</span></a></h2>${section.blocks.map(block => renderBlock(block, doc.ui)).join('')}</section>`).join('')}</div>
  <nav class="docs-pagination" aria-label="${e(doc.ui.menu)}">${[doc.articles[index - 1], doc.articles[index + 1]].map((a, i) => a ? `<a href="${docsUrl(lang, a.id)}"><span>${e(i ? doc.ui.next : doc.ui.previous)}</span><strong>${e(a.title)}</strong></a>` : '<span></span>').join('')}</nav>`;
}

export function renderDocs(template, locale, doc, lang, id = '', assetVersion = 'local', { isRoot = false } = {}) {
  const article = id ? doc.articles.find(a => a.id === id) : null;
  if (id && !article) throw new Error(`Unknown documentation article: ${id}`);
  const section = article?.sections || [];
  const page = {
    ...locale.page,
    ...Object.fromEntries(Object.entries(doc.ui).map(([key, value]) => [`docs_${key}`, value])),
    html_content_2: article ? `${article.title} — Buffera` : doc.overview.metaTitle,
    html_content: article?.description || doc.overview.metaDescription,
    html_content_3: article?.description || doc.overview.metaDescription,
    docs_searchHint: doc.ui.searchHint,
  };
  const records = doc.articles.flatMap(a => a.sections.map(s => ({
    title: a.title, section: s.title, text: s.blocks.map(plain).join(' '), url: `${docsUrl(lang, a.id)}#${s.id}`,
  })));
  return renderPage(template, { ...locale, page }, lang, assetVersion, {
    isRoot, route: `docs/${id ? `${id}/` : ''}`,
    fragments: {
      docsLayout: article ? 'docs-article-layout' : 'docs-overview-layout',
      docsNavigation: navigation(doc, lang, id),
      docsContent: article ? articleContent(doc, article, lang) : overview(doc, lang),
      docsToc: section.length ? `<aside class="docs-toc"><nav aria-label="${e(doc.ui.toc)}"><p>${e(doc.ui.toc)}</p>${section.map(s => `<a href="#${s.id}">${e(s.title)}</a>`).join('')}</nav></aside>` : '',
      docsJson: json({ records, ui: doc.ui }),
    },
  });
}
