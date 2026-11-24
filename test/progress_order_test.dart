// 阅读进度必须按「阅读顺序」算（漫画目录降序时索引 34 不是 3%）。
//
// 用户反馈：「只剩下最后35章没看，不应该90%以上吗」——截图里读到第 1152 话
// （1187 话），进度却显示 3%。
import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/source/chapter_order.dart';

/// 正序目录：第 1 章在前。
Book _novel(int count, {int index = 0}) => Book(
  id: 'n$count',
  title: '小说',
  format: BookFormat.online,
  path: 'u',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(
        title: '第 ${i + 1} 章',
        href: 'https://s.com/c$i',
        charCount: 100,
      ),
  ],
  chapterIndex: index,
);

/// 降序目录：最新话在前（第 N 话在索引 count-N）。
Book _manga(int count, {int index = 0}) => Book(
  id: 'm$count',
  title: '漫画',
  format: BookFormat.online,
  path: 'u',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(
        title: '第 ${count - i} 话',
        href: 'https://s.com/m$i',
        charCount: 100,
      ),
  ],
  chapterIndex: index,
);

void main() {
  test('漫画读到第 1152 话（1187 话）→ 约 97%，不是 3%', () {
    // 第 1152 话在索引 34
    final book = _manga(1187, index: 34);
    expect(book.progressLabel, '97%');
    expect(book.progress, greaterThan(0.9));
  });

  test('漫画：最老的一话是 0%，最新的一话接近 100%', () {
    expect(_manga(10, index: 9).progress, 0);
    expect(_manga(10, index: 0).progress, 0.9);
  });

  test('漫画读完（finished）→ 100%', () {
    final book = _manga(10, index: 0)..finished = true;
    expect(book.progress, 1);
  });

  test('小说行为不变：第 1 章 0%，第 6/11 章 ≈ 50%', () {
    expect(_novel(11, index: 0).progress, 0);
    expect(_novel(11, index: 5).progress, closeTo(5 / 11, 0.001));
    expect(_novel(11, index: 10).progress, closeTo(10 / 11, 0.001));
  });

  test('章内偏移也按阅读方向推进', () {
    final book = _manga(10, index: 9)..charOffset = 50; // 最老一话读到一半
    expect(book.progress, closeTo(0.05, 0.001));
    final novel = _novel(10, index: 0)..charOffset = 50;
    expect(novel.progress, closeTo(0.05, 0.001));
  });

  test('readingPosition：降序目录按总章数-1-索引', () {
    final chapters = _manga(5).chapters;
    expect(readingPosition(chapters, 4, 0), 0);
    expect(readingPosition(chapters, 0, 0), 4);
    expect(readingPosition(chapters, 0, 0.5), 4.5);
  });

  test('已读字数：漫画统计「比当前话更旧」的那些', () {
    // 5 话 × 100 字，读到索引 3（第 2 话）→ 已读更旧的索引 4 = 100 字
    final book = _manga(5, index: 3);
    expect(book.readChars, 100);
  });

  test('目录顺序判断：认不出序号时不乱判', () {
    final weird = Book(
      id: 'w',
      title: '怪目录',
      format: BookFormat.online,
      path: 'u',
      chapters: [
        ChapterRef(title: '序章'),
        ChapterRef(title: '尾声'),
      ],
    );
    expect(looksNewestFirst(weird.chapters), isFalse);
    expect(weird.progress, 0);
  });
  group('方向契约：小说与漫画都必须一致（以后新加的书也走同一套）', () {
    test('readingChapterNumber：正序索引+1，降序总章数-索引', () {
      expect(readingChapterNumber(_novel(10).chapters, 0), 1);
      expect(readingChapterNumber(_novel(10).chapters, 9), 10);
      expect(readingChapterNumber(_manga(1187).chapters, 35), 1152);
      expect(readingChapterNumber(_manga(1187).chapters, 0), 1187);
    });

    test('isChapterRead：漫画里比当前话新的不算已读', () {
      final manga = _manga(10, index: 5); // 读到第 5 话（自新往旧数）
      expect(isChapterRead(manga, 9), isTrue, reason: '更旧的一话已读');
      expect(isChapterRead(manga, 5), isFalse, reason: '当前话未读完');
      expect(isChapterRead(manga, 1), isFalse, reason: '更新的一话还没读');

      final novel = _novel(10, index: 5);
      expect(isChapterRead(novel, 1), isTrue);
      expect(isChapterRead(novel, 5), isFalse);
      expect(isChapterRead(novel, 9), isFalse);
    });

    test('olderIndex / newerIndex：降序目录方向相反', () {
      final manga = _manga(10).chapters;
      expect(olderIndex(manga, 5), 6);
      expect(newerIndex(manga, 5), 4);
      expect(olderIndex(manga, 9), isNull);
      expect(newerIndex(manga, 0), isNull);

      final novel = _novel(10).chapters;
      expect(olderIndex(novel, 5), 4);
      expect(newerIndex(novel, 5), 6);
    });

    test('缓存范围描述里的章号：漫画不显示成索引', () {
      final manga = _manga(1187);
      final plan = const BookCachePlan(mode: CacheMode.from, start: 35);
      expect(
        plan.describe(manga.chapterCount, newestFirst: true),
        '第 1152 章 → 最新（自动追更）',
      );
      final novel = _novel(100);
      expect(plan.describe(novel.chapterCount), '第 36 章 → 最新（自动追更）');
    });

    test('两端都对：0 章 / 1 章不会越界', () {
      final empty = <ChapterRef>[];
      expect(readingPosition(empty, 0, 0), 0);
      expect(readingChapterNumber(empty, 0), 0);
      final one = _novel(1);
      expect(one.progress, 0);
      expect(readingChapterNumber(one.chapters, 0), 1);
    });
  });
}

// 让 group 在 main 里可读：把 extension 换成普通 import 的工具类不需要；
// chapter_order 的 helper 直接取自 models.dart（chapter_order 再导出）。
