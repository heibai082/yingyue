// 缓存范围 / 追更合并 / 缓存命中判定的单元测试。
//
// 对应需求（用户原话）：
//   「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从当前章节缓存到最新
//    （并且开启自动追剧模式缓存）」
//   「缓存完了的章节不应该是秒开么，为什么还要转圈」
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_source.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/cache_plan.dart';
import 'package:sakura_read/src/data/cache_tracker.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/offline_downloader.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

/// 正序目录（小说）：第 1 章在前。
Book _novel(
  int count, {
  BookCachePlan? plan,
  int reading = 0,
  String id = '',
}) => Book(
  id: id.isEmpty ? 'b${plan?.mode.name ?? 'all'}$count' : id,
  title: '测试书',
  format: BookFormat.online,
  path: 'https://example.com/book',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(title: '第 ${i + 1} 章', href: 'https://example.com/c$i'),
  ],
  chapterIndex: reading,
  cachePlan: plan ?? BookCachePlan.defaults,
);

/// 降序目录（漫画）：最新一话在前。第 N 话在索引 count-N。
Book _manga(
  int count, {
  BookCachePlan? plan,
  int reading = 0,
  String id = '',
}) => Book(
  id: id.isEmpty ? 'm${plan?.mode.name ?? 'all'}$count' : id,
  title: '测试漫画',
  format: BookFormat.online,
  path: 'https://example.com/manga',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(title: '第 ${count - i} 话', href: 'https://example.com/m$i'),
  ],
  chapterIndex: reading,
  cachePlan: plan ?? BookCachePlan.defaults,
);

void main() {
  group('buildCachePlan', () {
    test('全部：先下当前章之后的，再回头补前面的', () {
      final plan = buildCachePlan(_novel(10, reading: 4));
      expect(plan.total, 10);
      expect(plan.indices, [4, 5, 6, 7, 8, 9, 3, 2, 1, 0]);
    });

    test('全部：已缓存的章节会跳过', () {
      final plan = buildCachePlan(_novel(6, reading: 0), cached: {1, 2});
      expect(plan.total, 6);
      expect(plan.cachedInRange, 2);
      expect(plan.indices, [0, 3, 4, 5]);
    });

    test('全部（漫画，最新话在前）：从当前话往更新方向排', () {
      final plan = buildCachePlan(_manga(6, reading: 2));
      expect(plan.indices, [2, 1, 0, 3, 4, 5]);
    });

    test('从当前章到最新：只下起点之后，新章优先', () {
      final plan = buildCachePlan(
        _novel(10, plan: const BookCachePlan(mode: CacheMode.from, start: 6)),
      );
      // 正序目录：范围是 [6..9]，最新（9）先下
      expect(plan.range, [6, 7, 8, 9]);
      expect(plan.indices, [9, 8, 7, 6]);
    });

    test('漫画（降序目录）第 1152 话 → 最新：只有 35 话，先下更新的', () {
      // 1187 话、最新话在前（第 N 话在索引 1187-N）：
      // 第 1152 话 = 索引 34；比它新的第 1153~1187 话在索引 0~33。
      // 回归：0.41 第一版把方向算反，范围变成 [0..34] 却按「第 35 章」显示，
      // 进度条 34/35 一下就 97%。
      final plan = buildCachePlan(
        _manga(
          1187,
          plan: const BookCachePlan(mode: CacheMode.from, start: 34),
        ),
      );
      expect(plan.total, 35);
      expect(plan.range.first, 0);
      expect(plan.range.last, 34);
      // 最新那头先下（第 1187 话），再往回补到第 1152 话
      expect(plan.indices.take(2), [0, 1]);
    });

    test('漫画（降序目录）第 35 话 → 最新：起点在最旧那头，覆盖 1153 话', () {
      // 第 35 话 = 索引 1152（几乎是最旧的一话）；「到最新」= 索引 0..1152。
      // 这条保证边界不越界，而不是又变成整本 1187 话。
      final plan = buildCachePlan(
        _manga(
          1187,
          plan: const BookCachePlan(mode: CacheMode.from, start: 1152),
        ),
      );
      expect(plan.total, 1153);
      expect(plan.range.first, 0);
      expect(plan.range.last, 1152);
      // 最新那一话先下
      expect(plan.indices.take(2), [0, 1]);
      expect(plan.indices.last, 1152);
    });

    test('从当前章到最新：起点默认取阅读进度', () {
      final plan = buildCachePlan(
        _novel(5, reading: 3, plan: const BookCachePlan(mode: CacheMode.from)),
      );
      expect(plan.range, [3, 4]);
      expect(plan.indices, [4, 3]);
    });

    test('从当前章到最新（漫画，降序目录）：范围是 [0..起点]', () {
      final plan = buildCachePlan(
        _manga(8, plan: const BookCachePlan(mode: CacheMode.from, start: 3)),
      );
      // 第 4 话（索引 3）→ 最新（索引 0）：4 话
      expect(plan.range, [0, 1, 2, 3]);
      expect(plan.indices, [0, 1, 2, 3]);
    });

    test('一段区间：正反输入都能容忍，且先下更新的', () {
      final a = buildCachePlan(
        _novel(
          10,
          plan: const BookCachePlan(mode: CacheMode.range, start: 2, end: 4),
        ),
      );
      expect(a.range, [2, 3, 4]);
      expect(a.indices, [4, 3, 2]);
      final b = buildCachePlan(
        _novel(
          10,
          plan: const BookCachePlan(mode: CacheMode.range, start: 4, end: 2),
        ),
      );
      expect(b.indices, [4, 3, 2]);
    });

    test('不缓存：什么章都不下', () {
      final plan = buildCachePlan(
        _novel(10, plan: const BookCachePlan(mode: CacheMode.off)),
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.total, 0);
    });

    test('全部都缓存过了：计划为空但范围仍然报出来', () {
      final plan = buildCachePlan(_novel(3), cached: {0, 1, 2});
      expect(plan.isEmpty, isTrue);
      expect(plan.total, 3);
      expect(plan.cachedInRange, 3);
    });

    test('缓存偏好会跟着书持久化，旧书（没有这字段）默认全部', () {
      final book = Book.fromJson({
        'id': 'x',
        'title': '旧书',
        'format': 'online',
        'path': 'u',
      });
      expect(book.cachePlan.mode, CacheMode.all);
      expect(book.toJson().containsKey('cachePlan'), isFalse);

      final custom = _novel(
        5,
        plan: const BookCachePlan(mode: CacheMode.from, start: 2, updatedAt: 7),
      );
      final back = Book.fromJson(custom.toJson());
      expect(back.cachePlan.mode, CacheMode.from);
      expect(back.cachePlan.start, 2);
      expect(back.cachePlan.updatedAt, 7);
    });
  });

  group('追更：目录合并', () {
    test('只认链接，同名的不同章不会被当成重复', () {
      final current = [
        ChapterRef(title: '第 1 章', href: 'a'),
        ChapterRef(title: '第 2 章', href: 'b'),
      ];
      final fresh = [
        ChapterRef(title: '第 2 章', href: 'b'),
        ChapterRef(title: '第 2 章', href: 'b-new'),
        ChapterRef(title: '第 3 章', href: 'c'),
      ];
      final added = newChaptersOf(current, fresh);
      expect(added.map((c) => c.href), ['b-new', 'c']);
    });

    test('正序目录追加到末尾，降序目录插到最前面', () {
      final current = [ChapterRef(title: '旧', href: 'old')];
      final added = [ChapterRef(title: '新', href: 'new')];
      expect(
        appendNewChapters(
          current,
          added,
          newestFirst: false,
        ).map((c) => c.href),
        ['old', 'new'],
      );
      expect(
        appendNewChapters(current, added, newestFirst: true).map((c) => c.href),
        ['new', 'old'],
      );
    });
  });

  group('缓存命中判定（阅读页据此决定要不要转圈）', () {
    test('磁盘上有正文文件才算命中；空文件 / 没有都不算', () async {
      final tmp = await Directory.systemTemp.createTemp('sakura_is_cached');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final store = BookStore(
        dirsOverride: AppDirs(files: tmp.path, cache: tmp.path),
      );
      await store.load();
      addTearDown(store.dispose);
      final book = _novel(3, id: 'hit');
      final content = OnlineBookContent(book, store);
      addTearDown(content.dispose);

      expect(content.isCached(0), isFalse);
      await store.writeCachedChapter(book, 0, '');
      expect(content.isCached(0), isFalse, reason: '0 字节不算');
      await store.writeCachedChapter(book, 0, '正文');
      expect(content.isCached(0), isTrue);
      expect(content.isCached(1), isFalse);
      expect(content.isCached(-1), isFalse);
      expect(content.isCached(99), isFalse);
    });

    test('TXT 永远算命中（本地文件，毫秒级）', () {
      final txt = Book(
        id: 't',
        title: '本地',
        format: BookFormat.txt,
        path: '/tmp/a.txt',
        chapters: [ChapterRef(title: 'c1', start: 0, end: 3)],
      );
      expect(TxtBookContent(txt).isCached(0), isTrue);
    });
  });

  group('CacheTracker：抓新章 → 下好 → 才并入目录', () {
    late BookStore store;
    late Directory tmp;

    // 每个用例独立目录：缓存按「章节链接」存，共用目录会互相污染
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sakura_tracker');
      store = BookStore(
        dirsOverride: AppDirs(files: tmp.path, cache: tmp.path),
      );
      await store.load();
    });

    tearDown(() async {
      store.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// 假内容：把正文写进缓存（走 BookStore.writeCachedChapter，和真实落盘一致）。
    OfflineDownloader fakeDownloader({int failAt = -1}) => OfflineDownloader(
      contentFactory: (book, s) => _WritingContent(book, s, failAt: failAt),
    );

    test('新章下好后才出现在目录里，且进缓存', () async {
      final book = _novel(3, id: 'tracked');
      store.addOnline(book);
      for (var i = 0; i < 3; i++) {
        await _writeCache(store, book, i, '正文$i');
      }

      final tracker = CacheTracker(
        store: store,
        downloader: fakeDownloader(),
        tocFetcher: (_, _) async => [
          for (var i = 0; i < 5; i++)
            ChapterRef(title: '第 ${i + 1} 章', href: 'https://example.com/c$i'),
        ],
      );
      addTearDown(tracker.dispose);

      final r = await tracker.trackOne('tracked', force: true);
      expect(r.added, 2);
      expect(r.downloaded, 2);
      expect(r.failed, 0);

      final after = store.byId('tracked')!;
      expect(after.chapterCount, 5);
      expect(after.chapterCache.containsAll({0, 1, 2, 3, 4}), isTrue);
      expect(after.discoveredChapters, isEmpty);
      expect(after.chapterIndex, 0);
    });

    test('关掉自动缓存的书：完全不碰', () async {
      final book = _novel(
        3,
        id: 'tracked',
        plan: const BookCachePlan(mode: CacheMode.off),
      );
      store.addOnline(book);
      var fetched = 0;
      final tracker = CacheTracker(
        store: store,
        downloader: fakeDownloader(),
        tocFetcher: (_, _) async {
          fetched++;
          return const [];
        },
      );
      addTearDown(tracker.dispose);

      final r = await tracker.trackOne('tracked', force: true);
      expect(r.skipped, isTrue);
      expect(r.reason, contains('关掉'));
      expect(fetched, 0);
    });

    test('刚查过目录：30 分钟内不重复抓', () async {
      final book = _novel(3, id: 'tracked');
      store.addOnline(book);
      store.markTracked('tracked');
      var fetched = 0;
      final tracker = CacheTracker(
        store: store,
        downloader: fakeDownloader(),
        tocFetcher: (_, _) async {
          fetched++;
          return const [];
        },
      );
      addTearDown(tracker.dispose);

      final r = await tracker.trackOne('tracked');
      expect(r.skipped, isTrue);
      expect(fetched, 0);
      await tracker.trackOne('tracked', force: true);
      expect(fetched, 1);
    });

    test('抓目录失败不致命：按原计划把缺的章补上', () async {
      final book = _novel(4, id: 'tracked');
      store.addOnline(book);
      await _writeCache(store, book, 0, '正文0');

      final tracker = CacheTracker(
        store: store,
        downloader: fakeDownloader(),
        tocFetcher: (_, _) async => throw StateError('站点 502'),
      );
      addTearDown(tracker.dispose);

      final r = await tracker.trackOne('tracked', force: true);
      expect(r.added, 0);
      expect(r.downloaded, 3);
      expect(store.byId('tracked')!.chapterCount, 4);
    });

    test('下载失败不算成功：进度里带原因，目录不提前扩容', () async {
      final book = _novel(2, id: 'tracked');
      store.addOnline(book);

      final tracker = CacheTracker(
        store: store,
        downloader: fakeDownloader(failAt: 1),
        tocFetcher: (_, _) async => const [],
      );
      addTearDown(tracker.dispose);

      final r = await tracker.trackOne('tracked', force: true);
      expect(r.downloaded, 1);
      expect(r.failed, 1);
      expect(store.byId('tracked')!.chapterCount, 2);
    });
  });
}

/// 把每次读取的章节写进缓存（模拟真实落盘，好让 refreshChapterCache 扫得到）。
class _WritingContent extends BookContent {
  _WritingContent(this.book, this.store, {this.failAt = -1});

  final Book book;
  final BookStore store;
  final int failAt;

  @override
  Future<String> chapterText(int index) async {
    if (index == failAt) throw StateError('网络错误');
    final text = '第 ${index + 1} 章正文';
    await _writeCache(store, book, index, text);
    return text;
  }
}

Future<void> _writeCache(BookStore store, Book book, int index, String text) =>
    store.writeCachedChapter(book, index, text);
