import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Run with a Node.js installation that provides sharp, or pass its package path:
// SHARP_MODULE=/absolute/path/to/node_modules/sharp node generate.mjs [locale]
const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const output = fileURLToPath(new URL('.', import.meta.url));
const copy = {
  ru: {
    lines: ['Хорошие', 'буфера.', 'Всё помнят.'],
    baseline: 225,
    lineHeight: 88,
    fontSize: 84,
    descriptionY: 466,
    description: 'История буфера обмена для Mac',
    note: 'Поиск по смыслу · Всё на твоём Mac',
  },
  en: {
    lines: ['Nice buffers.', 'Great memory.'],
    baseline: 270,
    lineHeight: 90,
    fontSize: 76,
    descriptionY: 430,
    description: 'Clipboard history for Mac',
    note: 'Search by meaning · Everything stays on your Mac',
  },
  es: {
    lines: ['Buenos búferes.', 'Gran memoria.'], baseline: 270, lineHeight: 90, fontSize: 66, descriptionY: 430,
    description: 'Historial del portapapeles para Mac',
    note: 'Búsqueda por significado · Todo se queda en tu Mac',
  },
  de: {
    lines: ['Schöne Puffer.', 'Starkes Gedächtnis.'], baseline: 270, lineHeight: 90, fontSize: 62, descriptionY: 430,
    description: 'Zwischenablageverlauf für den Mac',
    note: 'Suche nach Bedeutung · Alles bleibt auf deinem Mac',
  },
  fr: {
    lines: ['Jolies formes.', 'Bonne mémoire.'], baseline: 270, lineHeight: 90, fontSize: 76, descriptionY: 430,
    description: 'Historique du presse-papiers pour Mac',
    note: 'Recherche par sens · Tout reste sur votre Mac',
  },
  'pt-BR': {
    lines: ['Belos buffers.', 'Ótima memória.'], baseline: 270, lineHeight: 90, fontSize: 76, descriptionY: 430,
    description: 'Histórico da área de transferência para Mac',
    note: 'Busca pelo significado · Tudo fica no seu Mac',
  },
  'zh-Hans': {
    lines: ['好看的剪贴板。', '好用的记忆。'], baseline: 270, lineHeight: 90, fontSize: 76, descriptionY: 430,
    description: 'Mac 剪贴板历史记录',
    note: '按含义搜索 · 一切留在你的 Mac 上',
  },
  ja: {
    lines: ['いいバッファ。', 'いい記憶。'], baseline: 270, lineHeight: 90, fontSize: 76, descriptionY: 430,
    description: 'Mac のクリップボード履歴',
    note: '意味で検索 · すべて Mac の中に',
  },
};

function form(x, y, rotation, gradient) {
  return `<g transform="translate(${x} ${y}) rotate(${rotation} 115 28)">
    <path d="M0 125C0 48 43 0 111 0C187 0 230 49 230 125C230 204 185 290 113 290C42 290 0 207 0 125Z" fill="url(#${gradient})" filter="url(#formShadow)"/>
    <path d="M0 125C0 48 43 0 111 0C187 0 230 49 230 125C230 204 185 290 113 290C42 290 0 207 0 125Z" fill="none" stroke="url(#rim)" stroke-width="2"/>
    <ellipse cx="84" cy="52" rx="48" ry="18" transform="rotate(-25 84 52)" fill="#fff4ff" opacity=".36" filter="url(#shine)"/>
    <path d="M31 214C64 280 155 295 207 217" fill="none" stroke="#5f327a" stroke-width="2" opacity=".13"/>
  </g>`;
}

const selectedLocale = process.argv[2];
if (selectedLocale && !Object.hasOwn(copy, selectedLocale)) {
  throw new Error(`Unsupported locale: ${selectedLocale}`);
}
for (const [locale, text] of Object.entries(copy)) {
  if (selectedLocale && selectedLocale !== locale) continue;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <radialGradient id="left" cx="30%" cy="12%" r="100%">
      <stop offset="0" stop-color="#ead7ff"/><stop offset=".21" stop-color="#cfaff7"/><stop offset=".44" stop-color="#b486ea"/><stop offset=".66" stop-color="#9565d3"/><stop offset=".89" stop-color="#7443a8"/><stop offset="1" stop-color="#61358d"/>
    </radialGradient>
    <radialGradient id="right" cx="40%" cy="14%" r="100%">
      <stop offset="0" stop-color="#e6d0ff"/><stop offset=".24" stop-color="#c9a2f2"/><stop offset=".49" stop-color="#ac80df"/><stop offset=".72" stop-color="#8c5ac5"/><stop offset="1" stop-color="#653b94"/>
    </radialGradient>
    <linearGradient id="rim" x2=".5" y2="1"><stop stop-color="#fff" stop-opacity=".4"/><stop offset="1" stop-color="#61358d" stop-opacity=".05"/></linearGradient>
    <filter id="formShadow" x="-40%" y="-30%" width="180%" height="180%"><feDropShadow dx="0" dy="14" stdDeviation="10" flood-color="#50276b" flood-opacity=".24"/></filter>
    <filter id="shadow" x="-50%" y="-100%" width="200%" height="300%"><feGaussianBlur stdDeviation="18"/></filter>
    <filter id="shine" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="14"/></filter>
    <filter id="chipShadow" x="-50%" y="-70%" width="200%" height="240%"><feDropShadow dx="0" dy="9" stdDeviation="10" flood-color="#50276b" flood-opacity=".1"/></filter>
  </defs>
  <rect width="1200" height="630" fill="#eee9f8"/>
  <g fill="#321f43" font-family="Helvetica Neue,Arial,sans-serif">
    <g transform="translate(67 63)"><path d="M7 6C1 26 15 34 20 17C25 34 39 26 33 6" transform="scale(1.25)" fill="none" stroke="#321f43" stroke-width="3" stroke-linecap="round"/><text x="65" y="35" font-size="43" font-weight="700" letter-spacing="-2">buffera</text></g>
    <text x="67" y="${text.baseline}" font-size="${text.fontSize}" font-weight="700" letter-spacing="-3.5">${text.lines.map((line, i) => `<tspan x="67" dy="${i ? text.lineHeight : 0}">${line}</tspan>`).join('')}</text>
    <text x="70" y="${text.descriptionY}" fill="#665170" font-size="29" letter-spacing="-.5">${text.description}</text>
    <circle cx="76" cy="568" r="5" fill="#8658ad"/>
    <text x="94" y="575" fill="#665170" font-size="22">${text.note}</text>
  </g>
  <ellipse cx="932" cy="505" rx="192" ry="20" fill="#785a92" opacity=".28" filter="url(#shadow)"/>
  ${form(917, 185, -12, 'right')}
  ${form(755, 185, 12, 'left')}
  <g transform="translate(742 155) rotate(-11)" filter="url(#chipShadow)"><rect width="91" height="62" rx="16" fill="#faf7ff"/><text x="45.5" y="42" text-anchor="middle" font-family="Helvetica Neue,Arial,sans-serif" font-size="31" fill="#321f43">⌘ C</text></g>
  <g transform="translate(1051 451) rotate(-9)" filter="url(#chipShadow)"><rect width="80" height="58" rx="16" fill="#e7f7a5"/><path d="m27 30 10 10 18-24" fill="none" stroke="#321f43" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></g>
</svg>`;
  await writeFile(`${output}${locale}.svg`, svg);
  await sharp(Buffer.from(svg)).png().toFile(`${output}${locale}.png`);
}
