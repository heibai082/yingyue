// 章节图片列表缓存：翻回来 / 预取过的下一话要能直接出图。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/comic_chapter_cache.dart';

void main() {
  test('存了能取出来', () {
    final c = ComicChapterCache();
    c.put('a', ['1.jpg', '2.jpg']);
    expect(c.contains('a'), isTrue);
    expect(c['a'], ['1.jpg', '2.jpg']);
    expect(c['b'], isNull);
  });

  test('空列表不缓存（这一话没图，翻回来要重新取）', () {
    final c = ComicChapterCache();
    c.put('a', const []);
    expect(c.contains('a'), isFalse);
    expect(c.length, 0);
  });

  test('超过上限丢最早那条', () {
    final c = ComicChapterCache(limit: 3);
    c.put('a', ['1']);
    c.put('b', ['1']);
    c.put('c', ['1']);
    c.put('d', ['1']);
    expect(c.length, 3);
    expect(c.contains('a'), isFalse, reason: '最早的 a 被挤掉');
    expect(c.contains('d'), isTrue);
  });

  test('重复 put 同一个地址不会撑大缓存', () {
    final c = ComicChapterCache(limit: 2);
    c.put('a', ['1']);
    c.put('a', ['1', '2']);
    c.put('b', ['1']);
    expect(c.length, 2);
    expect(c['a'], ['1', '2'], reason: '后写的覆盖前一次');
  });

  test('clear 清空', () {
    final c = ComicChapterCache();
    c.put('a', ['1']);
    c.clear();
    expect(c.length, 0);
  });
}
