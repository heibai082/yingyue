import pathlib

p = pathlib.Path(r"D:\dev\sakura-read\sync-server\server.py")
s = p.read_text(encoding="utf-8")
old = '                "recent": (st.get("books") or [])[:30],'
new = (
    '                "recent": sorted('
    'st.get("books") or [], '
    'key=lambda b: int(b.get("lastReadAt") or 0), '
    'reverse=True)[:30],'
)
print("found:", old in s)
s = s.replace(old, new, 1)
p.write_text(s, encoding="utf-8")
import ast

ast.parse(s)
print("ok")
