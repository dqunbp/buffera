(() => {
  const { records, ui } = JSON.parse(document.getElementById('docs-data').textContent);
  const input = document.getElementById('docs-search');
  const results = document.getElementById('docs-search-results');
  const matches = document.getElementById('docs-search-matches');
  const status = document.getElementById('docs-search-status');
  const content = document.getElementById('docs-page-content');
  const toc = document.querySelector('.docs-toc');
  const menu = document.querySelector('.docs-menu');
  const narrow = matchMedia('(max-width: 800px)');
  const syncMenu = () => { menu.open = !narrow.matches; };
  syncMenu();
  narrow.addEventListener('change', syncMenu);
  document.querySelector('.docs-search').hidden = false;
  const normalize = text => text.toLocaleLowerCase().normalize('NFKD').replace(/\p{M}/gu, '');
  const indexed = records.map(record => ({ ...record, searchable: normalize(`${record.title} ${record.section} ${record.text}`) }));

  function search() {
    const query = normalize(input.value.trim());
    results.hidden = !query;
    content.hidden = !!query;
    if (toc) toc.hidden = !!query;
    matches.replaceChildren();
    if (!query) { status.textContent = ''; return; }
    const terms = query.split(/\s+/);
    const found = indexed.filter(record => terms.every(term => record.searchable.includes(term)));
    status.textContent = found.length ? ui.results.replace('{count}', found.length) : ui.noResults;
    found.forEach(record => {
      const link = document.createElement('a');
      link.href = record.url;
      const title = document.createElement('span');
      title.textContent = record.title;
      const heading = document.createElement('strong');
      heading.textContent = record.section;
      const snippet = document.createElement('p');
      snippet.textContent = `${record.text.slice(0, 160)}${record.text.length > 160 ? '…' : ''}`;
      link.append(title, heading, snippet);
      matches.append(link);
    });
  }
  input.addEventListener('input', search);
  const clear = () => { input.value = ''; search(); input.focus(); };
  document.getElementById('docs-search-clear').addEventListener('click', clear);
  document.addEventListener('keydown', event => {
    const editing = event.target.closest('input, textarea, select, [contenteditable="true"]');
    if (!editing && !event.altKey && ((event.key === '/' && !event.ctrlKey && !event.metaKey) || (event.key.toLowerCase() === 'k' && (event.metaKey || event.ctrlKey)))) {
      event.preventDefault(); input.focus(); input.select();
    }
    if (event.key === 'Escape' && document.activeElement === input) { event.preventDefault(); clear(); }
  });
  for (const button of document.querySelectorAll('[data-copy]')) {
    button.hidden = false;
    button.addEventListener('click', async () => {
      const block = button.closest('.docs-code');
      block.querySelector('[data-copy-feedback]').hidden = true;
      try {
        await navigator.clipboard.writeText(block.querySelector('code').textContent);
        button.textContent = ui.copied;
        document.getElementById('docs-copy-status').textContent = ui.copied;
        setTimeout(() => { button.textContent = ui.copy; }, 2000);
      } catch {
        button.textContent = ui.copy;
        block.querySelector('[data-copy-feedback]').hidden = false;
        document.getElementById('docs-copy-status').textContent = ui.copyFailed;
        block.querySelector('pre').focus();
      }
    });
  }
  const sections = [...document.querySelectorAll('.docs-prose section')];
  const tocLinks = [...document.querySelectorAll('.docs-toc a')];
  if (sections.length) {
    let scheduled = false;
    function updateCurrent() {
      scheduled = false;
      const current = [...sections].reverse().find(section => section.getBoundingClientRect().top <= 130) || sections[0];
      for (const link of tocLinks) {
        if (link.hash === `#${current.id}`) link.setAttribute('aria-current', 'location');
        else link.removeAttribute('aria-current');
      }
    }
    addEventListener('scroll', () => {
      if (!scheduled) { scheduled = true; requestAnimationFrame(updateCurrent); }
    }, { passive: true });
    updateCurrent();
  }
})();
