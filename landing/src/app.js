'use strict';

// Only synthetic examples. This demo never reads or writes the visitor's clipboard.
const messages = JSON.parse(document.querySelector('#locale-data').textContent);
const { samples, kindLabels, ui } = messages;
const locale = document.documentElement.lang;
const touchIdle = document.querySelector('#touch-label').textContent;
const formatMessage = (message, values) => message.replace(/\{(\w+)\}/g, (_, key) => values[key]);
const demo = document.querySelector('.demo-window');
const search = document.querySelector('#demo-search');
const semanticSearch = document.querySelector('#demo-semantic');
const askButton = demo.querySelector('[data-command="ask"]');
const list = document.querySelector('#demo-items');
const count = document.querySelector('#demo-count');
const detail = document.querySelector('#demo-detail');
const detailNote = detail.querySelector('.detail-note');
const previewNote = detailNote.textContent;
const settings = document.querySelector('.demo-settings');
const dateFilter = document.querySelector('#demo-date');
const toast = document.querySelector('.demo-toast');
const paths = {
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>',
  search: '<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',
  reset: '<path d="M4 9a8 8 0 1 1 0 7M4 3v6h6"/>',
  filters: '<path d="M3 6h4m4 0h10M3 12h10m4 0h4M3 18h4m4 0h10"/><circle cx="9" cy="6" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="9" cy="18" r="2"/>',
  settings: '<path d="m9 3-.6 3-2 .9L3.8 6 2 9l2.2 2v2L2 15l1.8 3 2.6-.9 2 .9.6 3h6l.6-3 2-.9 2.6.9 1.8-3-2.2-2v-2L22 9l-1.8-3-2.6.9-2-.9L15 3Z"/><circle cx="12" cy="12" r="3"/>',
  pin: '<path d="m15 3 6 6-3 1-4 4v4l-3-3-7 7 7-7-5-5h4l4-4Z"/>',
  history: '<path d="M3 10a9 9 0 1 1 1 7M3 4v6h6m3-4v6l4 2"/>',
  star: '<path d="m12 3 2.8 5.8 6.4.9-4.6 4.5 1.1 6.3-5.7-3-5.7 3 1.1-6.3-4.6-4.5 6.4-.9Z"/>',
  all: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  text: '<path d="M5 5h14M12 5v14m-4 0h8"/>',
  link: '<path d="m10 8 3-3a4 4 0 0 1 6 6l-3 3m-2 2-3 3a4 4 0 0 1-6-6l3-3m0 6 8-8"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8" cy="9" r="1"/><path d="m3 17 6-5 4 4 4-7 4 6"/>',
  file: '<path d="M6 3h8l4 4v14H6Zm8 0v5h4"/>',
  data: '<path d="m8 5-6 7 6 7m8-14 6 7-6 7M14 3l-4 18"/>',
  remote: '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
  concealed: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 2v6m10-6v6M3 10h18"/>',
  app: '<rect x="3" y="3" width="18" height="18" rx="4"/><path d="M8 16 12 7l4 9m-7-3h6"/>',
  conceal: '<path d="m3 3 18 18M9 5c6-2 11 6 12 7l-4 4M6 6l-5 6s8 11 16 6"/>',
  reveal: '<path d="M1 12s11-16 22 0c-11 16-22 0-22 0Z"/><circle cx="12" cy="12" r="3"/>',
  preview: '<path d="M9 3H3v6m12-6h6v6M3 15v6h6m12-6v6h-6"/>',
  copyAs: '<path d="M4 5h14M10 5v14m-4 0h7m2-5 3 3 4-6"/>',
  copy: '<rect x="5" y="5" width="14" height="16" rx="2"/><rect x="9" y="2" width="6" height="5" rx="1"/>',
  finder: '<path d="M2 7V4h8l3 3h9v13H2Z"/>',
  save: '<path d="M12 2v12m-5-5 5 5 5-5M3 14v7h18v-7"/>',
};
function icon(name) {
  const element = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  element.setAttribute('viewBox', '0 0 24 24');
  element.setAttribute('aria-hidden', 'true');
  element.innerHTML = paths[name] || paths.app; // Static, trusted path definitions only.
  return element;
}
function button(label, iconName, handler, className = 'demo-icon-button') {
  const element = document.createElement('button');
  element.type = 'button'; element.className = className;
  element.setAttribute('aria-label', label); element.title = label;
  element.append(icon(iconName));
  element.addEventListener('click', handler);
  return element;
}
for (const element of demo.querySelectorAll('[data-icon]')) {
  element.append(icon(element.dataset.icon));
  if (element.hasAttribute('aria-label')) element.title = element.getAttribute('aria-label');
}
let filter = 'all', source = 'all', scope = 'history', nearbyID = null;
let visible = [], selection = 0, lastOpened = null, toastTimer;
function notify(message) {
  clearTimeout(toastTimer); toast.textContent = message; toast.hidden = false;
  toastTimer = setTimeout(() => { toast.hidden = true; }, 4500);
}
function screenshot() {
  const image = document.createElement('img');
  image.src = new URL(`../demo-${locale}.svg`, location.href).href;
  image.alt = ui.imageAlt; image.width = 640; image.height = 310;
  return image;
}
function renderSidebar() {
  const focusedFilter = document.activeElement?.dataset.filter;
  const focusedSource = document.activeElement?.dataset.source;
  const kinds = document.querySelector('#demo-kinds'); kinds.replaceChildren();
  const heading = document.createElement('div'); heading.className = 'demo-sidebar-heading'; heading.textContent = ui.contentType; kinds.append(heading);
  for (const [value, title] of Object.entries(ui.types)) {
    const row = button(title, value, () => { filter = value; nearbyID = null; renderDemo(); }, 'demo-sidebar-row');
    row.append(document.createTextNode(title)); row.dataset.filter = value;
    row.setAttribute('aria-pressed', String(filter === value)); kinds.append(row);
  }
  const sources = document.querySelector('#demo-sources'); sources.replaceChildren();
  for (const value of ['all', ...new Set(samples.map(item => item.source))]) {
    const label = value === 'all' ? ui.allApps : value;
    const row = button(label, value === 'all' ? 'all' : 'app', () => { source = value; nearbyID = null; renderDemo(); }, 'demo-sidebar-row');
    const sourceIcon = samples.find(item => item.source === value)?.sourceIcon;
    if (sourceIcon) {
      const image = document.createElement('img');
      image.src = new URL(`../app-${sourceIcon}.png`, location.href).href;
      image.alt = ''; image.width = 16; image.height = 16;
      image.className = 'demo-app-icon';
      image.addEventListener('error', () => image.replaceWith(icon('app')), { once: true });
      row.replaceChildren(image);
    }
    row.dataset.source = value; row.append(document.createTextNode(label)); row.setAttribute('aria-pressed', String(source === value)); sources.append(row);
  }
  if (focusedFilter) [...kinds.querySelectorAll('button')].find(row => row.dataset.filter === focusedFilter)?.focus({ preventScroll: true });
  if (focusedSource) [...sources.querySelectorAll('button')].find(row => row.dataset.source === focusedSource)?.focus({ preventScroll: true });
}
function toggleFavorite(item) {
  item.favorite = !item.favorite;
  const previous = item.id; renderDemo();
  const row = [...list.children].find(row => row.dataset.id === previous);
  row?.querySelector('[data-action="favorite"]')?.focus({ preventScroll: true });
}
function runAction(action, item, trigger) {
  if (action === 'favorite') { toggleFavorite(item); return; }
  if (action === 'preview') { openDetail(item, trigger); return; }
  if (action === 'conceal') { item.concealed = !item.concealed; renderDemo(); return; }
  if (action === 'nearby') { nearbyID = item.id; renderDemo(); notify(ui.nearbyNotice); return; }
  notify(ui[`${action}Notice`]);
}
function renderDemo() {
  const query = search.value.trim().toLocaleLowerCase(locale);
  const nearbyIndex = samples.findIndex(item => item.id === nearbyID);
  visible = samples.filter((item, index) => {
    if (nearbyID) return Math.abs(index - nearbyIndex) <= 1;
    const matchesKind = filter === 'all' || (filter === 'concealed' ? item.concealed : item.kind === filter);
    // Curated topics illustrate semantic matching; no model runs on the landing page.
    const searchable = item.concealed ? item.source
      : `${item.text} ${item.source} ${semanticSearch.checked ? item.keywords : ''}`;
    return matchesKind && (source === 'all' || item.source === source) && (scope !== 'favorite' || item.favorite)
      && dateFilter.value !== 'yesterday' && searchable.toLocaleLowerCase(locale).includes(query);
  });
  selection = 0; list.replaceChildren();
  if (!visible.length) {
    const empty = document.createElement('p'); empty.className = 'demo-empty'; empty.textContent = messages.empty; list.append(empty);
  }
  visible.forEach((item, index) => {
    const card = document.createElement('article'); card.className = `demo-item${index === selection ? ' selected' : ''}${item.kind === 'image' ? ' image-card' : ''}`;
    card.tabIndex = 0; card.dataset.id = item.id; card.setAttribute('aria-label', item.concealed ? ui.hidden : item.title);
    const content = document.createElement('div'); content.className = 'item-content';
    if (item.kind === 'image') content.append(screenshot());
    else {
      content.append(icon(item.concealed ? 'concealed' : item.kind));
      const text = document.createElement('p'); text.textContent = item.concealed ? ui.hidden : item.text; content.append(text);
    }
    const key = document.createElement('span'); key.className = 'item-key'; key.textContent = `⌘${index + 1}`; content.append(key);
    const footer = document.createElement('div'); footer.className = 'item-footer';
    if (item.kind === 'image') {
      const type = document.createElement('span'); type.className = 'item-type';
      type.title = kindLabels.image; type.setAttribute('role', 'img'); type.setAttribute('aria-label', kindLabels.image);
      type.append(icon('image')); content.append(type);
    }
    const meta = document.createElement('span'); meta.className = 'item-meta';
    meta.textContent = `${item.source} · ${item.time}`; meta.title = meta.textContent;
    const actions = document.createElement('div'); actions.className = 'item-actions';
    const actionNames = item.kind === 'image' ? ['favorite', 'nearby', 'finder', 'save', 'preview', 'copyAs', 'copy'] : ['favorite', 'nearby', 'conceal', 'preview', 'copyAs', 'copy'];
    for (const action of actionNames) {
      const label = action === 'favorite' ? ui[item.favorite ? 'removeFavorite' : 'addFavorite'] : action === 'conceal' ? ui[item.concealed ? 'reveal' : 'conceal'] : ui[action];
      const symbol = action === 'favorite' ? 'star' : action === 'nearby' ? 'history' : action === 'conceal' && item.concealed ? 'reveal' : action;
      const control = button(label, symbol, event => { event.stopPropagation(); select(index); runAction(action, item, event.currentTarget); });
      control.dataset.action = action;
      if (action === 'favorite') control.setAttribute('aria-pressed', String(item.favorite));
      actions.append(control);
    }
    footer.append(meta, actions); card.append(content, footer);
    card.addEventListener('click', () => { select(index); card.focus({ preventScroll: true }); });
    card.addEventListener('dblclick', event => { if (!event.target.closest('button')) notify(ui.copyNotice); });
    card.addEventListener('focus', () => select(index)); list.append(card);
  });
  count.textContent = formatMessage(ui.records, { visible: visible.length });
  demo.querySelector('[data-command="reset"]').hidden = !query && filter === 'all' && source === 'all' && scope === 'history' && dateFilter.value === 'all' && !nearbyID;
  demo.querySelector('.demo-scopes').hidden = Boolean(nearbyID);
  demo.querySelector('.demo-nearby-back').hidden = !nearbyID;
  demo.querySelectorAll('[data-scope]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.scope === scope)));
  renderSidebar();
}
function select(index) {
  selection = index;
  [...list.querySelectorAll('.demo-item')].forEach((element, i) => element.classList.toggle('selected', i === index));
}
function openDetail(item, trigger) {
  detail.classList.remove('demo-chat');
  detail.querySelector('.detail-kind').textContent = `${kindLabels[item.kind]} · ${item.source}`;
  detail.querySelector('h3').textContent = item.concealed ? ui.hidden : item.title;
  const content = detail.querySelector('.detail-content'); content.replaceChildren();
  if (item.kind === 'image') content.append(screenshot());
  else content.textContent = item.concealed ? ui.hidden : item.text;
  detailNote.textContent = previewNote;
  showDetail(trigger);
}
function openAskDemo() {
  detail.classList.add('demo-chat');
  detail.querySelector('.detail-kind').textContent = ui.askExample;
  const title = detail.querySelector('h3');
  title.replaceChildren(askButton.querySelector('svg').cloneNode(true), document.createTextNode(askButton.getAttribute('aria-label')));
  const content = detail.querySelector('.detail-content'); content.replaceChildren();
  const context = document.createElement('p'); context.className = 'demo-chat-context';
  context.textContent = ui.askContext;
  const question = document.createElement('p'); question.className = 'demo-chat-question';
  question.textContent = ui.askQuestion;
  const answer = document.createElement('div'); answer.className = 'demo-chat-answer';
  const identity = document.createElement('strong'); identity.className = 'demo-chat-identity';
  identity.append(askButton.querySelector('svg').cloneNode(true), document.createTextNode('Buffera'));
  const answerText = document.createElement('p');
  const entry = samples.find(item => item.id === 'image' && !item.concealed);
  answerText.textContent = entry
    ? formatMessage(ui.askAnswer, { name: ui.imageName, address: ui.imageAddress }) : ui.hidden;
  answer.append(identity, answerText);
  content.append(context, question, answer);
  if (entry) {
    const sourceLabel = document.createElement('span'); sourceLabel.className = 'demo-chat-source-label';
    sourceLabel.textContent = ui.askSourceLabel;
    const source = button(ui.askOpenSource, 'history', () => openDetail(entry, askButton), 'demo-chat-source');
    const sourceText = document.createElement('span');
    const sourceTitle = document.createElement('strong'); sourceTitle.textContent = entry.title;
    const metadata = document.createElement('small'); metadata.textContent = `${entry.source} · ${entry.time}`;
    const openLabel = document.createElement('span'); openLabel.textContent = ui.askOpenSource;
    sourceText.append(sourceTitle, metadata, openLabel); source.append(sourceText);
    answer.append(sourceLabel, source);
  }
  detailNote.textContent = ui.askNote;
  showDetail(askButton);
}
function showDetail(trigger) {
  closeSettings(); toast.hidden = true; lastOpened = trigger;
  detail.hidden = false; demo.querySelector('.demo-controls').inert = true;
  detail.querySelector('button').focus({ preventScroll: true });
}
function closeDetail() {
  detail.hidden = true; demo.querySelector('.demo-controls').inert = false;
  if (lastOpened?.isConnected) lastOpened.focus({ preventScroll: true });
}
function closeSettings() {
  settings.hidden = true; demo.querySelector('[data-command="settings"]').setAttribute('aria-expanded', 'false');
}
function toggleSidebar() {
  demo.classList.remove('filters-open');
  const collapsed = demo.classList.toggle('sidebar-collapsed');
  demo.querySelector('[data-command="sidebar"]').setAttribute('aria-expanded', String(!collapsed));
  demo.querySelector('[data-command="filters"]').setAttribute('aria-expanded', 'false');
  closeSettings();
}
if (matchMedia('(max-width: 600px)').matches) toggleSidebar();

search.addEventListener('input', () => { nearbyID = null; renderDemo(); });
semanticSearch.addEventListener('change', () => { nearbyID = null; renderDemo(); });
askButton.addEventListener('click', openAskDemo);
dateFilter.addEventListener('change', () => { nearbyID = null; renderDemo(); });
demo.querySelectorAll('[data-scope]').forEach(button => button.addEventListener('click', () => { scope = button.dataset.scope; renderDemo(); }));
demo.querySelector('.demo-nearby-back').addEventListener('click', () => { nearbyID = null; renderDemo(); });
demo.querySelector('[data-command="reset"]').addEventListener('click', () => {
  filter = source = 'all'; scope = 'history'; nearbyID = null; search.value = ''; dateFilter.value = 'all'; renderDemo(); search.focus({ preventScroll: true });
});
demo.querySelector('[data-command="sidebar"]').addEventListener('click', toggleSidebar);
demo.querySelector('[data-command="filters"]').addEventListener('click', event => {
  closeSettings();
  const open = demo.classList.toggle('filters-open');
  event.currentTarget.setAttribute('aria-expanded', String(open));
});
demo.querySelector('[data-command="pin"]').addEventListener('click', event => {
  const button = event.currentTarget, pinned = button.getAttribute('aria-pressed') !== 'true';
  button.setAttribute('aria-pressed', String(pinned)); button.setAttribute('aria-label', ui[pinned ? 'unpin' : 'pin']); button.title = ui[pinned ? 'unpin' : 'pin']; notify(ui[pinned ? 'pinNotice' : 'unpinNotice']);
});
demo.querySelector('[data-command="settings"]').addEventListener('click', event => {
  demo.classList.remove('filters-open'); demo.querySelector('[data-command="filters"]').setAttribute('aria-expanded', 'false');
  settings.hidden = !settings.hidden; event.currentTarget.setAttribute('aria-expanded', String(!settings.hidden));
  if (!settings.hidden) document.querySelector('#demo-theme').focus({ preventScroll: true });
});
document.querySelector('#demo-theme').addEventListener('change', event => { demo.dataset.theme = event.target.value; });
document.addEventListener('click', event => {
  if (!settings.hidden && !settings.contains(event.target) && !event.target.closest('[data-command="settings"]')) closeSettings();
});
detail.querySelector('button').addEventListener('click', closeDetail);
demo.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    if (!detail.hidden) closeDetail();
    else if (!settings.hidden) { closeSettings(); demo.querySelector('[data-command="settings"]').focus(); }
    else if (nearbyID) { nearbyID = null; renderDemo(); }
    demo.classList.remove('filters-open'); demo.querySelector('[data-command="filters"]').setAttribute('aria-expanded', 'false');
    toast.hidden = true; event.preventDefault(); return;
  }
  if (!detail.hidden) {
    if (event.key === 'Tab') {
      const controls = [...detail.querySelectorAll('button:not([disabled])')];
      const current = controls.indexOf(document.activeElement);
      const next = (current + (event.shiftKey ? -1 : 1) + controls.length) % controls.length;
      event.preventDefault(); controls[next].focus();
    }
    return;
  }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') { event.preventDefault(); closeSettings(); search.focus({ preventScroll: true }); search.select(); return; }
  if (!settings.hidden || event.target.closest('select,button,input[type="checkbox"]')) return;
  const rows = [...list.querySelectorAll('.demo-item')];
  if (['ArrowDown', 'ArrowUp'].includes(event.key) && rows.length) {
    event.preventDefault(); select(document.activeElement === search ? 0 : (selection + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length);
    rows[selection].focus({ preventScroll: true }); rows[selection].scrollIntoView({ block: 'nearest', behavior: 'instant' });
  }
  if ((event.metaKey || event.ctrlKey) && event.key === '0') { event.preventDefault(); demo.querySelector('[data-command="reset"]').click(); return; }
  if (!rows.length) return;
  if ((event.metaKey || event.ctrlKey) && /^[1-9]$/.test(event.key)) {
    event.preventDefault(); const index = Number(event.key) - 1;
    if (rows[index]) { select(index); rows[index].focus({ preventScroll: true }); notify(ui.copyNotice); }
  }
  if (event.key === 'Enter') { event.preventDefault(); notify(ui.copyNotice); }
  if (event.key === ' ' && event.target !== search) { event.preventDefault(); openDetail(visible[selection], rows[selection]); }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'd') { event.preventDefault(); toggleFavorite(visible[selection]); }
});
renderDemo();

// Spring integration only runs while moving and while the sculpture is in view.
const sculpture = document.querySelector('#sculpture');
const forms = [...sculpture.querySelectorAll('.soft-form')];
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const bodies = forms.map(() => ({ x: 0, y: 0, vx: 0, vy: 0 }));
let target = { x: 0, y: 0 };
let frame = 0;
let lastTime = 0;
let inView = true;
let labelTimer;
let squeezeCount = 0;

function stopSpring() {
  if (frame) cancelAnimationFrame(frame);
  frame = 0;
  lastTime = 0;
  bodies.forEach(body => Object.assign(body, { x: 0, y: 0, vx: 0, vy: 0 }));
  forms.forEach(form => form.style.removeProperty('transform'));
}

function animate(time) {
  const dt = Math.min((time - (lastTime || time - 16.67)) / 1000, .032);
  lastTime = time;
  let moving = false;
  bodies.forEach((body, index) => {
    const response = index ? .78 : 1;
    body.vx += ((target.x * response - body.x) * 155 - body.vx * 10.5) * dt;
    body.vy += ((target.y * response - body.y) * 155 - body.vy * 10.5) * dt;
    body.x += body.vx * dt;
    body.y += body.vy * dt;
    const stretch = Math.max(-.08, Math.min(.08, body.vy * .00035));
    forms[index].style.transform = `translate3d(${body.x.toFixed(2)}px,${body.y.toFixed(2)}px,0) rotate(${(body.x * .15).toFixed(2)}deg) scale(${(1 - stretch).toFixed(4)},${(1 + stretch).toFixed(4)})`;
    moving ||= Math.abs(body.vx) + Math.abs(body.vy) > .3 || Math.abs(body.x - target.x * response) + Math.abs(body.y - target.y * response) > .05;
  });
  if (moving && inView && !document.hidden && !reduceMotion.matches) frame = requestAnimationFrame(animate);
  else { frame = 0; lastTime = 0; }
}

function wakeSpring() {
  if (!frame && !reduceMotion.matches && inView && !document.hidden) frame = requestAnimationFrame(animate);
}

sculpture.addEventListener('pointermove', event => {
  if (event.pointerType === 'touch') return;
  const rect = sculpture.getBoundingClientRect();
  target = { x: ((event.clientX - rect.left) / rect.width - .5) * 28, y: ((event.clientY - rect.top) / rect.height - .5) * 24 };
  wakeSpring();
});
sculpture.addEventListener('pointerleave', () => {
  target = { x: 0, y: 0 };
  wakeSpring();
});
sculpture.addEventListener('click', () => {
  bodies.forEach((body, index) => { body.vy += index ? 300 : 385; body.vx += index ? 100 : -100; });
  if (squeezeCount < 3) {
    squeezeCount += 1;
    const label = document.querySelector('#touch-label');
    clearTimeout(labelTimer);
    if (squeezeCount === 3) {
      const { firstLine, secondLine } = messages.touchCta;
      label.textContent = `${firstLine} ${secondLine}`;
      label.closest('.touch-caption').classList.add('is-played');
      document.querySelector('#install-title').replaceChildren(
        document.createTextNode(firstLine), document.createElement('br'), document.createTextNode(secondLine),
      );
    } else {
      label.textContent = messages.touchActive;
      labelTimer = setTimeout(() => { label.textContent = touchIdle; }, 2400);
    }
  }
  wakeSpring();
});
reduceMotion.addEventListener('change', stopSpring);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { target = { x: 0, y: 0 }; stopSpring(); }
});
new IntersectionObserver(([entry]) => {
  inView = entry.isIntersecting;
  if (!inView) { target = { x: 0, y: 0 }; stopSpring(); }
}, { threshold: .05 }).observe(sculpture);
// A single small arrival bounce; there is no continuous idle animation.
if (!reduceMotion.matches) { bodies[0].y = -16; bodies[1].y = -11; wakeSpring(); }
