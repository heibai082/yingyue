// 断网验收：先读缓存、没有才联网。
//
// 用户问：「断网的话，是不是可以看缓存的漫画和小说了？优先看缓存，
// 没有的话，联网在线看」——这里把两件事都钉死在测试里：
//   1. 有缓存 → 不碰网络也能读（书源缺失 / 网络失败都不影响）；
//   2. 没缓存 → 报错里说清楚「还没缓存」，不会假装修好了。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_source.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/chapter_cache.dart';
import 'package:sakura_read/src/data/comic_image_cache.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';
import 'package:sakura_read/src/source/comic_chapter_cache.dart';

Book _onlineBook({int count = 4, String id = 'offline'}) => Book(
  id: id,
  title: '离线测试书',
  format: BookFormat.online,
  path: 'https://example.com/book',
  // 故意用「书源不存在」来模拟断网：读缓存不该需要它
  sourceUrl: 'https://example.com/no-such-source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(title: '第 ${i + 1} 章 标题$i', href: 'https://example.com/c/$i'),
  ],
);

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late BookStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_offline_read');
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

  group('小说：断网也能读缓存过的章节', () {
    test('缓存命中时完全不碰网络（书源都没有也照读）', () async {
      final book = _onlineBook();
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, '这一章是缓存下来的正文');
      await store.writeCachedChapter(book, 2, '第 3 章正文');

      final content = OnlineBookContent(book, store);
      addTearDown(content.dispose);

      expect(content.isCached(0), isTrue);
      expect(content.isCached(1), isFalse);
      expect(await content.chapterText(0), '这一章是缓存下来的正文');
      expect(await content.chapterText(2), '第 3 章正文');
    });

    test('没缓存的章节：报错里明确说「还没缓存」，并提示联网后再读', () async {
      final book = _onlineBook();
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, '缓存正文');

      final content = OnlineBookContent(book, store);
      addTearDown(content.dispose);

      // 书源不存在 = 断网 + 没缓存 → 抛错（不会返回空串冒充成功）
      await expectLater(
        content.chapterText(1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('还没缓存'), contains('断网')),
          ),
        ),
      );
    });

    test('缓存是逐章的：第 0 章能读，第 3 章读不了（不该整本都废）', () async {
      final book = _onlineBook();
      store.addOnline(book);
      await store.writeCachedChapter(book, 0, 'A');
      final content = OnlineBookContent(book, store);
      addTearDown(content.dispose);
      expect(await content.chapterText(0), 'A');
      await expectLater(content.chapterText(3), throwsA(isA<StateError>()));
    });
  });

  group('漫画：断网也能看缓存过的那几话', () {
    test('图片落盘 + 清单落盘 → 断网可看（不依赖网络）', () async {
      final book = _onlineBook(count: 2, id: 'comic');
      store.addOnline(book);
      final href = book.chapters[0].href!;
      const urls = [
        'https://img.example.com/a1.jpg',
        'https://img.example.com/a2.jpg',
      ];
      for (var i = 0; i < urls.length; i++) {
        final f = comicImageCacheFile(store, book.id, href, i, urls[i]);
        await f.parent.create(recursive: true);
        await f.writeAsBytes([1, 2, 3]);
      }
      // 章节 → 图片清单 也落盘（阅读页据此直接出图，不用再抓 HTML）
      final cache = ComicChapterCache();
      cache
        ..put(href, urls)
        ..put('https://example.com/c/1', ['https://img.example.com/b1.jpg']);
      await cache.saveTo(
        File('${store.chapterCacheDir(book.id).path}/comic_list_cache.json'),
      );

      // 1) 图片本身在本地
      expect(comicImageCached(store, book.id, href, 0, urls[0]), isTrue);
      expect(comicImageCached(store, book.id, href, 1, urls[1]), isTrue);
      // 2) 这一话算「已缓存」（详情页 / 计划据此跳过）
      expect(store.hasCachedChapter(book, 0), isTrue);
      // 3) 清单能从磁盘恢复（下次打开直接出图，不请求章节 HTML）
      final restored = ComicChapterCache();
      await restored.loadFrom(
        File('${store.chapterCacheDir(book.id).path}/comic_list_cache.json'),
      );
      expect(restored[href], urls);
      // 4) 没缓存过的那一话，不会假装有
      expect(
        comicImageCached(
          store,
          book.id,
          book.chapters[1].href!,
          0,
          'https://img.example.com/b1.jpg',
        ),
        isFalse,
      );
    });

    test('缓存目录在持久位置：换个 cache 目录（模拟清理）图片还在', () async {
      final book = _onlineBook(count: 1, id: 'comic2');
      store.addOnline(book);
      final href = book.chapters[0].href!;
      const url = 'https://img.example.com/x.jpg';
      final f = comicImageCacheFile(store, book.id, href, 0, url);
      await f.parent.create(recursive: true);
      await f.writeAsBytes([9, 9, 9]);
      await store.flush();

      final store2 = BookStore(
        dirsOverride: AppDirs(
          files: dirs.files,
          cache: '${tmp.path}/cache-cleared',
        ),
      );
      await store2.load();
      addTearDown(store2.dispose);
      expect(
        comicImageCached(store2, store2.byId('comic2')!.id, href, 0, url),
        isTrue,
      );
      // 目录确实在 files 下
      expect(
        ChapterCache.dirFor(dirs, store2.byId('comic2')!).path,
        contains('/files/'),
      );
    });
  });
}
