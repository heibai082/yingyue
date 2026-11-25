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
import io
import json
import os
import re
import threading
import time
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("DATA_DIR", os.path.join(ROOT, "data"))
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "14"))
PORT = int(os.environ.get("PORT", "8090"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
USERS_DIR = os.path.join(DATA_DIR, "users")

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
    server_version = "YingYueSync/1.1"
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

    def _json(self, obj, code=200):
        self._send(code, obj)

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

    def _user(self):
        """命中的用户名；没命中的令牌返回 None。"""
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
        if path == "/app.js":
            return self._static("app.js", "application/javascript; charset=utf-8")
        if path == "/api/health":
            return self._json({"ok": True, "uptime": int(time.time() - STARTED_AT), "version": "1.1"})
        if path == "/api/config":
            return self._json({
                "name": "嘤阅同步",
                "version": "1.1",
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
                "devices": st.get("devices", {}),
                "recent": (st.get("books") or [])[:30],
                "backups": list_backups(udir),
                "stats": st.get("stats", {}),
            })
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
                    return self._json(json.load(fh))
                except Exception:
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
            with open(os.path.join(udir, "sources.json"), "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False)
            return self._json({"ok": True})
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
