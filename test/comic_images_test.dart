// 漫画图片地址提取的回归测试（不联网）。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/online_book_service.dart';

void main() {
  const base =
      'https://cn.bzmanga.com/user/page_direct?comic_id=x&chapter_slot=0';

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
    const text =
        'https://s1.bzcdn.net/scomic/a/1.jpg\n'
        'https://s1.bzcdn.net/scomic/a/2.jpg\n'
        '  \nhttps://s1.bzcdn.net/scomic/a/3.jpg';
    final urls = OnlineBookService.extractImageUrls(text, baseUrl: base);
    expect(urls, hasLength(3));
  });

  test('相对地址按章节页补全', () {
    const html = '<img src="/scomic/a/5.jpg">';
    expect(OnlineBookService.extractImageUrls(html, baseUrl: base), [
      'https://cn.bzmanga.com/scomic/a/5.jpg',
    ]);
  });

  test('没有图就返回空列表', () {
    expect(
      OnlineBookService.extractImageUrls('<p>纯文字章节</p>', baseUrl: base),
      isEmpty,
    );
  });

  test('标签上声明 1×1 的图是占位/广告，直接丢掉（包子漫画新话就靠这张）。', () {
    const html = '''
<ul class="comic-contain">
  <amp-img width="1" height="1" src="https://s1.bzcdn.net/scomic/other-comic/0/1/1.jpg"
      data-src="https://s1.bzcdn.net/scomic/other-comic/0/1/1.jpg"></amp-img>
  <amp-img width="1280" height="1869" src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1.jpg"
      data-src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1.jpg"></amp-img>
</ul>''';
    expect(OnlineBookService.extractImageUrls(html, baseUrl: base), [
      'https://s2.bzcdn.net/scomic/hanghaiwang/0/1.jpg',
    ]);
  });

  test('章节地址里的 comic_id 能抽成「这本书」的标识（去掉 _xxxxx 变体后缀）', () {
    expect(
      OnlineBookService.comicSlug(
        'https://cn.bzmanga.com/user/page_direct?comic_id='
        'hanghaiwang-weitianrongyilang_i6wg8y&section_slot=0&chapter_slot=1185',
      ),
      'hanghaiwang-weitianrongyilang',
    );
    expect(
      OnlineBookService.comicSlug('https://cn.bzmanga.com/comic/hanghaiwang-x'),
      'hanghaiwang-x',
    );
  });

  test('新话网页版只给「别人的漫画 + 猜你喜欢封面」→ 全部过滤掉（实测页面）', () {
    // cn.bzmanga.com 第1186话（最新一话）网页版真实内容
    const gated = [
      'https://s1.bzcdn.net/scomic/meishaonianbangjiashijian-aojianyixi2/0/2-df6a/1.jpg',
      'https://static-tw.baozimh.com/cover/dianjingmengqi-jimanwenhua.jpg',
      'https://static-tw.baozimh.com/cover/xunzhaomanyue-chongcunyoucai.jpg',
      'https://static-tw.baozimh.com/cover/lanseyanhua-dotdot.jpg',
    ];
    expect(
      OnlineBookService.filterChapterImages(
        gated,
        'https://cn.bzmanga.com/user/page_direct?comic_id='
        'hanghaiwang-weitianrongyilang_i6wg8y&section_slot=0&chapter_slot=1186',
      ),
      isEmpty,
      reason: '广告 + 封面墙都不是正文，宁可提示「没图」也别放别人的漫画',
    );
  });

  test('正常章节：同一本漫画的 18 张全留下', () {
    final urls = [
      for (var i = 1; i <= 18; i++)
        'https://s2.bzcdn.net/scomic/hanghaiwang-weitianrongyilang/0/1186-mbfe/$i.jpg',
    ];
    expect(
      OnlineBookService.filterChapterImages(
        urls,
        'https://cn.bzmanga.com/user/page_direct?comic_id='
        'hanghaiwang-weitianrongyilang_i6wg8y&section_slot=0&chapter_slot=1185',
      ),
      hasLength(18),
    );
  });

  test('<amp-img> 的图也要认（包子漫画真实结构，之前整话都取不到）', () {
    const html = '''
<ul class="comic-contain">
  <amp-img id="chapter-img-0-0" width="1280" height="1869"
      src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/1.jpg"
      layout="responsive"
      data-src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/1.jpg"
      class="comic-contain__item"></amp-img>
  <amp-img id="chapter-img-0-1" width="1280" height="1900"
      src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/2.jpg"
      layout="responsive"
      data-src="https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/2.jpg"
      class="comic-contain__item"></amp-img>
</ul>''';
    final urls = OnlineBookService.extractImageUrls(html, baseUrl: base);
    expect(urls, [
      'https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/1.jpg',
      'https://s2.bzcdn.net/scomic/hanghaiwang/0/1186-mbfe/2.jpg',
    ]);
  });
}
