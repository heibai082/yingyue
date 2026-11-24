// 缓存必须「存得住」：
//   - 升级 / 系统清缓存目录后仍在（因为放在 files 目录，不在 cache 目录）；
//   - 目录插了新章（漫画目录降序，序号整体后移）后，旧缓存还能对上；
//   - 老版本（cache 目录 + ch_v2_序号）的缓存能搬到新位置。
//
// 用户反馈：「每次升级，这个就重新开始缓存，跟存不住一样」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/chapter_cache.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

Book _manga(int count, {String id = 'm'}) => Book(
  id: id,
  title: '航海王',
  format: BookFormat.online,
  path: 'https://example.com/one-piece',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(
        title: '第 ${count - i} 话 标题${count - i}',
        href: 'https://example.com/ch/${count - i}',
      ),
  ],
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_persist');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('正文存在 files 目录（持久），不在 cache 目录', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final store = BookStore(dirsOverride: dirs);
    await store.load();
    final book = _manga(3);
    store.addOnline(book);
    await store.writeCachedChapter(book, 1, '正文1');

    final path = ChapterCache.fileFor(dirs, book, 1).path;
    expect(path, contains('${tmp.path}/files'));
    expect(path, isNot(contains('${tmp.path}/cache')));
    expect(await store.cachedChapterCount('m'), 1);
    store.dispose();
  });

  test('模拟「升级后系统清了缓存目录」：换一个新的 cache 目录，缓存还在', () async {
    final files = '${tmp.path}/files';
    final store1 = BookStore(
      dirsOverride: AppDirs(files: files, cache: '${tmp.path}/cache-v1'),
    );
    await store1.load();
    final book = _manga(4);
    store1.addOnline(book);
    for (var i = 0; i < 4; i++) {
      await store1.writeCachedChapter(book, i, '正文$i');
    }
    expect(await store1.cachedChapterCount('m'), 4);
    await store1.flush();
    store1.dispose();

    // 「升级」：files 不变，cache 目录被清空/换新
    final store2 = BookStore(
      dirsOverride: AppDirs(files: files, cache: '${tmp.path}/cache-v2'),
    );
    await store2.load();
    expect(store2.books, hasLength(1));
    expect(
      await store2.cachedChapterCount(store2.byId('m')!.id),
      4,
      reason: '缓存不能因为升级 / 清 cache 目录而丢失',
    );
    store2.dispose();
  });

  test('漫画插了新话（序号整体后移）后，旧缓存仍按链接对上', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final store = BookStore(dirsOverride: dirs);
    await store.load();
    final book = _manga(5);
    store.addOnline(book);
    await store.writeCachedChapter(book, 0, '第 5 话正文');

    // 站点更新：最新一话插到最前面 → 原来的索引 0 变成 1
    final added = ChapterRef(
      title: '第 6 话 新的一话',
      href: 'https://example.com/ch/6',
    );
    book.discoveredChapters = [added];
    store.applyChapterUpdates('m');

    final after = store.byId('m')!;
    expect(after.chapterCount, 6);
    expect(after.chapters[0].href, added.href);
    expect(store.hasCachedChapter(after, 1), isTrue, reason: '第 5 话还在缓存里');
    expect(
      await store.readCachedChapter(after, 1),
      '第 5 话正文',
      reason: '索引移动后读到的仍是同一话的正文',
    );
    store.dispose();
  });

  test('老版本缓存能搬过来（cache/books/<id>/ch_v2_序号.txt）', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final book = _manga(4);
    // 造一份旧位置的文件（和 0.43 的落盘格式一致）
    final legacy = Directory(
      '${ChapterCache.legacyRoot(dirs).path}/${book.id}',
    );
    await legacy.create(recursive: true);
    for (var i = 0; i < 4; i++) {
      await File('${legacy.path}/ch_v2_${i.toString().padLeft(4, '0')}.txt')
          .writeAsString('${book.chapters[i].title}\n这里是正文');
    }

    final store = BookStore(dirsOverride: dirs);
    await store.load();
    store.addOnline(book);
    // 迁移是 await 的：老版本留下的缓存搬完再断言
    await store.migrateLegacyCaches();
    expect(await store.cachedChapterCount('m'), 4);
    expect(await store.readCachedChapter(store.byId('m')!, 2), contains('正文'));

    // 新位置的目录已生成，旧目录已清掉
    final target = ChapterCache.dirFor(dirs, book);
    expect(await target.exists(), isTrue);
    expect(await legacy.exists(), isFalse);
    store.dispose();
  });

  test('老缓存对不上号（标题不匹配）就不搬，避免把别的章当成这一章', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final book = _manga(4);
    final legacy = Directory(
      '${ChapterCache.legacyRoot(dirs).path}/${book.id}',
    );
    await legacy.create(recursive: true);
    for (var i = 0; i < 4; i++) {
      await File('${legacy.path}/ch_v2_${i.toString().padLeft(4, '0')}.txt')
          .writeAsString('完全无关的内容 $i');
    }
    final store = BookStore(dirsOverride: dirs);
    await store.load();
    store.addOnline(book);
    await store.migrateLegacyCaches();
    expect(await store.cachedChapterCount('m'), 0);
    store.dispose();
  });

  test('书名/地址相同的书重新导入后，缓存目录仍是同一个', () {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final a = _manga(3, id: 'id-1');
    final b = _manga(3, id: 'id-2'); // 同一个书页地址，换了 id
    expect(
      ChapterCache.dirFor(dirs, a).path,
      ChapterCache.dirFor(dirs, b).path,
      reason: '重新导入不应该换缓存目录',
    );
  });
  test('老漫画图片目录（32 位 hash）搬过来后仍算「已缓存」', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final book = _manga(2);
    final legacy = Directory(
      '${ChapterCache.legacyRoot(dirs).path}/${book.id}',
    );
    final href = book.chapters[0].href!;
    final legacyImg = Directory(
      '${legacy.path}/img/${ChapterCache.legacyImageKey(href)}',
    );
    await legacyImg.create(recursive: true);
    await File('${legacyImg.path}/000.jpg').writeAsBytes([1, 2, 3]);

    final store = BookStore(dirsOverride: dirs);
    await store.load();
    store.addOnline(book);
    await store.migrateLegacyCaches();

    final after = store.byId('m')!;
    expect(store.hasCachedChapter(after, 0), isTrue);
    expect(
      ChapterCache.imageDirFor(dirs, after, 0).listSync(),
      isNotEmpty,
      reason: '图片目录已改名到新 hash',
    );
    store.dispose();
  });
  test('老漫画图片按「第几张」命名 → 迁移后按图片地址命名，仍算已缓存', () async {
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final book = _manga(2);
    final href = book.chapters[0].href!;
    final legacy = Directory(
      '${ChapterCache.legacyRoot(dirs).path}/${book.id}',
    );
    final chapterDir = Directory(
      '${legacy.path}/img/h${ChapterCache.fnv64(href)}',
    );
    await chapterDir.create(recursive: true);
    const imgUrl = 'https://img.example.com/p/1.jpg';
    await File('${chapterDir.path}/000.jpg').writeAsBytes([1, 2, 3]);
    await File('${legacy.path}/comic_list_cache.json')
        .writeAsString('{"$href":["$imgUrl"]}');

    final store = BookStore(dirsOverride: dirs);
    await store.load();
    store.addOnline(book);
    await store.migrateLegacyCaches();

    final after = store.byId('m')!;
    expect(store.hasCachedChapter(after, 0), isTrue);
    final newFile = File(
      '${ChapterCache.imageDirFor(dirs, after, 0).path}/h${ChapterCache.fnv64(imgUrl)}.jpg',
    );
    expect(newFile.existsSync(), isTrue, reason: '迁移成按图片地址命名');
    expect(
      File('${ChapterCache.imageDirFor(dirs, after, 0).path}/000.jpg')
          .existsSync(),
      isFalse,
    );
    store.dispose();
  });
}
