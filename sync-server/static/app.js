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
  btn.onclick = () => {
    document.querySelectorAll('.nav').forEach((b) => b.classList.remove('active'));
    document.querySelectorAll('.view').forEach((v) => v.classList.remove('active'));
    btn.classList.add('active');
    $('#view-' + btn.dataset.view).classList.add('active');
  };
});

$('#server-url').textContent = location.origin;
load();
state.timer = setInterval(load, 5000);
