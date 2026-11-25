// 0.48 下载中心 / 缓存裁剪 / 导出 的验收测试。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_source.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/cache_export.dart';
import 'package:sakura_read/src/data/chapter_cache.dart';
import 'package:sakura_read/src/data/download_center.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/offline_downloader.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

Book _book(String id, int count) => Book(
  id: id,
  title: '书$id',
  format: BookFormat.online,
  path: 'https://example.com/$id',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(
        title: '第 ${i + 1} 章 标题$i',
        href: 'https://example.com/$id/$i',
      ),
  ],
);

/// 假内容：写进缓存（模拟真实落盘）。
class _Content extends BookContent {
  _Content(
    this.book,
    this.store, {
    this.failAll = false,
    this.delay = Duration.zero,
  });

  final Book book;
  final BookStore store;
  bool failAll;
  final Duration delay;

  @override
  Future<String> chapterText(int index) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failAll) throw StateError('网络错误');
    final text = '正文 $index';
    await store.writeCachedChapter(book, index, text);
    return text;
  }
}

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late BookStore store;
  late bool failAll;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_dl_center');
    dirs = AppDirs(files: '${tmp.path}/files', cache: '${tmp.path}/cache');
    store = BookStore(dirsOverride: dirs);
    await store.load();
    failAll = false;
  });

  tearDown(() async {
    store.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  DownloadCenter makeCenter({Duration delay = Duration.zero}) {
    final center = DownloadCenter(
      downloader: OfflineDownloader(
        concurrency: 1,
        contentFactory: (b, s) =>
            _Content(b, s, failAll: failAll, delay: delay),
      ),
    );
    center.bind(store);
    return center;
  }

  group('下载中心：排队 / 暂停 / 重试', () {
    test('两本书按入队顺序串行跑，完成后状态是 done', () async {
      final a = _book('a', 2);
      final b = _book('b', 3);
      store.addOnline(a);
      store.addOnline(b);
      final center = makeCenter();
      addTearDown(center.dispose);

      await center.enqueue(a, indices: const [0, 1]);
      await center.enqueue(b, indices: const [0, 1, 2]);
      // 等队列跑完
      for (var i = 0; i < 100 && center.tasks.any((t) => !t.finished); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(center.tasks.map((t) => t.status), [
        DownloadTaskStatus.done,
        DownloadTaskStatus.done,
      ]);
      expect(await store.cachedChapterCount('a'), 2);
      expect(await store.cachedChapterCount('b'), 3);
    });

    test('暂停后当前任务变成 paused，继续后能跑完', () async {
      final a = _book('a', 20);
      store.addOnline(a);
      final center = makeCenter(delay: const Duration(milliseconds: 15));
      addTearDown(center.dispose);
      final task = await center.enqueue(
        a,
        indices: List.generate(20, (i) => i),
      );
      // 等它真的开始
      for (
        var i = 0;
        i < 50 && task.status != DownloadTaskStatus.running;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      center.pauseCurrent();
      for (
        var i = 0;
        i < 100 && task.status == DownloadTaskStatus.running;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.status, DownloadTaskStatus.paused);

      center.resumeTask(task.id);
      for (var i = 0; i < 200 && !task.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.status, DownloadTaskStatus.done);
      expect(await store.cachedChapterCount('a'), 20);
    });

    test('全部失败 → failed，修好后 retry 能完成', () async {
      final a = _book('a', 2);
      store.addOnline(a);
      failAll = true;
      final center = DownloadCenter(
        downloader: OfflineDownloader(
          concurrency: 1,
          contentFactory: (b, s) => _Content(b, s, failAll: failAll),
        ),
      )..bind(store);
      addTearDown(center.dispose);
      final task = await center.enqueue(a, indices: const [0, 1]);
      for (var i = 0; i < 100 && !task.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.status, DownloadTaskStatus.failed);
      expect(task.error, isNotNull);

      failAll = false; // 「网络好了」
      center.retry(task.id);
      for (var i = 0; i < 100 && !task.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.status, DownloadTaskStatus.done);
    });

    test('进度按「范围内已下好 / 总数」算（含排队前已缓存的章）', () async {
      final a = _book('a', 10);
      store.addOnline(a);
      final center = makeCenter();
      addTearDown(center.dispose);
      final task = await center.enqueue(
        a,
        indices: const [5, 6, 7, 8, 9],
        cachedBefore: 5,
      );
      expect(task.fraction, 0.5, reason: '10 章里已有 5 章');
      for (var i = 0; i < 100 && !task.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.fraction, 1.0);
    });
  });

  group('缓存裁剪', () {
    test('只保留当前章前后 N 章，其余删掉', () async {
      final a = _book('a', 30);
      store.addOnline(a);
      for (var i = 0; i < 30; i++) {
        await store.writeCachedChapter(a, i, '正文$i');
      }
      store.updateProgress('a', chapter: 15);
      await store.trimBookCache('a', keepOlder: 2, keepNewer: 3);
      final set = await store.refreshChapterCache('a');
      expect(set, containsAll([13, 14, 15, 16, 17, 18]));
      expect(set.contains(0), isFalse);
      expect(set.contains(29), isFalse);
    });
  });

  group('导出', () {
    test('小说导出 TXT：按阅读顺序、跳过没缓存的章', () async {
      final a = _book('novel', 3);
      store.addOnline(a);
      await store.writeCachedChapter(a, 0, '第一章正文');
      await store.writeCachedChapter(a, 2, '第三章正文');
      final dir = await Directory('${tmp.path}/out').create(recursive: true);
      final exporter = CacheExporter(dirOverride: dir.path);
      final result = await exporter.exportNovel(a, store);

      expect(result.chapters, 2);
      expect(result.skipped, 1);
      final text = await File(result.path).readAsString();
      expect(text, contains('第一章正文'));
      expect(text, contains('第三章正文'));
      expect(text.indexOf('第一章正文'), lessThan(text.indexOf('第三章正文')));
    });

    test('漫画导出 CBZ：图片按清单顺序打包', () async {
      final c = _book('comic', 2);
      store.addOnline(c);
      final imgDir = ChapterCache.imageDirFor(dirs, c, 0);
      await imgDir.create(recursive: true);
      final urls = [
        'https://img.example.com/0.jpg',
        'https://img.example.com/1.jpg',
      ];
      final manifest = <Map<String, String>>[];
      for (var i = 0; i < urls.length; i++) {
        final name = ChapterCache.imageFileName(urls[i]);
        manifest.add({'u': urls[i], 'f': name});
        await File('${imgDir.path}/$name').writeAsBytes([1, 2, 3, i]);
      }
      await ChapterCache.writeManifest(imgDir, manifest);

      final dir = await Directory('${tmp.path}/out').create(recursive: true);
      final result = await CacheExporter(dirOverride: dir.path)
          .exportComic(c, store);
      expect(result.chapters, 1);
      final bytes = await File(result.path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name).toList();
      expect(names, hasLength(2));
      expect(names.every((n) => n.endsWith('.jpg')), isTrue);
    });
  });
}
