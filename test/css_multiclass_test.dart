// 多 class 选择器回归测试（包子漫画这类源的搜索/目录规则全是这种写法）。
//
// 背景：`class.a b c` 在阅读 3.0 里表示「同时带 a、b、c 三个 class」，
// 而 CSS 里空格是后代选择器；直接丢给 package:html 会报错 → 搜索 0 本 / 目录为空。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/analyze_rule.dart';

const _searchHtml = '''
<html><body>
<div class="comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6">
  <a href="/comic/hanghaiwang-weitianrongyilang" aria-label="航海王" class="comics-card__info">
    <div class="comics-card__title text-truncate"><h3 class="text-truncate">航海王</h3></div>
    <small class="tags text-truncate">尾田荣一郎</small>
  </a>
</div>
<div class="comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6">
  <a href="/comic/hanghaiwangxueyuan" aria-label="航海王学园" class="comics-card__info">
    <div class="comics-card__title text-truncate"><h3 class="text-truncate">航海王学园</h3></div>
  </a>
</div>
<!-- 少几个 class 的卡片不算命中（必须同时带那三个 class） -->
<div class="comics-card">
  <div class="comics-card__title text-truncate"><h3>广告位</h3></div>
</div>
</body></html>''';

const _tocHtml = '''
<html><body>
<div class="pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters">
  <a href="/user/page_direct?comic_id=x&amp;section_slot=0&amp;chapter_slot=2"><span>第2话</span></a>
</div>
<div class="pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters">
  <a href="/user/page_direct?comic_id=x&amp;section_slot=0&amp;chapter_slot=1"><span>第1话</span></a>
</div>
<div class="comics-chapters"><a href="/nope"><span>不是章节</span></a></div>
</body></html>''';

void main() {
  test('搜索：class.a b c 当「同时带这几个 class」，只选到真正的卡片', () {
    final e = AnalyzeRule(_searchHtml, baseUrl: 'https://cn.bzmanga.com');
    final cards = e.getElements(
      'class.comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6',
    );
    expect(cards, hasLength(2));
  });

  test('搜索：卡片里的书名 / 链接能取出来（同一个 ctx 逐字段求值）', () {
    final e = AnalyzeRule(_searchHtml, baseUrl: 'https://cn.bzmanga.com');
    final cards = e.getElements(
      'class.comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6',
    );
    final names = <String>[];
    final urls = <String>[];
    for (final card in cards) {
      names.addAll(
        AnalyzeRule(
          _searchHtml,
          baseUrl: 'https://cn.bzmanga.com',
        ).getStrings('class.comics-card__title text-truncate@text', ctx: card),
      );
      urls.addAll(
        AnalyzeRule(
          _searchHtml,
          baseUrl: 'https://cn.bzmanga.com',
        ).getStrings(
          'class.comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6@tag.a@href',
          ctx: card,
        ),
      );
    }
    expect(names.first, '航海王');
    expect(urls.first, contains('hanghaiwang-weitianrongyilang'));
  });

  test('目录：chapterList 多 class 写法能选到章节，链接取原始 href', () {
    final e = AnalyzeRule(_tocHtml, baseUrl: 'https://cn.bzmanga.com');
    final items = e.getElements(
      'class.pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters',
    );
    expect(items, hasLength(2));
    final hrefs = <String>[];
    for (final item in items) {
      hrefs.addAll(
        AnalyzeRule(
          _tocHtml,
          baseUrl: 'https://cn.bzmanga.com',
        ).getStrings('tag.a@href', ctx: item),
      );
    }
    expect(hrefs, hasLength(2));
    expect(hrefs.first, contains('chapter_slot=2'));
  });

  test('带标签名的后代选择器没被改坏（.list div 仍然是后代）', () {
    const html = '<div class="list"><div class="item">A</div></div>'
        '<div class="item">B</div>';
    final e = AnalyzeRule(html, baseUrl: 'https://example.com');
    expect(e.getStrings('class.list div@text'), ['A']);
  });
}
