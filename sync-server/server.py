#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""嘤阅同步服务（单文件，只用标准库，方便 Docker 里跑）。

能力：
  - REST 状态同步：GET/POST /api/state（书架进度、书签、阅读统计，按时间取新合并）
  - 备份：GET/POST /api/backups、下载/删除、自动保留最近 N 份
  - WebDAV 子集（/dav/）：OPTIONS / PROPFIND / MKCOL / PUT / GET / DELETE，
    所以 App 里原来的「WebDAV 备份」也能直接指到这里
  - macOS / iOS 风格的网页面板（/）: 看设备、看最新进度、下备份、删备份

环境变量：
  SYNC_TOKEN   访问令牌（默认 yingyue，建议改）
  DATA_DIR     数据目录（默认 /data，本地跑用 ./data）
  BACKUP_KEEP  云端保留备份份数（默认 14）
  PORT         端口（默认 8090）
"""

import base64
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
BACKUP_DIR = os.path.join(DATA_DIR, "backups")
DAV_DIR = os.path.join(DATA_DIR, "dav")
STATE_FILE = os.path.join(DATA_DIR, "state.json")
TOKEN = os.environ.get("SYNC_TOKEN", "yingyue")
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "14"))
PORT = int(os.environ.get("PORT", "8090"))

LOCK = threading.Lock()
STARTED_AT = time.time()


def ensure_dirs():
    for d in (DATA_DIR, BACKUP_DIR, DAV_DIR):
        os.makedirs(d, exist_ok=True)


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {"version": 1, "updatedAt": 0, "books": [], "bookmarks": [], "devices": {}, "stats": {}}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE_FILE)


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
    inc_stats = incoming.get("stats") if isinstance(incoming.get("stats"), dict) else {}
    stats["totalSeconds"] = max(int(stats.get("totalSeconds") or 0), int(inc_stats.get("totalSeconds") or 0))
    stats["finishedBooks"] = max(int(stats.get("finishedBooks") or 0), int(inc_stats.get("finishedBooks") or 0))
    days = stats.get("days") if isinstance(stats.get("days"), dict) else {}
    for k, v in (inc_stats.get("days") or {}).items():
        try:
            days[k] = max(int(days.get(k) or 0), int(v or 0))
        except Exception:
            continue
    stats["days"] = days
    cur["stats"] = stats

    devices = cur.get("devices") if isinstance(cur.get("devices"), dict) else {}
    incoming_devices = incoming.get("devices") if isinstance(incoming.get("devices"), dict) else {}
    for name, info in incoming_devices.items():
        if isinstance(info, dict):
            merged = dict(devices.get(name) or {})
            merged.update(info)
            merged["lastSeen"] = now
            devices[name] = merged
    cur["devices"] = devices
    cur["version"] = 1
    cur["updatedAt"] = now
    return cur


def list_backups():
    out = []
    try:
        names = os.listdir(BACKUP_DIR)
    except FileNotFoundError:
        return out
    for name in names:
        if not name.lower().endswith(".zip"):
            continue
        p = os.path.join(BACKUP_DIR, name)
        try:
            st = os.stat(p)
            out.append({"name": name, "size": st.st_size, "mtime": int(st.st_mtime)})
        except OSError:
            continue
    out.sort(key=lambda b: b["mtime"], reverse=True)
    return out


def prune_backups():
    items = list_backups()
    for b in items[BACKUP_KEEP:]:
        try:
            os.remove(os.path.join(BACKUP_DIR, b["name"]))
        except OSError:
            pass


def safe_name(name):
    name = urllib.parse.unquote(name)
    name = os.path.basename(name)
    return re.sub(r"[^0-9A-Za-z._\-\u4e00-\u9fff]", "_", name)


class Handler(BaseHTTPRequestHandler):
    server_version = "YingYueSync/1.0"
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

    def _auth_ok(self):
        if not TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer ") and auth[7:].strip() == TOKEN:
            return True
        if auth.startswith("Basic "):
            try:
                raw = base64.b64decode(auth[6:]).decode("utf-8", "replace")
                _, _, pw = raw.partition(":")
                if pw == TOKEN:
                    return True
            except Exception:
                pass
        if self.headers.get("X-Token", "") == TOKEN:
            return True
        q = urllib.parse.urlparse(self.path).query
        if urllib.parse.parse_qs(q).get("token", [""])[0] == TOKEN:
            return True
        return False

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
            return self._json({"ok": True, "uptime": int(time.time() - STARTED_AT), "version": "1.0"})
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        if path == "/api/state":
            with LOCK:
                return self._json(load_state())
        if path == "/api/summary":
            with LOCK:
                st = load_state()
            return self._json({
                "updatedAt": st.get("updatedAt", 0),
                "books": len(st.get("books", [])),
                "bookmarks": len(st.get("bookmarks", [])),
                "devices": st.get("devices", {}),
                "recent": (st.get("books") or [])[:30],
                "backups": list_backups(),
                "stats": st.get("stats", {}),
            })
        if path == "/api/backups":
            return self._json({"items": list_backups()})
        m = re.match(r"^/api/backups/(.+)$", path)
        if m:
            name = safe_name(m.group(1))
            p = os.path.join(BACKUP_DIR, name)
            if not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            with open(p, "rb") as f:
                data = f.read()
            return self._send(200, data, "application/zip", {"Content-Disposition": 'attachment; filename="%s"' % name})
        if path.startswith("/dav"):
            return self._dav_get(path)
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        if path == "/api/state":
            try:
                incoming = json.loads(self._body().decode("utf-8-sig"))
            except Exception:
                return self._json({"error": "bad json"}, 400)
            with LOCK:
                cur = load_state()
                merged = merge_state(cur, incoming)
                save_state(merged)
            return self._json({
                "ok": True,
                "updatedAt": merged.get("updatedAt"),
                "books": len(merged.get("books", [])),
                "bookmarks": len(merged.get("bookmarks", [])),
            })
        if path == "/api/backups":
            data = self._body()
            if not data:
                return self._json({"error": "empty"}, 400)
            if not zipfile.is_zipfile(__import__("io").BytesIO(data)):
                return self._json({"error": "not a zip"}, 400)
            name = "backup-%s.zip" % time.strftime("%Y%m%d-%H%M%S")
            with LOCK:
                with open(os.path.join(BACKUP_DIR, name), "wb") as f:
                    f.write(data)
                prune_backups()
            return self._json({"ok": True, "name": name})
        return self._json({"error": "not found"}, 404)

    def do_PUT(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        if path.startswith("/dav"):
            rel = path[len("/dav"):].lstrip("/")
            target = os.path.normpath(os.path.join(DAV_DIR, rel))
            if not target.startswith(DAV_DIR):
                return self._json({"error": "bad path"}, 400)
            data = self._body()
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data)
            return self._send(201, b"")
        return self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        m = re.match(r"^/api/backups/(.+)$", path)
        if m:
            name = safe_name(m.group(1))
            p = os.path.join(BACKUP_DIR, name)
            if os.path.isfile(p):
                os.remove(p)
                return self._json({"ok": True})
            return self._json({"error": "not found"}, 404)
        if path.startswith("/dav"):
            rel = path[len("/dav"):].lstrip("/")
            target = os.path.normpath(os.path.join(DAV_DIR, rel))
            if not target.startswith(DAV_DIR):
                return self._json({"error": "bad path"}, 400)
            try:
                os.remove(target)
                return self._send(204, b"")
            except FileNotFoundError:
                return self._send(404, b"")
        return self._json({"error": "not found"}, 404)

    # ---------- WebDAV（够 App 用） ----------
    def do_MKCOL(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        rel = path[len("/dav"):].lstrip("/") if path.startswith("/dav") else ""
        target = os.path.normpath(os.path.join(DAV_DIR, rel))
        if not target.startswith(DAV_DIR):
            return self._json({"error": "bad path"}, 400)
        if os.path.isdir(target):
            return self._send(405, b"")
        os.makedirs(target, exist_ok=True)
        return self._send(201, b"")

    def do_PROPFIND(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._auth_ok():
            return self._json({"error": "unauthorized"}, 401)
        depth = (self.headers.get("Depth") or "1").strip()
        rel = path[len("/dav"):].lstrip("/") if path.startswith("/dav") else ""
        target = os.path.normpath(os.path.join(DAV_DIR, rel))
        if not target.startswith(DAV_DIR):
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
            rel_path = os.path.relpath(p, DAV_DIR).replace(os.sep, "/")
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

    def _dav_get(self, path):
        rel = path[len("/dav"):].lstrip("/")
        target = os.path.normpath(os.path.join(DAV_DIR, rel))
        if not target.startswith(DAV_DIR) or not os.path.isfile(target):
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


def main():
    ensure_dirs()
    if os.environ.get("PRUNE_ON_START", "1") == "1":
        with LOCK:
            prune_backups()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("嘤阅同步服务已启动：http://0.0.0.0:%d  data=%s  备份保留=%d" % (PORT, DATA_DIR, BACKUP_KEEP))
    srv.serve_forever()


if __name__ == "__main__":
    main()
