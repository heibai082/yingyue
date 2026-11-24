// 漫画图片地址提取的回归测试（不联网）。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/online_book_service.dart';

void main() {
  const base = 'https://cn.bzmanga.com/user/page_direct?comic_id=x&chapter_slot=0';

  test('普通 <img src>：绝对地址原样取出（包子漫画的真实结构）', () {
    const html = '''
<div class="comic-contain">
  <img src="https://s1.bzcdn.net/scomic/abc/0/0-l07d/1.jpg" alt="第一页" width="1200" height="4200">
  <img src="https://s1.bzcdn.net/scomic/abc/0/0-l07d/2.jpg" alt="第二页" width="1200" height="4400">
</div>''';
    final urls = OnlineBookService.extractImageUrls(html, baseUrl: base);
    expect(urls, [
      'https://s1.bzcdn.net/scomic/abc/0/0-l07d/1.jpg',
      'https://s1.bzcdn.net/scomic/abc/0/0-l07d/2.jpg',
    ]);
  });

  test('懒加载：优先 data-src，src 里的占位图不要', () {
    const html = '<img src="/static/loading.png" data-src="/scomic/a/3.jpg">';
    final urls = OnlineBookService.extractImageUrls(html, baseUrl: base);
    expect(urls, ['https://cn.bzmanga.com/scomic/a/3.jpg']);
  });

  test('图标 / logo / gif / svg 这些杂图会被过滤', () {
    const html = '''
<img src="https://static-tw.baozimh.com/static/bzmh/img/apple-icon-57x57.png">
<img src="https://x.com/logo.png">
<img src="https://x.com/spacer.gif">
<img src="https://x.com/icon.svg">
<img src="https://s1.bzcdn.net/scomic/a/9.jpg">''';
    final urls = OnlineBookService.extractImageUrls(html, baseUrl: base);
    expect(urls, ['https://s1.bzcdn.net/scomic/a/9.jpg']);
  });

  test('规则直接给「一行一个地址」的纯文本也能解析', () {
    const text = 'https://s1.bzcdn.net/scomic/a/1.jpg\n'
        'https://s1.bzcdn.net/scomic/a/2.jpg\n'
        '  \nhttps://s1.bzcdn.net/scomic/a/3.jpg';
    final urls = OnlineBookService.extractImageUrls(text, baseUrl: base);
    expect(urls, hasLength(3));
  });

  test('相对地址按章节页补全', () {
    const html = '<img src="/scomic/a/5.jpg">';
    expect(
      OnlineBookService.extractImageUrls(html, baseUrl: base),
      ['https://cn.bzmanga.com/scomic/a/5.jpg'],
    );
  });

  test('没有图就返回空列表', () {
    expect(
      OnlineBookService.extractImageUrls('<p>纯文字章节</p>', baseUrl: base),
      isEmpty,
    );
  });
}
