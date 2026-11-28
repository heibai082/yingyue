#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""迷你书源引擎（0.55）：让 Docker 网页端也能在线搜书 / 看目录 / 读正文。

支持的规则语法（覆盖内置书源与大多数 CSS 类源）：
  - 选择器：`tag`、`.class`、`#id`、`tag.class`、`tag.1`（第 N 个）、后代（`div.x ul li`）
  - 属性：`@text`、`@html`、`@href`、`@src`、`@title`、`@alt`、`@content`，以及嵌套 `dl.1@tag.dd`
  - 兜底：`a || b`（依次尝试）
  - 正则：`##pattern##replacement`
  - JSON：`$` / `$.a.b` / `$[*]` / `$.query.pages.*`（给 JSON 接口源用）
  - 不支持：`@xpath:`、`@js:`、需要登录/加密的源 —— 会明确报「这条源需要 App 的 WebView」

请求：searchUrl 支持 `,{"method":"POST","body":"q={{key}}","headers":{...}}` 这种 Legado 写法，
`{{key}}` / `{{page}}` 会替换；每个源一个 CookieJar，搜索→目录→正文共享。
"""

import base64
import gzip
import html as html_lib
import http.cookiejar
import json
import re
import urllib.parse
import urllib.request
from html.parser import HTMLParser

UA = (
    "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"
)


# ---------------- 极简 DOM ----------------
VOID_TAGS = {
    "br", "img", "hr", "input", "meta", "link", "source", "area", "base",
    "col", "embed", "param", "track", "wbr",
}


class Node:
    __slots__ = ("tag", "attrs", "children", "parent", "text_parts")

    def __init__(self, tag, attrs=None, parent=None):
        self.tag = tag
        self.attrs = dict(attrs or {})
        self.children = []
        self.parent = parent
        self.text_parts = []

    def text(self):
        out = []
        for p in self.text_parts:
            out.append(p)
        for c in self.children:
            out.append(c.text())
        return "".join(out)

    def html(self):
        attrs = "".join(
            ' %s="%s"' % (k, html_lib.escape(str(v), quote=True))
            for k, v in self.attrs.items()
        )
        if self.tag in VOID_TAGS:
            return "<%s%s>" % (self.tag, attrs)
        inner = "".join(html_lib.escape(p) for p in self.text_parts) + "".join(
            c.html() for c in self.children
        )
        return "<%s%s>%s</%s>" % (self.tag, attrs, inner, self.tag)

    def ancestors(self):
        n = self.parent
        while n is not None:
            yield n
            n = n.parent


class _DomBuilder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        node = Node(tag, attrs, self.stack[-1])
        self.stack[-1].children.append(node)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].text_parts.append(data)


def parse_html(text):
    b = _DomBuilder()
    try:
        b.feed(text or "")
        b.close()
    except Exception:
        pass
    return b.root


def iter_nodes(root):
    stack = [root]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(reversed(n.children))


def _simple_match(node, token):
    """token: tag / .class / #id / tag.class / tag#id / id.x / class.x / tag.x。"""
    token = token.strip()
    if not token or token == "*":
        return True
    # Legado 写法：id.xxx / class.xxx / tag.xxx
    if token.startswith("id."):
        return node.attrs.get("id") == token[3:]
    if token.startswith("class."):
        return token[6:] in (node.attrs.get("class") or "").split()
    if token.startswith("tag."):
        return node.tag == token[4:]
    cls = None
    idv = None
    tag = token
    m = re.match(r"^([A-Za-z0-9_\-]*)\.([A-Za-z0-9_\-]+)$", token)
    if m:
        tag, cls = m.group(1), m.group(2)
    m = re.match(r"^([A-Za-z0-9_\-]*)#([A-Za-z0-9_\-]+)$", token)
    if m:
        tag, idv = m.group(1), m.group(2)
    if tag and node.tag != tag:
        return False
    if cls:
        classes = (node.attrs.get("class") or "").split()
        if cls not in classes:
            return False
    if idv and node.attrs.get("id") != idv:
        return False
    return True


def _select(nodes, selector):
    """支持 `tag.class`、索引后缀 `.N`、后代空格；索引作用在「当前选择器结果」上。"""
    sel = selector.strip()
    if not sel:
        return nodes
    # 索引：`dl.1` / `.item.0`（最后一段是纯数字）
    index = None
    m = re.match(r"^(.*)\.(\d+)$", sel)
    if m and not m.group(1).endswith("."):
        sel, index = m.group(1), int(m.group(2))
    parts = [p for p in sel.split() if p]
    current = list(nodes)
    for part in parts:
        found = []
        for n in current:
            for d in iter_nodes(n):
                if d is n and part != "*":
                    # 自身也算（常见规则 class.x 直接指当前节点）
                    if _simple_match(n, part):
                        found.append(n)
                    continue
                if _simple_match(d, part):
                    found.append(d)
        current = found
    if index is not None:
        current = [current[index]] if 0 <= index < len(current) else []
    return current


# ---------------- 规则求值 ----------------
ATTRS = {"text", "html", "href", "src", "title", "alt", "content", "value", "data-src"}


def _apply_regex(value, expr):
    """`##pattern##replacement`（含 `###` 分隔）"""
    if "###" in expr:
        pattern, repl = expr.split("###", 1)
    elif expr.count("##") >= 2:
        _, pattern, repl = expr.split("##", 2)
    else:
        return value
    try:
        return re.sub(pattern, repl or "", value)
    except re.error:
        return value


def _unwrap_js(value):
    """有些规则会写 `a@href&tpl` 之类，这里只做基础的 `##` 处理。"""
    return value


def eval_rule(rule, html_text, base_url=""):
    """把一条规则在 HTML/JSON 上求值，返回字符串列表。"""
    if not rule or not rule.strip():
        return []
    rule = rule.strip()
    # 兜底：a || b
    if "||" in rule:
        for part in rule.split("||"):
            got = eval_rule(part.strip(), html_text, base_url)
            if got:
                return got
        return []

    # JSON 规则
    if rule.startswith("$") or rule.startswith("@json:"):
        return _eval_json(rule.lstrip("@json:").strip() if rule.startswith("@json:") else rule, html_text)

    # 明确不支持的
    if rule.startswith("@xpath:") or rule.startswith("@js:") or rule.startswith("@css:"):
        return []

    # 正则后处理
    regex_expr = None
    if "##" in rule:
        rule, _, rest = rule.partition("##")
        regex_expr = "##" + rest

    # 链式：selector@tag.x@attr@attr2
    parts = [p for p in rule.split("@") if p]
    if not parts:
        return []
    nodes = [parse_html(html_text)]
    attr = "text"
    for i, part in enumerate(parts):
        p = part.strip()
        if p in ATTRS:
            attr = p
            continue
        if p.startswith("tag.") or p.startswith("class.") or p.startswith("id."):
            # 嵌套选择：tag.dd / class.x
            nodes = _select(nodes, p)
            attr = "text"
            continue
        # 第一段或普通选择器
        nodes = _select(nodes, p)
        attr = "text"
    out = []
    for n in nodes:
        if attr == "text":
            v = n.text()
        elif attr == "html":
            v = n.html()
        else:
            v = n.attrs.get(attr, "")
        v = re.sub(r"\s+", " ", v or "").strip()
        if regex_expr:
            v = _apply_regex(v, regex_expr)
        if v:
            out.append(v)
    return out


def _eval_json(path, text):
    try:
        data = json.loads(text.lstrip("\ufeff"))
    except Exception:
        return []
    cur = [data]
    parts = [p for p in path.strip().lstrip("$").split(".") if p]
    for part in parts:
        nxt = []
        for item in cur:
            if part == "*":
                if isinstance(item, list):
                    nxt.extend(item)
                elif isinstance(item, dict):
                    nxt.extend(item.values())
                continue
            m = re.match(r"^([^\[]+)\[(\d+|\*)\]$", part)
            if m:
                key, idx = m.group(1), m.group(2)
                val = item.get(key) if isinstance(item, dict) else None
                if isinstance(val, list):
                    if idx == "*":
                        nxt.extend(val)
                    else:
                        i = int(idx)
                        if 0 <= i < len(val):
                            nxt.append(val[i])
                continue
            if isinstance(item, dict) and part in item:
                nxt.append(item[part])
        cur = nxt
    out = []
    for v in cur:
        if isinstance(v, (str, int, float)):
            out.append(str(v))
        elif isinstance(v, list):
            out.extend(str(x) for x in v if isinstance(x, (str, int, float)))
    return out


# ---------------- 请求 ----------------
class SourceSession:
    """一个源一个会话（Cookie 共享）。"""

    def __init__(self, source):
        self.source = source
        self.jar = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPCookieProcessor(self.jar)]
        self.opener = urllib.request.build_opener(*handlers)
        self.base = (source.get("bookSourceUrl") or "").rstrip("/")

    def headers(self):
        h = {"User-Agent": UA}
        raw = self.source.get("header")
        if isinstance(raw, str) and raw.strip():
            try:
                h.update({str(k): str(v) for k, v in json.loads(raw).items()})
            except Exception:
                pass
        return h

    def fetch(self, url, method="GET", body=None, extra_headers=None, timeout=15):
        full = urllib.parse.urljoin(self.base + "/", url) if not url.startswith("http") else url
        data = body.encode("utf-8") if isinstance(body, str) else body
        req = urllib.request.Request(full, data=data, method=method)
        for k, v in self.headers().items():
            req.add_header(k, v)
        for k, v in (extra_headers or {}).items():
            req.add_header(k, str(v))
        with self.opener.open(req, timeout=timeout) as r:
            raw = r.read()
            if r.headers.get("Content-Encoding") == "gzip":
                try:
                    raw = gzip.decompress(raw)
                except Exception:
                    pass
            enc = "utf-8"
            ctype = r.headers.get("Content-Type") or ""
            m = re.search(r"charset=([\w\-]+)", ctype, re.I)
            if m:
                enc = m.group(1)
            try:
                text = raw.decode(enc, "replace")
            except LookupError:
                text = raw.decode("utf-8", "replace")
            return text, r.geturl(), raw, r.headers


def parse_search_url(spec, key, page=1):
    """把 `url,{json}` 拆成 (url, method, body, headers)。"""
    spec = (spec or "").strip()
    opts = {}
    if "," in spec:
        url_part, _, rest = spec.partition(",")
        rest = rest.strip()
        if rest.startswith("{"):
            try:
                opts = json.loads(rest)
            except Exception:
                opts = {}
        spec = url_part
    url = spec.replace("{{key}}", urllib.parse.quote(key)).replace(
        "{{page}}", str(page)
    )
    method = (opts.get("method") or "GET").upper()
    body = opts.get("body")
    if isinstance(body, str):
        body = body.replace("{{key}}", urllib.parse.quote(key)).replace(
            "{{page}}", str(page)
        )
    headers = opts.get("headers") or {}
    return url, method, body, headers


def search_source(source, key, page=1, timeout=12):
    session = SourceSession(source)
    url, method, body, headers = parse_search_url(
        source.get("searchUrl"), key, page
    )
    text, final_url, _, _ = session.fetch(
        url, method=method, body=body, extra_headers=headers, timeout=timeout
    )
    rs = source.get("ruleSearch") or {}
    list_rule = (rs.get("bookList") or "").strip()
    if not list_rule:
        return []
    # JSON 源：按 bookList 取每条
    if list_rule.startswith("$"):
        items = _json_items(list_rule, text)
        out = []
        for item in items:
            rec = _json_record(rs, item, final_url)
            if rec and rec.get("name") and rec.get("bookUrl"):
                out.append(rec)
        return out
    # HTML 源
    root = parse_html(text)
    nodes = _select([root], list_rule)
    out = []
    for n in nodes:
        rec = _html_record(rs, n, final_url)
        if rec and rec.get("name") and rec.get("bookUrl"):
            out.append(rec)
    return out


def _json_items(list_rule, text):
    """bookList 形如 `$[*]` / `$.query.pages.*` / `$.data.list[*]`。"""
    try:
        data = json.loads(text.lstrip("\ufeff"))
    except Exception:
        return []
    path = list_rule.strip().lstrip("$")
    cur = data
    for part in [p for p in path.split(".") if p]:
        m = re.match(r"^([^\[]*)(?:\[(\*|\d+)\])?$", part)
        if not m:
            return []
        key, idx = m.group(1), m.group(2)
        if key:
            if not isinstance(cur, dict) or key not in cur:
                return []
            cur = cur[key]
        if idx == "*":
            if isinstance(cur, list):
                return cur
            if isinstance(cur, dict):
                return list(cur.values())
            return []
        if idx is not None:
            i = int(idx)
            if isinstance(cur, list) and 0 <= i < len(cur):
                cur = cur[i]
            else:
                return []
    if isinstance(cur, list):
        return cur
    if isinstance(cur, dict):
        return list(cur.values())
    return []


def _pick(rule, ctx, base_url):
    """HTML 记录：在当前节点上求值。"""
    if not rule:
        return ""
    parts = [p for p in rule.split("@") if p]
    if not parts:
        return ""
    nodes = [ctx]
    attr = "text"
    for p in parts:
        p = p.strip()
        if p in ATTRS:
            attr = p
            continue
        nodes = _select(nodes, p)
    if not nodes:
        return ""
    n = nodes[0]
    v = n.text() if attr == "text" else (n.html() if attr == "html" else n.attrs.get(attr, ""))
    v = re.sub(r"\s+", " ", v or "").strip()
        # 相对地址补全
    if attr in ("href", "src") and v and not v.startswith("http"):
        v = urllib.parse.urljoin(base_url, v)
    return v


def _pick_json(rule, item):
    """JSON 记录：`$.title` 之类。"""
    if not rule:
        return ""
    r = rule.strip()
    if not r.startswith("$"):
        return ""
    parts = [p for p in r.lstrip("$").split(".") if p]
    cur = item
    for p in parts:
        if not isinstance(cur, dict) or p not in cur:
            return ""
        cur = cur[p]
    return str(cur) if isinstance(cur, (str, int, float)) else ""


def _json_record(rs, item, base_url):
    name = _pick_json(rs.get("name"), item)
    book_url = _pick_json(rs.get("bookUrl"), item)
    if book_url and not book_url.startswith("http"):
        book_url = urllib.parse.urljoin(base_url, book_url)
    return {
        "name": name,
        "author": _pick_json(rs.get("author"), item),
        "intro": _pick_json(rs.get("intro"), item),
        "bookUrl": book_url,
        "coverUrl": _pick_json(rs.get("coverUrl"), item),
        "kind": _pick_json(rs.get("kind"), item),
        "lastChapter": _pick_json(rs.get("lastChapter"), item),
    }


def _html_record(rs, node, base_url):
    return {
        "name": _pick(rs.get("name"), node, base_url),
        "author": _pick(rs.get("author"), node, base_url),
        "intro": _pick(rs.get("intro"), node, base_url),
        "bookUrl": _pick(rs.get("bookUrl"), node, base_url),
        "coverUrl": _pick(rs.get("coverUrl"), node, base_url),
        "kind": _pick(rs.get("kind"), node, base_url),
        "lastChapter": _pick(rs.get("lastChapter"), node, base_url),
    }



# ---------------- 目录排序（卷 / 话 混排的站点） ----------------
_VOL_RE = re.compile("卷")
_CHAP_RE = re.compile("[话話回章節节集部篇]")
_NUM_RE = re.compile(r"第\s*(\d+(?:\.\d+)?)")


def _chap_number(title):
    m = _NUM_RE.search(title or "")
    if not m:
        m2 = re.match(r"\s*(\d+(?:\.\d+)?)", title or "")
        if not m2:
            return None
        return float(m2.group(1))
    return float(m.group(1))


def _chap_kind(title):
    if _VOL_RE.search(title or ""):
        return 0
    if _CHAP_RE.search(title or ""):
        return 1
    return 2


def sort_chapters(chapters, newest_first):
    """去重 + 排序：漫画按「卷 → 话」分组，组内按序号降序；小说只去重。"""
    if len(chapters) < 2:
        return chapters
    nums = [_chap_number(c.get("title", "")) for c in chapters]
    known = sum(1 for n in nums if n is not None)
    if known < len(chapters) * 0.8:
        return chapters
    kept = []
    seen_keys = set()
    seen_urls = set()
    for c, n in zip(chapters, nums):
        if n is not None:
            key = (_chap_kind(c.get("title", "")), n)
            if key in seen_keys:
                continue
            seen_keys.add(key)
            kept.append((c, n))
        else:
            u = c.get("url") or ""
            if u and u in seen_urls:
                continue
            if u:
                seen_urls.add(u)
            kept.append((c, -1.0))
    if not newest_first:
        return [c for c, _ in kept]
    indexed = list(enumerate(kept))
    indexed.sort(
        key=lambda pair: (
            _chap_kind(pair[1][0].get("title", "")),
            -pair[1][1],
            pair[0],
        )
    )
    return [c for _, (c, _n) in indexed]


def fetch_toc(source, book_url, timeout=20):
    session = SourceSession(source)
    text, final_url, _, _ = session.fetch(book_url, timeout=timeout)
    rt = source.get("ruleToc") or {}
    list_rule = (rt.get("chapterList") or "").strip()
    name_rule = (rt.get("chapterName") or "").strip()
    url_rule = (rt.get("chapterUrl") or "").strip()
    root = parse_html(text)
    nodes = _select([root], list_rule) if list_rule else []
    chapters = []
    for n in nodes:
        title = _pick(name_rule or "tag.a@text", n, final_url)
        href = _pick(url_rule or "tag.a@href", n, final_url)
        if title and href:
            chapters.append({"title": title, "url": href})
    chapters = sort_chapters(chapters, source.get("bookSourceType") == 2)
    return {"title": "", "chapters": chapters, "finalUrl": final_url}



# ---------------- <js> 规则：常见「params + AES」漫画站 ----------------
def _extract_js_key(js):
    m = re.search(r"java\.lang\.String\(['\"]([^'\"]+)['\"]\)", js)
    return m.group(1).encode("utf-8") if m else b""


def _js_decrypt_images(js, html, base_url):
    """支持 `params = 'base64'` + AES/CBC 的站点（漫画团这类）。"""
    m = re.search(r"params\s*=\s*['\"]([^'\"]+)['\"]", html)
    if not m:
        return []
    key = _extract_js_key(js)
    if not key:
        return []
    text_b64 = m.group(1)
    # JS 字符串里的转义：\/ \u002b \u003d 之类
    text_b64 = text_b64.replace("\\/", "/")
    text_b64 = re.sub(r"\\u([0-9a-fA-F]{4})", lambda x: chr(int(x.group(1), 16)), text_b64)
    text_b64 = text_b64.replace("\\n", "").replace("\\r", "")
    try:
        raw = base64.b64decode(text_b64 + "=" * (-len(text_b64) % 4))
    except Exception as e:
        print("[js] base64 解码失败: %s" % e)
        return []
    if len(raw) < 32:
        return []
    iv, ct = raw[:16], raw[16:]
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        data = dec.update(ct) + dec.finalize()
        pad = data[-1]
        if 0 < pad <= 16:
            data = data[:-pad]
        obj = json.loads(data.decode("utf-8", "replace"))
    except Exception as e:
        print("[js] 解密失败: %s" % e)
        return []
    arr = obj.get("chapter_images") or []
    host = ((obj.get("images_hosts") or [""])[0] or "").rstrip("/")
    out = []
    for u in arr:
        u = str(u)
        if not u.startswith("http"):
            if host:
                u = host + "/" + base64.b64encode(u.encode()).decode()
            else:
                u = urllib.parse.urljoin(base_url, u)
        out.append(u)
    return out


def fetch_content(source, chapter_url, timeout=25):
    session = SourceSession(source)
    text, final_url, _, _ = session.fetch(chapter_url, timeout=timeout)
    rc = source.get("ruleContent") or {}
    content_rule = (rc.get("content") or "").strip()
    if content_rule.startswith("$"):
        vals = eval_rule(content_rule, text)
        plain = "\n".join(vals)
        return {"title": "", "text": plain, "images": []}
    # <js> 规则：交给专门的解密器，解不出来就明确返回空（别退回整页抓 logo）
    if content_rule.startswith("<js>") or content_rule.startswith("<JS>"):
        js = content_rule[4:]
        js = js.split("</js>")[0].split("</JS>")[0]
        imgs = _js_decrypt_images(js, text, final_url)
        return {"title": "", "text": "", "images": imgs}

    root = parse_html(text)
    nodes = _select([root], content_rule) if content_rule else [root]
    if content_rule and not nodes:
        # 规则不匹配就返回空，不要拿整页图片冒充正文
        return {"title": "", "text": "", "images": []}
    # 图片：内容节点里的 img
    images = []
    for n in nodes:
        for d in iter_nodes(n):
            if d.tag == "img":
                src = d.attrs.get("data-src") or d.attrs.get("src") or ""
                if src:
                    images.append(urllib.parse.urljoin(final_url, src))
    # 正文：保留段落换行
    plain_parts = []
    for n in nodes:
        plain_parts.append(_block_text(n))
    plain = "\n".join(p for p in plain_parts if p).strip()
    # 图片占位标记（网页端优先渲染图片）
    return {"title": "", "text": plain, "images": images}


def _block_text(node):
    out = []
    for d in iter_nodes(node):
        if d.tag in ("p", "div", "br", "li", "h1", "h2", "h3", "tr"):
            out.append("\n")
        if d.text_parts:
            out.append("".join(d.text_parts))
    text = "".join(out).replace("\ufeff", "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t\u00a0]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()
