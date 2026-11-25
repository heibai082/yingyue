// 嘤阅同步面板（无依赖）
const $ = (s) => document.querySelector(s);
const state = { token: localStorage.getItem('yy_token') || '', data: null, timer: null };

function fmtSize(n) {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 10 || i === 0 ? 0 : 1)} ${u[i]}`;
}
function fmtTime(ms) {
  if (!ms) return '—';
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function fmtSeconds(sec) {
  if (!sec) return '—';
  const h = sec / 3600;
  return h >= 1 ? h.toFixed(1) : (sec / 60).toFixed(0) + ' 分';
}
function authHeaders() {
  return state.token ? { Authorization: `Bearer ${state.token}` } : {};
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { ...(opts.headers || {}), ...authHeaders() },
  });
  if (res.status === 401) {
    openTokenDialog();
    throw new Error('unauthorized');
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.headers.get('content-type')?.includes('json') ? res.json() : res;
}

async function load() {
  try {
    const d = await api('/api/summary');
    state.data = d;
    setStatus(true);
    render(d);
  } catch (e) {
    setStatus(false, e.message === 'unauthorized' ? '需要令牌' : '连接失败');
  }
}

function setStatus(ok, text) {
  const el = $('#status');
  el.className = 'status ' + (ok ? 'ok' : 'bad');
  el.textContent = text || (ok ? '已连接' : '离线');
}

function render(d) {
  $('#stat-books').textContent = d.books ?? 0;
  $('#stat-marks').textContent = d.bookmarks ?? 0;
  $('#stat-time').textContent = fmtSeconds(d.stats?.totalSeconds || 0);
  $('#stat-backups').textContent = (d.backups || []).length;
  $('#updated-at').textContent = d.updatedAt ? `最后同步 ${fmtTime(d.updatedAt)}` : '还没有同步过';
  renderBooks('#latest-books', (d.recent || []).slice(0, 6));
  renderBooks('#recent-list', d.recent || []);
  renderBackups(d.backups || []);
  renderDevices(d.devices || {});
  renderShelf(state.books || d.recent || []);
  renderBookmarks(d.bookmarkItems || []);
  renderStats(d.stats || {});
}

function renderBooks(sel, books) {
  const box = $(sel);
  if (!books.length) { box.innerHTML = '<div class="empty">还没有阅读记录，先在 App 里读一章吧</div>'; return; }
  box.innerHTML = books.map((b) => {
    const total = Number(b.total || 0);
    const idx = Number(b.chapterIndex || 0);
    const pct = b.finished ? 100 : total > 0 ? Math.min(100, Math.round(((idx + 1) / total) * 100)) : null;
    const badge = b.finished
      ? '<span class="badge done">读完</span>'
      : pct != null ? `<span class="badge">${pct}%</span>` : `<span class="badge">第 ${idx + 1} 章</span>`;
    return `<div class="row">
      <div class="grow">
        <div class="name">${esc(b.title || b.path || '未命名')}</div>
        <div class="sub">${esc(b.author || '')} ${b.group ? '· ' + esc(b.group) : ''} · ${fmtTime(b.lastReadAt)}</div>
      </div>
      ${badge}
    </div>`;
  }).join('');
}

function renderBackups(items) {
  const box = $('#backup-list');
  if (!items.length) { box.innerHTML = '<div class="empty">还没有备份</div>'; return; }
  box.innerHTML = items.map((b) => `<div class="row">
      <div class="grow">
        <div class="name">${esc(b.name)}</div>
        <div class="sub">${fmtSize(b.size)} · ${fmtTime(b.mtime * 1000)}</div>
      </div>
      <a class="btn" href="/api/backups/${encodeURIComponent(b.name)}${state.token ? '?token=' + encodeURIComponent(state.token) : ''}">下载</a>
      <button class="btn danger" data-del="${esc(b.name)}">删除</button>
    </div>`).join('');
  box.querySelectorAll('[data-del]').forEach((btn) => {
    btn.onclick = async () => {
      if (!confirm(`删除备份 ${btn.dataset.del}？`)) return;
      await api(`/api/backups/${encodeURIComponent(btn.dataset.del)}`, { method: 'DELETE' });
      load();
    };
  });
}

function renderDevices(devices) {
  const box = $('#device-list');
  const list = Object.entries(devices);
  if (!list.length) { box.innerHTML = '<div class="empty">还没有设备上报</div>'; return; }
  box.innerHTML = list.map(([name, info]) => `<div class="row">
      <div class="grow">
        <div class="name">${esc((info && info.name) || name)}</div>
        <div class="sub">${esc((info && info.platform) || '未知设备')} · 最近 ${fmtTime(info && info.lastSeen)}</div>
      </div>
    </div>`).join('');
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function openTokenDialog() {
  const dlg = $('#token-dialog');
  $('#token-input').value = state.token;
  dlg.showModal();
}

$('#token-dialog').addEventListener('close', () => {
  const val = $('#token-input').value.trim();
  if ($('#token-dialog').returnValue === 'ok') {
    state.token = val;
    localStorage.setItem('yy_token', val);
    load();
  }
});

$('#refresh').onclick = load;
$('#token-btn').onclick = openTokenDialog;

document.querySelectorAll('.nav').forEach((btn) => {
  btn.onclick = async () => {
    document.querySelectorAll('.nav').forEach((b) => b.classList.remove('active'));
    document.querySelectorAll('.view').forEach((v) => v.classList.remove('active'));
    btn.classList.add('active');
    $('#view-' + btn.dataset.view).classList.add('active');
    if (btn.dataset.view === 'shelf') {
      try {
        renderShelf(await ensureBooks());
      } catch (_) {}
    }
    if (btn.dataset.view === 'sources') loadSources();
    if (btn.dataset.view === 'bookmarks') {
      try {
        await ensureBooks();
      } catch (_) {}
    }
  };
});

$('#server-url').textContent = location.origin;
load();
state.timer = setInterval(load, 5000);

/* ---------- 书架 / 阅读 ---------- */
const reader = { book: null, chapters: [], index: 0, online: null };

async function ensureBooks() {
  if (state.books) return state.books;
  const st = await api('/api/state');
  state.books = st.books || [];
  return state.books;
}

function renderShelf(books) {
  const box = $('#shelf-list');
  if (!box) return;
  const list = (books && books.length) ? books : [];
  if (!list.length) {
    box.innerHTML = '<div class="empty">书架还是空的（App 同步一次后这里就有）</div>';
    return;
  }
  box.innerHTML = list.map((b, i) => `<div class="row" data-book="${i}">
      <div class="grow">
        <div class="name">${esc(b.title || b.path)}</div>
        <div class="sub">${esc(b.author || '')} · 第 ${Number(b.chapterIndex || 0) + 1} 章${b.total ? ' / ' + b.total : ''}</div>
      </div>
      <span class="badge">打开</span>
    </div>`).join('');
  box.querySelectorAll('[data-book]').forEach((el) => {
    el.onclick = () => openBook(list[Number(el.dataset.book)]);
  });
}

async function openBook(book) {
  reader.online = null;
  reader.book = book;
  reader.index = Number(book.chapterIndex || 0);
  $('#reader').classList.remove('hidden');
  $('#reader-title').textContent = book.title || book.path;
  $('#reader-sub').textContent = '正在加载目录…';
  $('#reader-body').innerHTML = '';
  try {
    const r = await api(`/api/chapters/list?path=${encodeURIComponent(book.path)}`);
    reader.chapters = r.items || [];
  } catch (_) {
    reader.chapters = [];
  }
  if (!reader.chapters.length) {
    $('#reader-sub').textContent = '';
    $('#reader-body').innerHTML = '<div class="reader-note">这本书还没有同步到正文。<br>在 App 里打开一章（并开启「同步缓存」）后，这里就能直接读。</div>';
    return;
  }
  showChapterList();
}

function showChapterList() {
  const b = reader.book;
  $('#reader-sub').textContent = `已同步 ${reader.chapters.length} 章`;
  $('#reader-body').innerHTML = `<div class="chapter-list">${reader.chapters.map((c) => `
    <div class="chapter-item" data-idx="${c.index}">
      ${esc(c.title || ('第 ' + (c.index + 1) + ' 章'))}
      <span class="muted">${c.hasText ? '正文' : ''}${c.images ? c.images + ' 图' : ''}</span>
    </div>`).join('')}</div>`;
  $('#reader-body').querySelectorAll('[data-idx]').forEach((el) => {
    el.onclick = () => loadChapter(Number(el.dataset.idx));
  });
  if (b) $('#reader-sub').textContent += ` · 当前第 ${Number(b.chapterIndex || 0) + 1} 章`;
}

async function loadChapter(index) {
  const b = reader.book;
  if (!b) return;
  if (reader.online) return loadOnlineChapter(reader.online, index);
  reader.index = index;
  $('#reader-sub').textContent = '加载中…';
  try {
    const data = await api(`/api/chapters?path=${encodeURIComponent(b.path)}&index=${index}`);
    $('#reader-title').textContent = data.title || b.title || '';
    $('#reader-sub').textContent = `${b.title || ''} · 第 ${index + 1} 章`;
    if (data.images && data.images.length) {
      $('#reader-body').innerHTML = data.images.map((u) => `<img src="${esc(u)}" loading="lazy" />`).join('');
    } else if (data.text) {
      $('#reader-body').innerHTML = `<div class="reader-text">${esc(data.text)}</div>`;
    } else {
      $('#reader-body').innerHTML = '<div class="reader-note">这一章既没有正文也没有图片</div>';
    }
    $('#reader-body').scrollTop = 0;
    // 回写进度：面板和 App 都能看到「读到哪」
    try {
      await api('/api/state', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          books: [{
            path: b.path,
            title: b.title,
            author: b.author,
            chapterIndex: index,
            lastReadAt: Date.now(),
            total: b.total,
          }],
        }),
      });
    } catch (_) {}
  } catch (e) {
    $('#reader-body').innerHTML = `<div class="reader-note">这一章还没同步（${esc(e.message)}）</div>`;
  }
}

function stepChapter(delta) {
  const idx = reader.chapters.findIndex((c) => c.index === reader.index);
  if (idx < 0) return;
  const next = idx + delta;
  if (next < 0 || next >= reader.chapters.length) return;
  loadChapter(reader.chapters[next].index);
}

$('#reader-back').onclick = () => {
  $('#reader').classList.add('hidden');
  showChapterListSafe();
};
$('#reader-prev').onclick = () => stepChapter(-1);
$('#reader-next').onclick = () => stepChapter(1);

function showChapterListSafe() {
  if (reader.chapters.length) showChapterList();
}
/* ---------- 书签 / 统计 / 书源 ---------- */
function bookTitleById(bookId) {
  const b = (state.books || []).find((x) => x.id === bookId);
  return b ? (b.title || b.path) : bookId;
}

function renderBookmarks(items) {
  const box = $('#bookmark-list');
  if (!box) return;
  if (!items.length) {
    box.innerHTML = '<div class="empty">还没有书签（App 里加一条，同步后这里就有）</div>';
    return;
  }
  box.innerHTML = items.map((m, i) => `<div class="row" data-mark="${i}">
      <div class="grow">
        <div class="name">${esc(m.chapterTitle || ('第 ' + ((m.chapterIndex || 0) + 1) + ' 章'))}</div>
        <div class="sub">${esc(bookTitleById(m.bookId))} · 第 ${(m.chapterIndex || 0) + 1} 章 · ${fmtTime(m.createdAt)}</div>
        ${m.excerpt ? `<div class="sub" style="margin-top:2px">「${esc(String(m.excerpt).slice(0, 80))}」</div>` : ''}
      </div>
      <span class="badge">跳转</span>
    </div>`).join('');
  box.querySelectorAll('[data-mark]').forEach((el) => {
    el.onclick = () => jumpToBookmark(items[Number(el.dataset.mark)]);
  });
}

async function jumpToBookmark(mark) {
  const books = await ensureBooks();
  const book = books.find((b) => b.id === mark.bookId);
  if (!book) {
    alert('这本书还没同步到服务器');
    return;
  }
  await openBook(book);
  await loadChapter(mark.chapterIndex || 0);
}

function renderStats(stats) {
  const total = stats.totalSeconds || 0;
  $('#st-total').textContent = total ? (total / 3600).toFixed(1) : '0';
  const days = stats.days || {};
  // 连续天数
  const key = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  let streak = 0;
  const today = new Date();
  for (let i = 0; i < 3650; i++) {
    const d = new Date(today.getTime() - i * 86400000);
    const v = days[key(d)] || 0;
    if (v > 0) streak++;
    else if (i > 0) break;
    else continue;
  }
  $('#st-streak').textContent = streak;
  $('#st-finished').textContent = stats.finishedBooks || 0;

  // 14 天柱状图
  const box = $('#chart');
  if (!box) return;
  const vals = [];
  for (let i = 13; i >= 0; i--) {
    const d = new Date(today.getTime() - i * 86400000);
    vals.push({ label: `${d.getMonth() + 1}/${d.getDate()}`, minutes: Math.round((days[key(d)] || 0) / 60) });
  }
  const max = Math.max(1, ...vals.map((v) => v.minutes));
  box.innerHTML = vals.map((v) => `<div class="bar" title="${v.minutes} 分钟">
      <i style="height:${Math.max(2, Math.round((v.minutes / max) * 100))}%"></i>
      <span>${v.label}</span>
    </div>`).join('');
}

async function loadSources() {
  const box = $('#source-list');
  if (!box) return;
  box.innerHTML = '<div class="empty">加载中…</div>';
  try {
    const data = await api('/api/sources');
    state.sources = data.items || [];
  } catch (_) {
    state.sources = [];
  }
  renderSources();
}

function renderSources() {
  const box = $('#source-list');
  const q = ($('#src-search')?.value || '').trim().toLowerCase();
  let list = state.sources || [];
  if (q) list = list.filter((s) => `${s.bookSourceName || ''} ${s.bookSourceUrl || ''}`.toLowerCase().includes(q));
  if (!list.length) {
    box.innerHTML = '<div class="empty">还没有书源（App 同步一次后这里就有）</div>';
    return;
  }
  box.innerHTML = list.slice(0, 500).map((s) => `<div class="row">
      <div class="grow">
        <div class="name">${esc(s.bookSourceName || '未命名')}</div>
        <div class="sub">${esc(s.bookSourceUrl || '')}</div>
      </div>
      <span class="badge ${s.enabled === false ? '' : 'done'}">${s.enabled === false ? '停用' : '启用'}</span>
    </div>`).join('') + (list.length > 500 ? `<div class="empty">只显示前 500 个（共 ${list.length}）</div>` : '');
}

$('#src-search')?.addEventListener('input', renderSources);
/* ---------- 在线搜书 / 在线阅读 ---------- */
async function runSearch() {
  const key = ($('#search-input')?.value || '').trim();
  if (!key) return;
  const box = $('#search-list');
  box.innerHTML = '<div class="empty">正在搜索各个书源…（最多等 15 秒）</div>';
  try {
    const data = await api(`/api/search?key=${encodeURIComponent(key)}`);
    renderSearchResults(data.items || []);
  } catch (e) {
    box.innerHTML = `<div class="empty">搜索失败：${esc(e.message)}</div>`;
  }
}

function renderSearchResults(items) {
  const box = $('#search-list');
  if (!items.length) {
    box.innerHTML = '<div class="empty">没搜到。可能书源需要 App 的 WebView（JS 源），或关键字太偏。</div>';
    return;
  }
  box.innerHTML = items.map((it, i) => `<div class="row" data-res="${i}">
      <div class="grow">
        <div class="name">${esc(it.name)} <span class="badge">${esc(it.sourceName)}</span></div>
        <div class="sub">${esc(it.author || '')}${it.lastChapter ? ' · ' + esc(it.lastChapter) : ''}</div>
        ${it.intro ? `<div class="sub" style="margin-top:2px">${esc(String(it.intro).slice(0, 90))}</div>` : ''}
      </div>
      <span class="badge done">打开</span>
    </div>`).join('');
  box.querySelectorAll('[data-res]').forEach((el) => {
    el.onclick = () => openOnlineBook(items[Number(el.dataset.res)]);
  });
}

async function openOnlineBook(item) {
  $('#reader').classList.remove('hidden');
  $('#reader-title').textContent = item.name || '—';
  $('#reader-sub').textContent = '正在取目录…';
  $('#reader-body').innerHTML = '<div class="reader-note">加载中…</div>';
  try {
    const data = await api(`/api/book?source=${encodeURIComponent(item.sourceUrl)}&url=${encodeURIComponent(item.bookUrl)}`);
    const chapters = data.chapters || [];
    if (!chapters.length) {
      $('#reader-sub').textContent = '';
      $('#reader-body').innerHTML = '<div class="reader-note">这个源没解析出目录（可能需要 App 的 WebView 或规则较特殊）</div>';
      return;
    }
    reader.online = { item, chapters };
    reader.book = { title: item.name, path: item.bookUrl };
    reader.chapters = chapters.map((c, i) => ({ index: i, title: c.title }));
    $('#reader-sub').textContent = `目录 ${chapters.length} 章`;
    $('#reader-body').innerHTML = `<div class="chapter-list">${chapters.map((c, i) => `
      <div class="chapter-item" data-oi="${i}">${esc(c.title)}</div>`).join('')}</div>`;
    $('#reader-body').querySelectorAll('[data-oi]').forEach((el) => {
      const i = Number(el.dataset.oi);
      el.onclick = () => loadOnlineChapter(reader.online, i);
    });
  } catch (e) {
    $('#reader-body').innerHTML = `<div class="reader-note">取目录失败：${esc(e.message)}</div>`;
  }
}

async function loadOnlineChapter(online, index) {
  const ch = online.chapters[index];
  if (!ch) return;
  reader.index = index;
  $('#reader-title').textContent = ch.title || '';
  $('#reader-sub').textContent = online.item.name || '';
  $('#reader-body').innerHTML = '<div class="reader-note">正在取正文…</div>';
  try {
    const data = await api(`/api/read?source=${encodeURIComponent(online.item.sourceUrl)}&url=${encodeURIComponent(ch.url)}`);
    if (data.images && data.images.length) {
      $('#reader-body').innerHTML = data.images.map((u) => `<img src="${esc(u)}" loading="lazy" />`).join('');
    } else if (data.text) {
      $('#reader-body').innerHTML = `<div class="reader-text">${esc(data.text)}</div>`;
    } else {
      $('#reader-body').innerHTML = '<div class="reader-note">这一章没取到正文（可能需要 App 的 WebView）</div>';
    }
    $('#reader-body').scrollTop = 0;
    reader.chaptersOffset = index;
  } catch (e) {
    $('#reader-body').innerHTML = `<div class="reader-note">取正文失败：${esc(e.message)}</div>`;
  }
}

$('#search-btn')?.addEventListener('click', runSearch);
$('#search-input')?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') runSearch();
});