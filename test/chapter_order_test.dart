// 目录顺序归一化：包子漫画「最新几话前置」导致的重复 + 索引错位。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/source/chapter_order.dart';

ChapterRef _c(int slot) => ChapterRef(
  title: '第${slot + 1}话',
  href:
      'https://cn.bzmanga.com/user/page_direct?comic_id=hanghaiwang'
      '&section_slot=0&chapter_slot=$slot',
);

void main() {
  test('包子漫画真实形态：最新 24 话前置 + 完整升序列表 → 去重且降序', () {
    // 站点实际顺序：[1186..1163] + [0..1186]
    final raw = <ChapterRef>[
      for (var s = 1186; s >= 1163; s--) _c(s),
      for (var s = 0; s <= 1186; s++) _c(s),
    ];
    expect(raw.length, 24 + 1187);

    final fixed = normalizeChapterOrder(raw, newestFirst: true);
    expect(fixed.length, 1187, reason: '重复的话要去掉');
    expect(chapterNumber(fixed.first), 1186);
    expect(chapterNumber(fixed.last), 0);
    // 严格降序
    for (var i = 1; i < fixed.length; i++) {
      expect(
        chapterNumber(fixed[i])! < chapterNumber(fixed[i - 1])!,
        isTrue,
        reason: '第 $i 条顺序不对：${fixed[i].title}',
      );
    }
    // 第1152话现在在正确位置：从 1186 往下数第 34 条（index 34）
    final idx = fixed.indexWhere((c) => chapterNumber(c) == 1151);
    expect(idx, 1186 - 1151);
  });

  test('小说（升序）保持原顺序，只去重', () {
    final raw = [
      for (var s = 0; s < 50; s++) _c(s),
      _c(10), // 重复一条
    ];
    final fixed = normalizeChapterOrder(raw, newestFirst: false);
    expect(fixed.length, 50);
    expect(chapterNumber(fixed.first), 0);
    expect(chapterNumber(fixed.last), 49);
  });

  test('认不出序号（<80%）就原样返回，不乱动', () {
    final raw = [
      ChapterRef(title: '序章', href: 'https://x.com/a'),
      ChapterRef(title: '附录', href: 'https://x.com/b'),
      ChapterRef(title: '后记', href: 'https://x.com/c'),
      _c(5),
    ];
    final fixed = normalizeChapterOrder(raw, newestFirst: true);
    expect(fixed.map((c) => c.title), ['序章', '附录', '后记', '第6话']);
  });

  test('looksNewestFirst 能认出现有老书的乱序', () {
    final broken = <ChapterRef>[
      for (var s = 1186; s >= 1163; s--) _c(s),
      for (var s = 0; s <= 1162; s++) _c(s),
    ];
    expect(looksNewestFirst(broken), isTrue);

    final normalNovel = [for (var s = 0; s < 20; s++) _c(s)];
    expect(looksNewestFirst(normalNovel), isFalse);
  });

  group('上一话 / 下一话的方向', () {
    List<ChapterRef> desc(int from, int to) => [
      for (var s = from; s >= to; s--) _c(s),
    ];

    test('漫画（最新话在前）：上一话往索引 +1（更早），下一话 -1（更新）', () {
      final chapters = desc(1186, 0); // 1186,1185,...,0
      final idx = 1186 - 1151; // 第1152话（slot 1151）的位置
      expect(chapterNumber(chapters[idx]), 1151);

      expect(olderStep(chapters), 1);
      final older = olderIndex(chapters, idx)!;
      expect(chapterNumber(chapters[older]), 1150, reason: '上一话应该是第1151话');
      final newer = newerIndex(chapters, idx)!;
      expect(chapterNumber(chapters[newer]), 1152, reason: '下一话应该是第1153话');
    });

    test('小说（正序）：上一话 -1，下一话 +1', () {
      final chapters = [for (var s = 0; s < 100; s++) _c(s)];
      expect(olderStep(chapters), -1);
      expect(chapterNumber(chapters[olderIndex(chapters, 10)!]), 9);
      expect(chapterNumber(chapters[newerIndex(chapters, 10)!]), 11);
    });

    test('到头了就返回 null（按钮要置灰）', () {
      final chapters = desc(10, 0);
      expect(olderIndex(chapters, chapters.length - 1), isNull);
      expect(newerIndex(chapters, 0), isNull);
    });
  });

  test('标题里只有「第N章」也能取到序号', () {
    final c = ChapterRef(title: '第 42 章 出发', href: 'https://x.com/ch/42');
    expect(chapterNumber(c), 42);
  });
}
