'use strict';

// The demo is deliberately self-contained: no access to the visitor's clipboard or history.
const messages = JSON.parse(document.querySelector('#locale-data').textContent);
const { samples, kindLabels } = messages;
const locale = document.documentElement.lang;
const touchIdle = document.querySelector('#touch-label').textContent;
const formatMessage = (message, values) => message.replace(/\{(\w+)\}/g, (_, key) => values[key]);
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
  const query = search.value.trim().toLocaleLowerCase(locale);
  visible = samples.filter(item => {
    const matchesFilter = filter === 'all' || (filter === 'favorite' ? item.favorite : item.kind === filter);
    return matchesFilter && `${item.title} ${item.text} ${item.source} ${item.keywords}`.toLocaleLowerCase(locale).includes(query);
  });
  selection = 0;
  list.replaceChildren();
  if (!visible.length) {
    const empty = document.createElement('p');
    empty.className = 'demo-empty';
    empty.textContent = messages.empty;
    list.append(empty);
  }
  visible.forEach((item, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `demo-item${index === selection ? ' selected' : ''}`;
    button.dataset.id = item.id;
    button.setAttribute('aria-label', formatMessage(messages.view, { title: item.title }));
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
      star.setAttribute('aria-label', messages.favorite);
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
  count.textContent = formatMessage(messages.count, { visible: visible.length, total: samples.length });
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
