// URL 实体还原 + 书源 header 的 `@js:` 包装解析。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/analyze_url.dart';
import 'package:sakura_read/src/source/models.dart';
import 'package:sakura_read/src/source/online_book_service.dart';

BookSource _src({String? header}) => BookSource(
  bookSourceUrl: 'https://cn.bzmanga.com',
  bookSourceName: '包子漫画',
  bookSourceType: 2,
  header: header,
);

void main() {
  group('resolveUrl 还原 HTML 实体', () {
    test('&amp; 变成 &（漫画章节参数就是栽在这里）', () {
      expect(
        resolveUrl(
          '/user/page_direct?comic_id=x&amp;section_slot=0&amp;chapter_slot=3',
          'https://cn.bzmanga.com',
        ),
        'https://cn.bzmanga.com/user/page_direct?comic_id=x&section_slot=0&chapter_slot=3',
      );
    });

    test('绝对地址里的实体也会还原', () {
      expect(
        resolveUrl('https://a.com/p?a=1&amp;b=2', ''),
        'https://a.com/p?a=1&b=2',
      );
    });

    test('普通地址不受影响', () {
      expect(
        resolveUrl('/book/1.html', 'https://a.com'),
        'https://a.com/book/1.html',
      );
    });
  });

  group('书源 header', () {
    test('普通 JSON', () {
      final h = OnlineBookService.headerMap(
        _src(header: '{"Referer":"https://a.com"}'),
      );
      expect(h['Referer'], 'https://a.com');
    });

    test('@js: JSON.stringify({...}) 这种包装也能取到里面的头', () {
      final h = OnlineBookService.headerMap(
        _src(
          header: '@js:\nJSON.stringify({\n'
              '"Accept-Language": "zh-CN,zh;q=0.9"\n})',
        ),
      );
      expect(h['Accept-Language'], 'zh-CN,zh;q=0.9');
    });

    test('空 header / 乱写不炸', () {
      expect(OnlineBookService.headerMap(_src(header: null)), isEmpty);
      expect(OnlineBookService.headerMap(_src(header: 'not json')), isEmpty);
    });
  });
}
