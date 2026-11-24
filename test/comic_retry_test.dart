// 取不到图时的「重试一次 + 说清为什么」：用 MockClient 模拟包子漫画的空壳页和正常页。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sakura_read/src/source/http_client.dart';
import 'package:sakura_read/src/source/models.dart';
import 'package:sakura_read/src/source/online_book_service.dart';

const _chapterUrl =
    'https://cn.bzmanga.com/user/page_direct?comic_id=hanghaiwang-weitianrongyilang'
    '&section_slot=0&chapter_slot=1152';

const _fullPage = '''
<html><body><ul class="comic-contain">
  <amp-img width="1280" height="1869" data-src="https://s1.bzcdn.net/scomic/hanghaiwang-weitianrongyilang/0/1153-fz8n/1.jpg"></amp-img>
  <amp-img width="1280" height="1869" data-src="https://s1.bzcdn.net/scomic/hanghaiwang-weitianrongyilang/0/1153-fz8n/2.jpg"></amp-img>
  <amp-img width="1280" height="1869" data-src="https://s1.bzcdn.net/scomic/hanghaiwang-weitianrongyilang/0/1153-fz8n/3.jpg"></amp-img>
</ul></body></html>''';

/// 空壳页：只有一张别的漫画的推广图 + 「打开APP」文案
const _stubPage = '''
<html><body><div class="promo">打开APP 解锁最新1话</div>
<ul class="comic-contain">
  <amp-img width="1" height="1" data-src="https://s1.bzcdn.net/scomic/other-comic/0/2-df6a/1.jpg"></amp-img>
</ul></body></html>''';

BookSource _source() => BookSource.fromJson({
  'bookSourceName': '包子漫画',
  'bookSourceUrl': 'https://cn.bzmanga.com',
  'bookSourceType': 2,
  'enabled': true,
  'ruleContent': {'content': '@js:\njava.getElements(...)'},
});

OnlineBookService _service(List<String> bodies) {
  var i = 0;
  final client = MockClient((req) async {
    final body = bodies[i < bodies.length ? i : bodies.length - 1];
    i++;
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );
  });
  return OnlineBookService(client: SourceHttpClient(client: client));
}

void main() {
  test('第一次空壳、第二次正常 → 自动重试后拿到 3 张', () async {
    final svc = _service([_stubPage, _fullPage]);
    final urls = await svc.fetchComicImages(_source(), _chapterUrl);
    expect(urls, hasLength(3));
    expect(urls.first, contains('/1153-fz8n/1.jpg'));
  });

  test('两次都是空壳 → 抛 ComicUnavailable，并说明是「打开 App / 解锁」', () async {
    final svc = _service([_stubPage, _stubPage]);
    try {
      await svc.fetchComicImages(_source(), _chapterUrl);
      fail('应该抛异常');
    } catch (e) {
      expect(e, isA<ComicUnavailable>());
      final msg = '$e';
      expect(msg, contains('打开 App'));
      expect(msg, contains('章节地址'));
      expect(msg, contains('chapter_slot=1152'));
    }
  });

  test('第一次就正常 → 只请求一次（不浪费时间重试）', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response.bytes(
        utf8.encode(_fullPage),
        200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final svc = OnlineBookService(client: SourceHttpClient(client: client));
    final urls = await svc.fetchComicImages(_source(), _chapterUrl);
    expect(urls, hasLength(3));
    expect(calls, 1);
  });
}
