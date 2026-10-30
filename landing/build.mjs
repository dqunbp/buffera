import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { languages, loadLocales, renderPage } from './scripts/i18n.mjs';
import { loadDocs, renderDocs } from './scripts/docs.mjs';

const source = new URL('./src/', import.meta.url);
const output = new URL('./dist/', import.meta.url);
const locales = await loadLocales();
const template = await readFile(new URL('index.html', source), 'utf8');
const docs = await loadDocs();
const docsTemplate = await readFile(new URL('docs.html', source), 'utf8');
const files = ['styles.css', 'app.js', 'docs.css', 'docs.js', 'favicon.svg', 'brand-pattern.svg', 'openai-mark.svg', ...languages.map(lang => `demo-${lang}.svg`), 'app-notes.png', 'app-safari.png', 'app-screenshot.png', 'app-terminal.png'];
const assetContents = await Promise.all(files.map(file => readFile(new URL(file, source))));
const assetVersion = createHash('sha256').update(Buffer.concat(assetContents)).digest('hex').slice(0, 12);

// Render every route before writing so incomplete translations fail the build.
const pages = [
  { path: 'index.html', html: renderPage(template, locales.en, 'en', assetVersion, { isRoot: true }) },
  ...languages.map(lang => ({
    path: `${lang}/index.html`, html: renderPage(template, locales[lang], lang, assetVersion),
  })),
];
for (const id of ['', ...docs.en.articles.map(article => article.id)]) {
  const route = `docs/${id ? `${id}/` : ''}`;
  pages.push({ path: `${route}index.html`, html: renderDocs(docsTemplate, locales.en, docs.en, 'en', id, assetVersion, { isRoot: true }) });
  for (const lang of languages) {
    pages.push({ path: `${lang}/${route}index.html`, html: renderDocs(docsTemplate, locales[lang], docs[lang], lang, id, assetVersion) });
  }
}
await Promise.all(pages.map(({ path }) => mkdir(new URL('./', new URL(path, output)), { recursive: true })));
await mkdir(new URL('og/', output), { recursive: true });
await Promise.all(files.map(file => copyFile(new URL(file, source), new URL(file, output))));
for (const lang of languages) {
  const card = await readFile(new URL(`og/${lang}.png`, source));
  if (card.toString('hex', 0, 8) !== '89504e470d0a1a0a' || card.readUInt32BE(16) !== 1200 || card.readUInt32BE(20) !== 630) {
    throw new Error(`Invalid OG card: ${lang}.png (expected 1200×630 PNG)`);
  }
  await writeFile(new URL(`og/${lang}.png`, output), card);
}
await Promise.all(pages.map(({ path, html }) => writeFile(new URL(path, output), html)));
console.log(`Built Buffera landing and documentation: ${pages.length} localized pages, automatic language routes and OG cards`);
