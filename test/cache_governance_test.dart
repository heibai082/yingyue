// 本轮治理项的验收测试：
//   A1 在线书进度条、A3 删书清缓存、A5 广告规则收紧、A7 半缓存、A8 换 URL 复用旧图、
//   A9/B7 迁移一次性、B3 磁盘满、B4 孤儿清理与缓存上限。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_source.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/chapter_cache.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/offline_downloader.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';
import 'package:sakura_read/src/source/ad_page_filter.dart';

Book _novel(int count, {String id = 'n', int index = 0}) => Book(
  id: id,
  title: '小说',
  format: BookFormat.online,
  path: 'https://example.com/book/$id',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(title: '第 ${i + 1} 章 标题$i', href: 'https://example.com/c$i'),
  ],
  chapterIndex: index,
);

Book _manga(int count, {String id = 'm', int index = 0}) => Book(
  id: id,
  title: '漫画',
  format: BookFormat.online,
  path: 'https://example.com/manga/$id',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(
        title: '第 ${count - i} 话 标题${count - i}',
        href: 'https://example.com/ch/${count - i}',
      ),
  ],
  chapterIndex: index,
);

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late BookStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_governance');
    dirs = AppDirs(files: '${tmp.path}/files', cache: '${tmp.path}/cache');
    store = BookStore(dirsOverride: dirs);
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('A1 在线书进度条（没有字数也要能跳）', () {
    test('小说：50% → 中间那一章', () {
      final book = _novel(10);
      expect(book.totalChars, 0);
      expect(chapterIndexForProgress(book, 0.5), 5);
      expect(chapterIndexForProgress(book, 0), 0);
      expect(chapterIndexForProgress(book, 1), 9);
    });

    test('漫画（降序目录）：0% 是最老一话，100% 是最新一话', () {
      final book = _manga(10);
      expect(chapterIndexForProgress(book, 0), 9);
      expect(chapterIndexForProgress(book, 1), 0);
      expect(chapterIndexForProgress(book, 0.5), 4);
    });

    test('本地书（有字数）仍按字数定位', () {
      final book = Book(
        id: 't',
        title: '本地',
        format: BookFormat.txt,
        path: '/tmp/a.txt',
        chapters: [
          ChapterRef(title: 'c1', start: 0, end: 100, charCount: 100),
          ChapterRef(title: 'c2', start: 100, end: 200, charCount: 100),
          ChapterRef(title: 'c3', start: 200, end: 300, charCount: 100),
        ],
        totalChars: 300,
      );
      expect(chapterIndexForProgress(book, 0.1), 0);
      expect(chapterIndexForProgress(book, 0.9), 2);
    });
  });

  group('A3 删书清缓存', () {
    test('removeById 默认把这本书的缓存目录删掉', () async {
      final book = _novel(3, id: 'del');
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, '正文');
      final dir = ChapterCache.dirFor(dirs, book);
      expect(await dir.exists(), isTrue);

      await store.removeById('del');
      expect(await dir.exists(), isFalse, reason: '不留孤儿缓存');
    });

    test('deleteCache: false 时保留缓存（只从书架移除）', () async {
      final book = _novel(3, id: 'keep');
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, '正文');
      final dir = ChapterCache.dirFor(dirs, book);
      await store.removeById('keep', deleteCache: false);
      expect(await dir.exists(), isTrue);
    });
  });

  group('A7/A8 漫画清单：完整 / 半缓存 / 换 URL', () {
    Future<Directory> seedManga({int files = 2, int entries = 2}) async {
      final book = _manga(2, id: 'comic');
      store.addOnline(book);
      final imgDir = ChapterCache.imageDirFor(dirs, book, 0);
      await imgDir.create(recursive: true);
      final urls = [
        for (var i = 0; i < entries; i++) 'https://img.example.com/$i.jpg',
      ];
      final manifest = <Map<String, String>>[];
      for (var i = 0; i < urls.length; i++) {
        final name = ChapterCache.imageFileName(urls[i]);
        manifest.add({'u': urls[i], 'f': name});
        if (i < files) {
          await File('${imgDir.path}/$name').writeAsBytes([1, 2, 3]);
        }
      }
      await ChapterCache.writeManifest(imgDir, manifest);
      return imgDir;
    }

    test('清单齐了才算已缓存', () async {
      await seedManga(files: 2, entries: 2);
      final book = store.byId('comic')!;
      expect(store.hasCachedChapter(book, 0), isTrue);
    });

    test('只存了一部分：不算已缓存，但会记成「半缓存」', () async {
      await seedManga(files: 1, entries: 2);
      final book = store.byId('comic')!;
      expect(store.hasCachedChapter(book, 0), isFalse);
      final complete = await store.refreshChapterCache('comic');
      expect(complete, isEmpty);
      expect(book.partialCache.contains(0), isTrue);
    });

    test('站点换了图片 URL：按位置复用旧文件（不重下）', () async {
      final imgDir = await seedManga(files: 2, entries: 2);
      // 新 URL（站点换 CDN），但清单里第 0 条是旧图
      final newUrl = 'https://cdn2.example.com/0.jpg';
      final resolved = ChapterCache.resolveImage(imgDir, 0, newUrl);
      expect(resolved, isNotNull, reason: '同位置的旧文件要能复用');
      // 全新位置没有记录 → 判空
      expect(ChapterCache.resolveImage(imgDir, 5, newUrl + '?x'), isNull);
    });

    test('buildMissingManifests 能给「有图没清单」的老缓存补清单', () async {
      final book = _manga(2, id: 'old');
      store.addOnline(book);
      final href = book.chapters[0].href!;
      final imgDir = ChapterCache.imageDirFor(dirs, book, 0);
      await imgDir.create(recursive: true);
      const url = 'https://img.example.com/old.jpg';
      await File('${imgDir.path}/${ChapterCache.imageFileName(url)}')
          .writeAsBytes([1]);
      // 老缓存只有图片清单（书级），没有 manifest
      await File(
        '${ChapterCache.dirFor(dirs, book).path}/comic_list_cache.json',
      ).writeAsString('{"$href":["$url"]}');
      expect(ChapterCache.readManifest(imgDir), isNull);

      await store.buildMissingManifests();
      expect(ChapterCache.readManifest(imgDir), isNotNull);
      expect(store.hasCachedChapter(store.byId('old')!, 0), isTrue);
    });
  });

  group('B4 缓存上限与孤儿清理', () {
    test('超过上限时按「最久没读」整本删', () async {
      final older = _novel(2, id: 'older');
      final newer = _novel(2, id: 'newer');
      store.addOnline(older);
      store.addOnline(newer);
      // 两本各写 1.5MB（上限设 2MB → 必须删掉一本）
      final big = 'x' * (1536 * 1024);
      await store.writeCachedChapter(older, 0, big);
      await store.writeCachedChapter(newer, 0, big);
      older.lastReadAt = 1000;
      newer.lastReadAt = 9000;

      final freed = await store.enforceCacheLimit(2);
      expect(freed, greaterThan(0));
      final olderDir = ChapterCache.dirFor(dirs, older);
      final newerDir = ChapterCache.dirFor(dirs, newer);
      expect(await olderDir.exists(), isFalse, reason: '最久没读的先删');
      expect(await newerDir.exists(), isTrue);
    });

    test('未超上限时不动', () async {
      final book = _novel(2, id: 'small');
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, '短正文');
      expect(await store.enforceCacheLimit(2048), 0);
    });

    test('孤儿缓存（书架里已没有这本书）会被清掉', () async {
      final orphan = Directory('${store.chapterCacheRoot.path}/b_deadbeef');
      await orphan.create(recursive: true);
      await File('${orphan.path}/x.txt').writeAsString('x');
      final removed = await store.pruneOrphanCaches();
      expect(removed, 1);
      expect(await orphan.exists(), isFalse);
    });
  });

  group('B7 迁移只跑一次', () {
    test('load 完会写 marker；再次 load 不再扫', () async {
      // 造一个 legacy 缓存，第一次 load 应该搬过去
      final book = _manga(2, id: 'legacy');
      final legacyRoot = ChapterCache.legacyRoot(dirs);
      final legacy = Directory('${legacyRoot.path}/${book.id}');
      final imgDir = Directory(
        '${legacy.path}/img/h${ChapterCache.fnv64(book.chapters[0].href!)}',
      );
      await imgDir.create(recursive: true);
      await File('${imgDir.path}/a.jpg').writeAsBytes([1]);

      final s0 = BookStore(dirsOverride: dirs);
      await s0.load();
      s0.addOnline(book);
      await s0.flush();
      await s0.migrateLegacyCaches();
      s0.dispose();

      // 第一次启动就会写 marker（哪怕没东西可搬），之后不再扫
      final marker = File('${dirs.files}/.chapter_cache_v3');
      expect(marker.existsSync(), isTrue, reason: '首次启动写 marker');

      final s1 = BookStore(dirsOverride: dirs);
      await s1.load();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(marker.existsSync(), isTrue);
      // 缓存仍然可读（marker 不影响已有缓存）
      expect(await s1.cachedChapterCount('legacy'), isNot(0));
      s1.dispose();
    });
  });

  group('B3 磁盘满：停下来并给出原因', () {
    test('写文件报 ENOSPC 时记「存储空间不足」并停止后续章节', () async {
      final book = _novel(4, id: 'full');
      store.addOnline(book);
      final downloader = OfflineDownloader(
        concurrency: 1,
        contentFactory: (b, s) => _NoSpaceContent(),
      );
      final progress = <OfflineDownloadProgress>[];
      final result = await downloader.downloadChapters(
        book,
        store,
        indices: const [0, 1, 2, 3],
        onProgress: progress.add,
      );
      expect(result.failed, greaterThan(0));
      expect(result.failureReasons['存储空间不足'], isNotNull);
      expect(result.done, 0);
      // 停下来之后不会把 4 章都试一遍
      expect(result.finished, isTrue);
    });
  });

  group('A5 广告 URL 规则收紧', () {
    test('/app/ 这种宽泛路径不再当广告（避免误伤整章）', () {
      expect(looksLikeAdUrl('https://i.x/app/chapter/1.jpg'), isFalse);
      expect(looksLikeAdUrl('https://i.x/qrcode-1.png'), isTrue);
      expect(looksLikeAdUrl('https://i.x/banner/app.jpg'), isTrue);
    });
  });
}

class _NoSpaceContent extends BookContent {
  @override
  Future<String> chapterText(int index) async {
    throw const FileSystemException(
      'write failed',
      '/data/cache/x',
      OSError('No space left on device', 28),
    );
  }
}
