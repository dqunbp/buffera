'use strict';

// The demo is deliberately self-contained: no access to the visitor's clipboard or history.
const samples = [
  { id: 'idea', kind: 'text', title: 'Хорошая идея не должна теряться.', source: 'Заметки', time: 'только что', favorite: true, text: 'Хорошая идея не должна теряться.\n\nСначала придумать. Потом скопировать. А когда понадобится — найти в Buffera.', keywords: 'идея дизайн текст память' },
  { id: 'link', kind: 'link', title: 'Та самая статья про хороший дизайн', source: 'Safari', time: '2 минуты назад', favorite: false, text: 'https://example.com/design?utm_source=newsletter\n\nВ приложении действие «Убрать метки из ссылки» удалит рекламную метку. Это демонстрационная ссылка.', keywords: 'статья дизайн ссылка сайт' },
  { id: 'image', kind: 'image', title: 'Скриншот с адресом любимого места', source: 'Снимок экрана', time: '12 минут назад', favorite: false, text: 'Текст внутри демонстрационного скриншота:\n\nКофейня «Пауза»\nУлица Примеров, 12\nКаждый день, 09:00–21:00\n\nЭто вымышленный пример распознанного текста.', keywords: 'кофе кофейня адрес картинка скриншот пауза улица примеров' },
  { id: 'json', kind: 'text', title: '{"idea":"сохранить","status":"готово"}', source: 'Terminal', time: '24 минуты назад', favorite: true, text: '{\n  "idea": "сохранить",\n  "status": "готово"\n}\n\nВ Buffera корректный JSON можно отформатировать перед копированием.', keywords: 'json код форматирование текст terminal' },
];
const kindLabels = { text: 'Текст', link: 'Ссылка', image: 'Картинка · OCR' };
const kindIcons = { text: 'T', link: '↗', image: '▧' };
const search = document.querySelector('#demo-search');
const list = document.querySelector('#demo-items');
const count = document.querySelector('#demo-count');
const detail = document.querySelector('#demo-detail');
const filters = [...document.querySelectorAll('[data-filter]')];
let filter = 'all';
let visible = samples;
let selection = 0;
let lastOpened = null;

function renderDemo() {
  const query = search.value.trim().toLocaleLowerCase('ru');
  visible = samples.filter(item => {
    const matchesFilter = filter === 'all' || (filter === 'favorite' ? item.favorite : item.kind === filter);
    return matchesFilter && `${item.title} ${item.text} ${item.source} ${item.keywords}`.toLocaleLowerCase('ru').includes(query);
  });
  selection = 0;
  list.replaceChildren();
  if (!visible.length) {
    const empty = document.createElement('p');
    empty.className = 'demo-empty';
    empty.textContent = 'Здесь пока ничего. Попробуй «дизайн», «адрес» или сбрось фильтр.';
    list.append(empty);
  }
  visible.forEach((item, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `demo-item${index === selection ? ' selected' : ''}`;
    button.dataset.id = item.id;
    button.setAttribute('aria-label', `Посмотреть: ${item.title}`);
    const icon = document.createElement('span');
    icon.className = `item-icon ${item.kind}`;
    icon.setAttribute('aria-hidden', 'true');
    icon.textContent = kindIcons[item.kind];
    const content = document.createElement('span');
    content.className = 'item-content';
    const title = document.createElement('span');
    title.className = 'item-title';
    title.textContent = item.title;
    const meta = document.createElement('span');
    meta.className = 'item-meta';
    for (const value of [item.source, item.time]) {
      const text = document.createElement('span');
      text.textContent = value;
      meta.append(text);
    }
    content.append(title, meta);
    button.append(icon, content);
    if (item.favorite) {
      const star = document.createElement('span');
      star.className = 'item-favorite';
      star.textContent = '☆';
      star.setAttribute('aria-label', 'В избранном');
      button.append(star);
    }
    const key = document.createElement('span');
    key.className = 'item-key';
    key.textContent = '↵';
    key.setAttribute('aria-hidden', 'true');
    button.append(key);
    button.addEventListener('click', () => openDetail(item, button));
    button.addEventListener('focus', () => select(index));
    list.append(button);
  });
  count.textContent = `${visible.length} из ${samples.length} примеров · твои данные не используются`;
}

function select(index) {
  selection = index;
  [...list.querySelectorAll('.demo-item')].forEach((element, i) => element.classList.toggle('selected', i === index));
}

function openDetail(item, trigger) {
  lastOpened = trigger;
  detail.querySelector('.detail-kind').textContent = `${kindLabels[item.kind]} · ${item.source}`;
  detail.querySelector('h3').textContent = item.title;
  detail.querySelector('p').textContent = item.text;
  detail.hidden = false;
  // The detail replaces the demo controls visually and in keyboard navigation.
  for (const element of document.querySelectorAll('.demo-search, .demo-filters, .demo-items')) element.inert = true;
  detail.querySelector('button').focus({ preventScroll: true });
}

function closeDetail() {
  detail.hidden = true;
  for (const element of document.querySelectorAll('.demo-search, .demo-filters, .demo-items')) element.inert = false;
  if (lastOpened?.isConnected) lastOpened.focus({ preventScroll: true });
}

search.addEventListener('input', renderDemo);
filters.forEach(button => button.addEventListener('click', () => {
  filter = button.dataset.filter;
  filters.forEach(other => {
    const active = other === button;
    other.classList.toggle('active', active);
    other.setAttribute('aria-pressed', String(active));
  });
  renderDemo();
}));
detail.querySelector('button').addEventListener('click', closeDetail);
document.querySelector('.demo-window').addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    if (!detail.hidden) closeDetail();
    search.focus({ preventScroll: true });
    search.select();
    return;
  }
  if (!detail.hidden) {
    if (event.key === 'Escape') { event.preventDefault(); closeDetail(); }
    return;
  }
  const rows = [...list.querySelectorAll('.demo-item')];
  if (['ArrowDown', 'ArrowUp'].includes(event.key) && rows.length) {
    event.preventDefault();
    const index = document.activeElement === search ? 0 : (selection + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
    select(index);
    rows[index].focus({ preventScroll: true });
  }
  if (event.key === 'Enter' && document.activeElement === search && visible.length) {
    event.preventDefault();
    openDetail(visible[selection], search);
  }
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
  const label = document.querySelector('#touch-label');
  label.textContent = 'Мягкие. Память — крепкая.';
  clearTimeout(labelTimer);
  labelTimer = setTimeout(() => { label.textContent = 'Да, их можно потрогать.'; }, 2400);
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

document.querySelector('#copy-command').addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  const command = 'zsh scripts/build-app.sh\nopen dist/Buffera.app';
  try {
    if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
    await navigator.clipboard.writeText(command);
    status.textContent = 'Команды скопированы. Запусти их из папки с исходниками.';
  } catch {
    status.textContent = 'Не удалось скопировать. Выдели команды выше и нажми ⌘C.';
    const range = document.createRange();
    range.selectNodeContents(document.querySelector('.command-block code'));
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
});
