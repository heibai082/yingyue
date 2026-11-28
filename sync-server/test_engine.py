# -*- coding: utf-8 -*-
"""迷你书源引擎的单测（直接 python 运行，不依赖 pytest）。"""
import unittest

import source_engine as se

HTML = """
<html><body>
<div class="box"><a class="title" href="/b/1">书一</a><span class="author">作者一</span></div>
<div class="box"><a class="title" href="/b/2">书二</a><span class="author">作者二</span></div>
<dl><dd><a href="/c/1">第1章</a></dd><dd><a href="/c/2">第2章</a></dd></dl>
<div id="content"><p>第一段</p><p>第二段</p></div>
</body></html>
"""


class EngineTest(unittest.TestCase):
    def test_select_class_and_nth(self):
        root = se.parse_html(HTML)
        self.assertEqual(len(se._select([root], "class.box")), 2)
        self.assertEqual(len(se._select([root], "class.box.0")), 1)
        self.assertEqual(len(se._select([root], "dl dd")), 2)

    def test_attr_and_text(self):
        root = se.parse_html(HTML)
        self.assertEqual(se.eval_rule("class.title@text", HTML), ["书一", "书二"])
        self.assertEqual(se.eval_rule("class.title@href", HTML), ["/b/1", "/b/2"])
        self.assertEqual(se.eval_rule("id.content@text", HTML), ["第一段第二段"])

    def test_or_fallback(self):
        self.assertEqual(
            se.eval_rule("id.nope@text || id.content@text", HTML),
            ["第一段第二段"],
        )

    def test_json_path(self):
        text = '{"data":{"list":[{"name":"A","url":"/a"},{"name":"B","url":"/b"}]}}'
        self.assertEqual(se.eval_rule("$.data.list[*].name", text), ["A", "B"])

    def test_regex_post(self):
        self.assertEqual(se.eval_rule("id.content@text##第##", HTML), ["一段二段"])

    def test_unsupported_rule_returns_empty(self):
        self.assertEqual(se.eval_rule("@js:xxx", HTML), [])

    def test_parse_search_url(self):
        url, method, body, headers = se.parse_search_url(
            '/s?q={{key}},{"method":"POST","body":"q={{key}}","headers":{"X":"1"}}',
            "你好",
        )
        self.assertEqual(method, "POST")
        self.assertIn("%E4%BD%A0%E5%A5%BD", url)
        self.assertIn("%E4%BD%A0%E5%A5%BD", body)
        self.assertEqual(headers.get("X"), "1")



    def test_sort_mixed_volume_and_chapter(self):
        raw = [
            {"title": t, "url": "u%d" % i}
            for i, t in enumerate(
                ["第10卷", "第09卷", "第41话", "第07卷", "第38话", "第2话", "第1话"]
            )
        ]
        out = se.sort_chapters(raw, True)
        titles = [c["title"] for c in out]
        # 卷/话混排：无视类型，按序号升序
        self.assertEqual(titles[:3], ["第1话", "第2话", "第07卷"])
        self.assertEqual(titles[-2:], ["第38话", "第41话"])

    def test_sort_novel_keeps_order_and_dedupes(self):
        raw = [
            {"title": t, "url": "n%d" % i}
            for i, t in enumerate(["第1章", "第2章", "第3章", "第2章"])
        ]
        out = se.sort_chapters(raw, False)
        self.assertEqual([c["title"] for c in out], ["第1章", "第2章", "第3章"])


if __name__ == "__main__":
    unittest.main()
