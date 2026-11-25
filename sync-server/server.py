#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""嘤阅同步服务（单文件，只用标准库，方便 Docker 里跑）。

能力：
  - REST 状态同步：GET/POST /api/state（书架进度、书签、阅读统计，按时间取新合并）
  - 备份：GET/POST /api/backups、下载/删除、自动保留最近 N 份
  - WebDAV 子集（/dav/）：OPTIONS / PROPFIND / MKCOL / PUT / GET / DELETE
  - macOS / iOS 风格网页面板（/）
  - 外网访问：可放反向代理后面（支持 X-Forwarded-*），配 PUBLIC_URL 只影响提示文案
  - 多用户：一个服务可以给几个朋友用，令牌不同、数据目录互相隔离

环境变量：
  SYNC_TOKEN    单用户令牌（默认 yingyue）
  SYNC_TOKENS   多用户写法：me:abc,friend:xyz（优先于 SYNC_TOKEN）
  DATA_DIR      数据目录（默认脚本旁 ./data；Docker 里 /data）
  BACKUP_KEEP   每个用户保留备份份数（默认 14）
  PORT          端口（默认 8090）
  PUBLIC_URL    外网地址（仅用于 /api/config 与提示，例如 https://sync.example.com）
"""

import base64
import http.cookies
import io
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import source_engine

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("DATA_DIR", os.path.join(ROOT, "data"))
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "14"))
PORT = int(os.environ.get("PORT", "8090"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")

# 版本号（workflow 会读取这个常量）
SYNC_VERSION = "1.3"
USERS_DIR = os.path.join(DATA_DIR, "users")

# 网页面板：账号密码登录（浏览器记住 30 天），App 仍用 Bearer 令牌
UI_USER = os.environ.get("UI_USER", "admin")
UI_PASSWORD = os.environ.get("UI_PASSWORD", "admin")  # 默认 admin/admin，可在面板里改
UI_SESSION_DAYS = int(os.environ.get("UI_SESSION_DAYS", "30"))
SESSIONS_FILE = os.path.join(DATA_DIR, "sessions.json")
UI_SESSIONS = {}  # sid -> {"user": name, "exp": ts}


def load_sessions():
    try:
        with open(SESSIONS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        now = time.time()
        return {k: v for k, v in data.items() if isinstance(v, dict) and v.get("exp", 0) > now}
    except Exception:
        return {}


def save_sessions():
    try:
        tmp = SESSIONS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(UI_SESSIONS, f)
        os.replace(tmp, SESSIONS_FILE)
    except Exception:
        pass


AUTH_FILE = os.path.join(DATA_DIR, "ui_auth.json")


def load_ui_auth():
    """面板账号密码：优先用 ui_auth.json（面板里改过的），否则用环境变量/默认 admin。"""
    try:
        with open(AUTH_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        u = (data.get("username") or "").strip()
        p = data.get("password") or ""
        if u and p:
            return u, p
    except Exception:
        pass
    return UI_USER, UI_PASSWORD


def save_ui_auth(username, password):
    tmp = AUTH_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"username": username, "password": password}, f)
    os.replace(tmp, AUTH_FILE)

TOKENS_FILE = os.path.join(DATA_DIR, "tokens.json")


def load_token_overrides():
    try:
        with open(TOKENS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items() if k and v}
    except Exception:
        pass
    return {}


def apply_token_overrides():
    """面板里改过的令牌优先：有覆盖的用户，丢掉环境变量里的旧令牌。"""
    overrides = load_token_overrides()
    if not overrides:
        return
    users = set(overrides.values())
    for tok in [t for t, u in list(TOKENS.items()) if u in users]:
        TOKENS.pop(tok, None)
    TOKENS.update(overrides)


def save_token_overrides():
    try:
        tmp = TOKENS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(TOKENS, f)
        os.replace(tmp, TOKENS_FILE)
    except Exception:
        pass


def token_of_user(name):
    for tok, u in TOKENS.items():
        if u == name:
            return tok
    return ""

def check_login(username, password):
    """返回用户目录名；失败返回 None。

    支持两种：
      1. 用户名 = 令牌对应的名字（如 me / friend），密码 = 该令牌
      2. 用户名 = UI_USER，密码 = UI_PASSWORD（管理员，进入第一个用户的数据）
    """
    username = (username or "").strip()
    password = (password or "").strip()
    if not password:
        return None
    panel_user, panel_pass = load_ui_auth()
    if username == panel_user and password == panel_pass:
        return next(iter(TOKENS.values()))
    if username in set(TOKENS.values()) and TOKENS.get(password) == username:
        return username
    for tok, name in TOKENS.items():
        if name == username and tok == password:
            return name
    first = 'me' if 'me' in TOKENS.values() else next(iter(TOKENS.values()))
    if username == UI_USER and password == (UI_PASSWORD or next(iter(TOKENS.keys()))):
        return first
    return None

LOCK = threading.Lock()
STARTED_AT = time.time()


def parse_tokens():
    """令牌 → 用户名。支持 SYNC_TOKENS=me:abc,friend:xyz 或单 SYNC_TOKEN。"""
    raw = os.environ.get("SYNC_TOKENS", "").strip()
    if raw:
        out = {}
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            if ":" in part:
                name, tok = part.split(":", 1)
                name, tok = name.strip(), tok.strip()
            else:
                name, tok = "user%d" % (len(out) + 1), part
            if tok:
                out[tok] = name or ("user%d" % (len(out) + 1))
        if out:
            return out
    return {os.environ.get("SYNC_TOKEN", "yingyue"): "default"}


TOKENS = parse_tokens()


def safe_user(name):
    return re.sub(r"[^0-9A-Za-z_\-\u4e00-\u9fff]", "_", name)[:40] or "default"


def user_dir(name):
    d = os.path.join(USERS_DIR, safe_user(name))
    os.makedirs(os.path.join(d, "backups"), exist_ok=True)
    os.makedirs(os.path.join(d, "dav"), exist_ok=True)
    return d


def state_file(udir):
    return os.path.join(udir, "state.json")


def load_state(udir):
    try:
        with open(state_file(udir), "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {"version": 1, "updatedAt": 0, "books": [], "bookmarks": [], "devices": {}, "stats": {}}


def save_state(udir, state):
    p = state_file(udir)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def merge_state(cur, incoming):
    """按「时间取新」合并：同一本书 / 同一条书签以新的为准。"""
    if not isinstance(incoming, dict):
        return cur
    now = int(time.time() * 1000)
    cur_books = {b.get("path") or b.get("id"): b for b in cur.get("books", []) if isinstance(b, dict)}
    for b in incoming.get("books", []) or []:
        if not isinstance(b, dict):
            continue
        key = b.get("path") or b.get("id")
        if not key:
            continue
        old = cur_books.get(key)
        if old is None or int(b.get("lastReadAt") or 0) >= int(old.get("lastReadAt") or 0):
            merged = dict(old or {})
            merged.update(b)
            cur_books[key] = merged
    cur["books"] = sorted(cur_books.values(), key=lambda b: int(b.get("lastReadAt") or 0), reverse=True)

    marks = {m.get("id"): m for m in cur.get("bookmarks", []) if isinstance(m, dict)}
    for m in incoming.get("bookmarks", []) or []:
        if isinstance(m, dict) and m.get("id"):
            marks[m["id"]] = m
    cur["bookmarks"] = sorted(marks.values(), key=lambda m: int(m.get("createdAt") or 0), reverse=True)

    stats = cur.get("stats") if isinstance(cur.get("stats"), dict) else {}
    inc = incoming.get("stats") if isinstance(incoming.get("stats"), dict) else {}
    stats["totalSeconds"] = max(int(stats.get("totalSeconds") or 0), int(inc.get("totalSeconds") or 0))
    stats["finishedBooks"] = max(int(stats.get("finishedBooks") or 0), int(inc.get("finishedBooks") or 0))
    days = stats.get("days") if isinstance(stats.get("days"), dict) else {}
    for k, v in (inc.get("days") or {}).items():
        try:
            days[k] = max(int(days.get(k) or 0), int(v or 0))
        except Exception:
            continue
    stats["days"] = days
    cur["stats"] = stats

    devices = cur.get("devices") if isinstance(cur.get("devices"), dict) else {}
    for name, info in (incoming.get("devices") or {}).items():
        if isinstance(info, dict):
            merged = dict(devices.get(name) or {})
            merged.update(info)
            merged["lastSeen"] = now
            devices[name] = merged
    cur["devices"] = devices
    cur["version"] = 1
    cur["updatedAt"] = now
    return cur


def load_sources(udir):
    f = os.path.join(udir, "sources.json")
    if not os.path.isfile(f):
        return []
    try:
        with open(f, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return []
    if isinstance(data, dict):
        data = data.get("items") or []
    return [s for s in data if isinstance(s, dict)]


def find_source(udir, source_url):
    for s in load_sources(udir):
        if (s.get("bookSourceUrl") or "").rstrip("/") == (source_url or "").rstrip("/"):
            return s
    return None


def search_online(udir, key, limit=30):
    sources = [
        s for s in load_sources(udir)
        if s.get("enabled", True) and (s.get("searchUrl") or "").strip()
    ][:60]
    results = []
    lock = threading.Lock()

    def one(src):
        try:
            items = source_engine.search_source(src, key)
        except Exception as e:
            print("[search] %s 失败：%s" % (src.get("bookSourceName"), e))
            return
        with lock:
            for it in items[:10]:
                it["sourceName"] = src.get("bookSourceName") or ""
                it["sourceUrl"] = src.get("bookSourceUrl") or ""
                results.append(it)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(one, sources))
    # 按书名+作者去重
    seen = set()
    out = []
    for r in results:
        k = (r.get("name") or "", r.get("author") or "")
        if not k[0] or k in seen:
            continue
        seen.add(k)
        out.append(r)
    return out[:limit]

def chapters_dir(udir):
    d = os.path.join(udir, "chapters")
    os.makedirs(d, exist_ok=True)
    return d


def chapter_key(path):
    import hashlib
    return hashlib.sha1(path.encode("utf-8")).hexdigest()[:16]


def chapter_file(udir, path, index):
    return os.path.join(chapters_dir(udir), chapter_key(path), "%06d.json" % index)


def save_chapter(udir, payload):
    path = str(payload.get("path") or "")
    index = int(payload.get("index") or 0)
    if not path:
        raise ValueError("missing path")
    data = {
        "path": path,
        "index": index,
        "title": payload.get("title") or "",
        "text": payload.get("text") or "",
        "images": payload.get("images") or [],
        "updatedAt": int(time.time() * 1000),
    }
    f = chapter_file(udir, path, index)
    os.makedirs(os.path.dirname(f), exist_ok=True)
    tmp = f + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, f)
    return data


def load_chapter(udir, path, index):
    f = chapter_file(udir, path, index)
    try:
        with open(f, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def chapter_index(udir):
    """返回 {bookPath: [章号]}，只扫文件名，快。"""
    root = chapters_dir(udir)
    out = {}
    try:
        dirs = os.listdir(root)
    except FileNotFoundError:
        return out
    # 目录名是 sha1(path)[:16]，需要反查 path：从 state 里拿
    st = load_state(udir)
    key_to_path = {}
    for b in st.get("books") or []:
        p = b.get("path")
        if p:
            key_to_path[chapter_key(p)] = p
    for name in dirs:
        folder = os.path.join(root, name)
        if not os.path.isdir(folder):
            continue
        path = key_to_path.get(name)
        if not path:
            continue
        idxs = []
        for f in os.listdir(folder):
            m = re.match(r"^(\d+)\.json$", f)
            if m:
                idxs.append(int(m.group(1)))
        if idxs:
            out[path] = sorted(idxs)
    return out

def list_chapters(udir, path):
    d = os.path.join(chapters_dir(udir), chapter_key(path))
    out = []
    try:
        names = os.listdir(d)
    except FileNotFoundError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name), "r", encoding="utf-8") as fh:
                data = json.load(fh)
            out.append({
                "index": int(data.get("index") or 0),
                "title": data.get("title") or "",
                "hasText": bool((data.get("text") or "").strip()),
                "images": len(data.get("images") or []),
            })
        except Exception:
            continue
    out.sort(key=lambda x: x["index"])
    return out


def download_image(url, referer, dest):
    import urllib.request
    req = urllib.request.Request(url, headers={
        "Referer": referer or url,
        "User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36",
    })
    with urllib.request.urlopen(req, timeout=25) as r:
        data = r.read()
    if not data:
        raise ValueError("empty image")
    with open(dest, "wb") as f:
        f.write(data)
    return len(data)

def list_backups(udir):
    bdir = os.path.join(udir, "backups")
    out = []
    try:
        names = os.listdir(bdir)
    except FileNotFoundError:
        return out
    for name in names:
        if not name.lower().endswith(".zip"):
            continue
        p = os.path.join(bdir, name)
        try:
            st = os.stat(p)
            out.append({"name": name, "size": st.st_size, "mtime": int(st.st_mtime)})
        except OSError:
            continue
    out.sort(key=lambda b: b["mtime"], reverse=True)
    return out


def prune_backups(udir):
    bdir = os.path.join(udir, "backups")
    for b in list_backups(udir)[BACKUP_KEEP:]:
        try:
            os.remove(os.path.join(bdir, b["name"]))
        except OSError:
            pass


def safe_name(name):
    name = urllib.parse.unquote(name)
    name = os.path.basename(name)
    return re.sub(r"[^0-9A-Za-z._\-\u4e00-\u9fff]", "_", name)


class Handler(BaseHTTPRequestHandler):
    server_version = "YingYueSync/1.3"
    protocol_version = "HTTP/1.1"

    # ---------- 基础 ----------
    def log_message(self, fmt, *args):
        print("[%s] %s" % (time.strftime("%H:%M:%S"), fmt % args))

    def _send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, Depth, X-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PROPFIND, MKCOL")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj, code=200, extra=None):
        self._send(code, obj, extra=extra)

    def _token(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[7:].strip()
        if auth.startswith("Basic "):
            try:
                raw = base64.b64decode(auth[6:]).decode("utf-8", "replace")
                _, _, pw = raw.partition(":")
                return pw.strip()
            except Exception:
                return ""
        if self.headers.get("X-Token"):
            return self.headers["X-Token"].strip()
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        return q.get("token", [""])[0].strip()

    def _sid(self):
        raw = self.headers.get("Cookie") or ""
        try:
            c = http.cookies.SimpleCookie(raw)
            m = c.get("yy_sid")
            return m.value if m else ""
        except Exception:
            return ""

    def _session_user(self):
        sid = self._sid()
        if not sid:
            return None
        s = UI_SESSIONS.get(sid)
        if not s or s.get("exp", 0) < time.time():
            UI_SESSIONS.pop(sid, None)
            return None
        return s.get("user")

    def _user(self):
        """命中的用户名：优先面板会话 cookie，其次 App 的令牌。"""
        u = self._session_user()
        if u:
            return u
        tok = self._token()
        if not TOKENS:
            return "default"
        return TOKENS.get(tok)

    def _require_user(self):
        u = self._user()
        if u is None:
            self._json({"error": "unauthorized"}, 401)
            return None
        return u

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    # ---------- 路由 ----------
    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            return self._static("index.html", "text/html; charset=utf-8")
        if path == "/style.css":
            return self._static("style.css", "text/css; charset=utf-8")
        if path == "/icon.png":
            return self._static("icon.png", "image/png")
        if path in ("/favicon.ico", "/apple-touch-icon.png"):
            return self._static("icon.png", "image/png")
        if path == "/app.js":
            return self._static("app.js", "application/javascript; charset=utf-8")
        if path == "/api/ui/account":
            user0 = self._user()
            if not user0:
                return self._json({"error": "unauthorized"}, 401)
            try:
                body = json.loads(self._body().decode("utf-8-sig") or "{}")
            except Exception:
                return self._json({"error": "bad json"}, 400)
            nu = (body.get("username") or "").strip()
            np = (body.get("password") or "").strip()
            if len(nu) < 2 or len(np) < 4:
                return self._json({"error": "账号至少 2 位、密码至少 4 位"}, 400)
            save_ui_auth(nu, np)
            return self._json({"ok": True, "username": nu})
        if path == "/api/ui/token":
            u = self._user()
            if not u:
                return self._json({"error": "unauthorized"}, 401)
            return self._json({"token": token_of_user(u), "user": u})
        if path == "/api/ui/me":
            u = self._user()
            if not u:
                return self._json({"error": "unauthorized"}, 401)
            return self._json({"user": u})
        if path == "/api/health":
            return self._json({"ok": True, "uptime": int(time.time() - STARTED_AT), "version": SYNC_VERSION})
        if path == "/api/config":
            return self._json({
                "name": "嘤阅同步",
                "version": SYNC_VERSION,
                "publicUrl": PUBLIC_URL or None,
                "users": len(set(TOKENS.values())),
                "features": ["state", "backups", "webdav", "multi-user"],
            })
        user = self._require_user()
        if user is None:
            return
        udir = user_dir(user)
        if path == "/api/whoami":
            return self._json({"user": user, "publicUrl": PUBLIC_URL or None})
        if path == "/api/state":
            with LOCK:
                return self._json(load_state(udir))
        if path == "/api/summary":
            with LOCK:
                st = load_state(udir)
            return self._json({
                "user": user,
                "updatedAt": st.get("updatedAt", 0),
                "books": len(st.get("books", [])),
                "bookmarks": len(st.get("bookmarks", [])),
                "bookmarkItems": (st.get("bookmarks") or [])[:300],
                "devices": st.get("devices", {}),
                "recent": (st.get("books") or [])[:30],
                "backups": list_backups(udir),
                "stats": st.get("stats", {}),
            })
        if path == "/api/search":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            key = (q.get("key") or [""])[0].strip()
            if not key:
                return self._json({"items": [], "error": "缺少关键字"}, 400)
            items = search_online(udir, key)
            return self._json({"items": items, "count": len(items)})
        if path == "/api/book":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            src_url = (q.get("source") or [""])[0]
            book_url = (q.get("url") or [""])[0]
            src = find_source(udir, src_url)
            if src is None:
                return self._json({"error": "找不到这个书源（先让 App 同步书源）"}, 404)
            try:
                data = source_engine.fetch_toc(src, book_url)
            except Exception as e:
                return self._json({"error": "取目录失败：%s" % e}, 502)
            return self._json(data)
        if path == "/api/read":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            src_url = (q.get("source") or [""])[0]
            url = (q.get("url") or [""])[0]
            src = find_source(udir, src_url)
            if src is None:
                return self._json({"error": "找不到这个书源"}, 404)
            try:
                data = source_engine.fetch_content(src, url)
            except Exception as e:
                return self._json({"error": "取正文失败：%s" % e}, 502)
            token = urllib.parse.quote(self._token())
            data["images"] = [
                "/api/img?u=%s&r=%s&token=%s"
                % (urllib.parse.quote(u, safe=""), urllib.parse.quote(url, safe=""), token)
                for u in data.get("images") or []
            ]
            return self._json(data)
        if path == "/api/img":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            u = (q.get("u") or [""])[0]
            ref = (q.get("r") or [""])[0]
            if not u.startswith("http"):
                return self._send(400, b"")
            try:
                req = urllib.request.Request(u, headers={
                    "Referer": ref or u,
                    "User-Agent": source_engine.UA,
                })
                with urllib.request.urlopen(req, timeout=25) as r:
                    data = r.read(15 * 1024 * 1024 + 1)
                    ctype = r.headers.get("Content-Type") or "image/jpeg"
                if len(data) > 15 * 1024 * 1024:
                    return self._send(413, b"")
                return self._send(200, data, ctype.split(";")[0])
            except Exception:
                return self._send(502, b"")
        if path == "/api/chapters/index":
            return self._json({"items": chapter_index(udir)})
        if path == "/api/chapters/list":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            p = (q.get("path") or [""])[0]
            return self._json({"items": list_chapters(udir, p)})
        if path == "/api/chapters":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            p = (q.get("path") or [""])[0]
            idx = int((q.get("index") or ["0"])[0])
            data = load_chapter(udir, p, idx)
            if data is None:
                return self._json({"error": "not found"}, 404)
            key = chapter_key(p)
            base = PUBLIC_URL or ""
            data["images"] = [
                (u if str(u).startswith("http") else
                 "%s/api/chapter-image/%s/%d/%d?token=%s"
                 % (base, key, idx, n, urllib.parse.quote(self._token())))
                for n, u in enumerate(data.get("images") or [])
            ]
            return self._json(data)
        if path.startswith("/api/chapter-image/"):
            parts = path[len("/api/chapter-image/"):].split("/")
            if len(parts) != 3:
                return self._json({"error": "bad path"}, 400)
            key, idx, n = parts[0], int(parts[1]), int(parts[2])
            d = os.path.join(chapters_dir(udir), safe_user(key))
            folder = os.path.join(d, "%06d" % idx)
            try:
                for name in os.listdir(folder):
                    if name.startswith("%04d." % n):
                        with open(os.path.join(folder, name), "rb") as f:
                            data = f.read()
                        ctype = "image/jpeg"
                        if name.endswith(".png"):
                            ctype = "image/png"
                        elif name.endswith(".webp"):
                            ctype = "image/webp"
                        return self._send(200, data, ctype)
            except FileNotFoundError:
                pass
            return self._send(404, b"")
        if path == "/api/sources":
            f = os.path.join(udir, "sources.json")
            if not os.path.isfile(f):
                return self._json({"items": []})
            with open(f, "r", encoding="utf-8") as fh:
                try:
                    data = json.load(fh)
                except Exception:
                    return self._json({"items": []})
            if isinstance(data, list):
                return self._json({"items": data})
            if isinstance(data, dict):
                return self._json(data)
            return self._json({"items": []})
        if path == "/api/settings":
            f = os.path.join(udir, "settings.json")
            if not os.path.isfile(f):
                return self._json({})
            with open(f, "r", encoding="utf-8") as fh:
                try:
                    return self._json(json.load(fh))
                except Exception:
                    return self._json({})
        if path == "/api/backups":
            return self._json({"items": list_backups(udir)})
        m = re.match(r"^/api/backups/(.+)$", path)
        if m:
            name = safe_name(m.group(1))
            p = os.path.join(udir, "backups", name)
            if not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            with open(p, "rb") as f:
                data = f.read()
            return self._send(200, data, "application/zip", {"Content-Disposition": 'attachment; filename="%s"' % name})
        if path.startswith("/dav"):
            return self._dav_get(udir, path)
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/ui/login":
            try:
                body = json.loads(self._body().decode("utf-8-sig") or "{}")
            except Exception:
                return self._json({"error": "bad json"}, 400)
            name = check_login(body.get("username"), body.get("password"))
            if not name:
                return self._json({"error": "账号或密码不对"}, 401)
            sid = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("=")
            exp = time.time() + UI_SESSION_DAYS * 86400
            UI_SESSIONS[sid] = {"user": name, "exp": exp}
            save_sessions()
            cookie = (
                "yy_sid=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax"
                % (sid, UI_SESSION_DAYS * 86400)
            )
            return self._json({"ok": True, "user": name}, extra={"Set-Cookie": cookie})
        if path == "/api/ui/logout":
            sid = self._sid()
            if sid:
                UI_SESSIONS.pop(sid, None)
                save_sessions()
            return self._json({"ok": True}, extra={"Set-Cookie": "yy_sid=; Path=/; Max-Age=0"})
        if path == "/api/ui/token":
            user0 = self._user()
            if not user0:
                return self._json({"error": "unauthorized"}, 401)
            try:
                body = json.loads(self._body().decode("utf-8-sig") or "{}")
            except Exception:
                return self._json({"error": "bad json"}, 400)
            new = (body.get("token") or "").strip()
            if not new:
                new = "yy-" + base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=").lower()
            if not re.match(r"^[A-Za-z0-9_\-]{6,64}$", new):
                return self._json({"error": "令牌只能用字母数字-_，6~64 位"}, 400)
            for tok in [t for t, u in list(TOKENS.items()) if u == user0]:
                TOKENS.pop(tok, None)
            TOKENS[new] = user0
            save_token_overrides()
            return self._json({"ok": True, "token": new, "user": user0})
        if path == "/api/ui/account":
            user0 = self._user()
            if not user0:
                return self._json({"error": "unauthorized"}, 401)
            try:
                body = json.loads(self._body().decode("utf-8-sig") or "{}")
            except Exception:
                return self._json({"error": "bad json"}, 400)
            nu = (body.get("username") or "").strip()
            np = (body.get("password") or "").strip()
            if len(nu) < 2 or len(np) < 4:
                return self._json({"error": "账号至少 2 位、密码至少 4 位"}, 400)
            save_ui_auth(nu, np)
            return self._json({"ok": True, "username": nu})
        if path == "/api/ui/me":
            u = self._user()
            if not u:
                return self._json({"error": "unauthorized"}, 401)
            return self._json({"user": u})
        user = self._require_user()
        if user is None:
            return
        udir = user_dir(user)
        if path == "/api/state":
            try:
                incoming = json.loads(self._body().decode("utf-8-sig"))
            except Exception:
                return self._json({"error": "bad json"}, 400)
            with LOCK:
                merged = merge_state(load_state(udir), incoming)
                save_state(udir, merged)
            return self._json({
                "ok": True,
                "user": user,
                "updatedAt": merged.get("updatedAt"),
                "books": len(merged.get("books", [])),
                "bookmarks": len(merged.get("bookmarks", [])),
            })
        if path == "/api/chapters":
            try:
                payload = json.loads(self._body().decode("utf-8-sig"))
            except Exception:
                return self._json({"error": "bad json"}, 400)
            try:
                path_key = str(payload.get("path") or "")
                idx = int(payload.get("index") or 0)
                images = payload.get("images") or []
                saved = []
                # 手机直接上传图片字节（已缓存漫画）：imagesBase64=[{name,data}]
                raw_b64 = payload.get("imagesBase64") or []
                if raw_b64:
                    folder0 = os.path.join(
                        chapters_dir(udir), chapter_key(path_key), "%06d" % idx
                    )
                    os.makedirs(folder0, exist_ok=True)
                    for n, item in enumerate(raw_b64):
                        try:
                            if isinstance(item, dict):
                                data_b64 = item.get("data") or ""
                                name = item.get("name") or "img.jpg"
                            else:
                                data_b64, name = str(item), "img.jpg"
                            ext = os.path.splitext(name)[1].lower() or ".jpg"
                            if ext not in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
                                ext = ".jpg"
                            blob = base64.b64decode(data_b64)
                            if not blob:
                                continue
                            with open(os.path.join(folder0, "%04d%s" % (n, ext)), "wb") as fh:
                                fh.write(blob)
                            saved.append(n)
                        except Exception as e3:
                            print("[chapter] base64 图片保存失败: %s" % e3)
                    payload["images"] = ["local:%d" % n for n in saved]
                if images:
                    folder = os.path.join(
                        chapters_dir(udir), chapter_key(path_key), "%06d" % idx
                    )
                    os.makedirs(folder, exist_ok=True)
                    for n, url in enumerate(images):
                        if not isinstance(url, str) or not url.startswith("http"):
                            continue
                        ext = ".jpg"
                        low = url.lower().split("?")[0]
                        for cand in (".png", ".webp", ".jpeg", ".gif"):
                            if low.endswith(cand):
                                ext = ".jpg" if cand == ".jpeg" else cand
                                break
                        dest = os.path.join(folder, "%04d%s" % (n, ext))
                        if os.path.isfile(dest) and os.path.getsize(dest) > 0:
                            saved.append(n)
                            continue
                        try:
                            download_image(url, payload.get("referer") or "", dest)
                            saved.append(n)
                        except Exception as e2:
                            print("[chapter] 图片下载失败 %s: %s" % (url, e2))
                    payload["images"] = [
                        "" for _ in range(len(images))
                    ]
                    for n in saved:
                        payload["images"][n] = "local:%d" % n
                data = save_chapter(udir, payload)
                return self._json({"ok": True, "index": data["index"], "images": len(saved)})
            except Exception as e:
                return self._json({"error": str(e)}, 400)
        if path == "/api/sources":
            try:
                data = json.loads(self._body().decode("utf-8-sig"))
            except Exception:
                return self._json({"error": "bad json"}, 400)
            if isinstance(data, dict) and isinstance(data.get("items"), list):
                data = data["items"]
            with open(os.path.join(udir, "sources.json"), "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False)
            return self._json({"ok": True, "count": len(data) if isinstance(data, list) else 0})
        if path == "/api/settings":
            try:
                data = json.loads(self._body().decode("utf-8-sig"))
            except Exception:
                return self._json({"error": "bad json"}, 400)
            with open(os.path.join(udir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False)
            return self._json({"ok": True})
        if path == "/api/backups":
            data = self._body()
            if not data:
                return self._json({"error": "empty"}, 400)
            if not zipfile.is_zipfile(io.BytesIO(data)):
                return self._json({"error": "not a zip"}, 400)
            name = "backup-%s.zip" % time.strftime("%Y%m%d-%H%M%S")
            with LOCK:
                with open(os.path.join(udir, "backups", name), "wb") as f:
                    f.write(data)
                prune_backups(udir)
            return self._json({"ok": True, "user": user, "name": name})
        return self._json({"error": "not found"}, 404)

    def do_PUT(self):
        path = urllib.parse.urlparse(self.path).path
        user = self._require_user()
        if user is None:
            return
        if path.startswith("/dav"):
            udir = user_dir(user)
            rel = path[len("/dav"):].lstrip("/")
            target = os.path.normpath(os.path.join(udir, "dav", rel))
            if not target.startswith(os.path.join(udir, "dav")):
                return self._json({"error": "bad path"}, 400)
            data = self._body()
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data)
            return self._send(201, b"")
        return self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        user = self._require_user()
        if user is None:
            return
        udir = user_dir(user)
        m = re.match(r"^/api/backups/(.+)$", path)
        if m:
            name = safe_name(m.group(1))
            p = os.path.join(udir, "backups", name)
            if os.path.isfile(p):
                os.remove(p)
                return self._json({"ok": True})
            return self._json({"error": "not found"}, 404)
        if path.startswith("/dav"):
            rel = path[len("/dav"):].lstrip("/")
            target = os.path.normpath(os.path.join(udir, "dav", rel))
            if not target.startswith(os.path.join(udir, "dav")):
                return self._json({"error": "bad path"}, 400)
            try:
                os.remove(target)
                return self._send(204, b"")
            except FileNotFoundError:
                return self._send(404, b"")
        return self._json({"error": "not found"}, 404)

    # ---------- WebDAV ----------
    def do_MKCOL(self):
        path = urllib.parse.urlparse(self.path).path
        user = self._require_user()
        if user is None:
            return
        udir = user_dir(user)
        rel = path[len("/dav"):].lstrip("/") if path.startswith("/dav") else ""
        target = os.path.normpath(os.path.join(udir, "dav", rel))
        if not target.startswith(os.path.join(udir, "dav")):
            return self._json({"error": "bad path"}, 400)
        if os.path.isdir(target):
            return self._send(405, b"")
        os.makedirs(target, exist_ok=True)
        return self._send(201, b"")

    def do_PROPFIND(self):
        path = urllib.parse.urlparse(self.path).path
        user = self._require_user()
        if user is None:
            return
        udir = user_dir(user)
        dav_root = os.path.join(udir, "dav")
        depth = (self.headers.get("Depth") or "1").strip()
        rel = path[len("/dav"):].lstrip("/") if path.startswith("/dav") else ""
        target = os.path.normpath(os.path.join(dav_root, rel))
        if not target.startswith(dav_root):
            return self._json({"error": "bad path"}, 400)
        if not os.path.exists(target):
            return self._send(404, b"")
        entries = [target]
        if depth != "0" and os.path.isdir(target):
            for name in sorted(os.listdir(target)):
                entries.append(os.path.join(target, name))
        parts = []
        for p in entries:
            is_dir = os.path.isdir(p)
            rel_path = os.path.relpath(p, dav_root).replace(os.sep, "/")
            href = "/dav/" + ("" if rel_path == "." else rel_path)
            if is_dir and not href.endswith("/"):
                href += "/"
            try:
                size = 0 if is_dir else os.path.getsize(p)
                mtime = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(os.path.getmtime(p)))
            except OSError:
                size, mtime = 0, time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime())
            parts.append(
                "<d:response><d:href>%s</d:href><d:propstat><d:prop>"
                "<d:resourcetype>%s</d:resourcetype>"
                "<d:getcontentlength>%d</d:getcontentlength>"
                "<d:getlastmodified>%s</d:getlastmodified>"
                "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                % (href, "<d:collection/>" if is_dir else "", size, mtime)
            )
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:">%s</d:multistatus>' % "".join(parts)
        ).encode("utf-8")
        self._send(207, body, "application/xml; charset=utf-8", {"DAV": "1,2"})

    def _dav_get(self, udir, path):
        dav_root = os.path.join(udir, "dav")
        rel = path[len("/dav"):].lstrip("/")
        target = os.path.normpath(os.path.join(dav_root, rel))
        if not target.startswith(dav_root) or not os.path.isfile(target):
            return self._send(404, b"")
        with open(target, "rb") as f:
            data = f.read()
        self._send(200, data, "application/octet-stream")

    def _static(self, name, ctype):
        p = os.path.join(ROOT, "static", name)
        if not os.path.isfile(p):
            return self._json({"error": "missing static file"}, 404)
        with open(p, "rb") as f:
            data = f.read()
        self._send(200, data, ctype)


def migrate_legacy():
    """老版本（单用户、直接放 DATA_DIR）的数据搬到 users/default。"""
    legacy_state = os.path.join(DATA_DIR, "state.json")
    target = user_dir("default")
    if os.path.isfile(legacy_state) and not os.path.isfile(state_file(target)):
        try:
            os.replace(legacy_state, state_file(target))
        except OSError:
            pass
    for sub in ("backups", "dav"):
        old = os.path.join(DATA_DIR, sub)
        new = os.path.join(target, sub)
        if os.path.isdir(old):
            try:
                for name in os.listdir(old):
                    src = os.path.join(old, name)
                    dst = os.path.join(new, name)
                    if not os.path.exists(dst):
                        os.replace(src, dst)
            except OSError:
                pass


def main():
    os.makedirs(USERS_DIR, exist_ok=True)
    UI_SESSIONS.update(load_sessions())
    apply_token_overrides()
    migrate_legacy()
    for name in set(TOKENS.values()):
        user_dir(name)
    if os.environ.get("PRUNE_ON_START", "1") == "1":
        with LOCK:
            for name in set(TOKENS.values()):
                prune_backups(user_dir(name))
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(
        "嘤阅同步服务已启动：http://0.0.0.0:%d  data=%s  用户=%d  备份保留=%d"
        % (PORT, DATA_DIR, len(set(TOKENS.values())), BACKUP_KEEP)
    )
    srv.serve_forever()


if __name__ == "__main__":
    main()
