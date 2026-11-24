// 漫画图片磁盘缓存的基础测试（缓存命中 = 真的秒开）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/comic_image_cache.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

void main() {
  late Directory tmp;
  late BookStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_comic_img');
    store = BookStore(dirsOverride: AppDirs(files: tmp.path, cache: tmp.path));
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('图片名按 URL 稳定 hash，同一话同一张图永远同一路径', () {
    final a = comicImageKey('https://img.example.com/a/1.jpg');
    final b = comicImageKey('https://img.example.com/a/1.jpg');
    final c = comicImageKey('https://img.example.com/a/2.jpg');
    expect(a, b);
    expect(a, isNot(c));
    expect(a.length, 17); // 'h' + 16 位 hash

    final f1 = comicImageCacheFile(
      store,
      'book1',
      'https://s.com/ch/1',
      3,
      'https://img.example.com/a/1.jpg',
    );
    final f2 = comicImageCacheFile(
      store,
      'book1',
      'https://s.com/ch/1',
      3,
      'https://img.example.com/a/1.jpg',
    );
    expect(f1.path, f2.path);
    expect(f1.path, endsWith('003.jpg'));
    expect(f1.path, contains('img'));
  });

  test('后缀跟原图一致（webp / png 都不被改坏）', () {
    final webp = comicImageCacheFile(
      store,
      'b',
      'h',
      0,
      'https://i.x/a.webp?token=1',
    );
    expect(webp.path, endsWith('000.webp'));
    final png = comicImageCacheFile(store, 'b', 'h', 1, 'https://i.x/a.PNG');
    expect(png.path, endsWith('001.png'));
  });

  test('空文件不算缓存命中（半截图不能被当成已缓存）', () {
    final url = 'https://i.x/a.jpg';
    expect(comicImageCached(store, 'b', 'h', 0, url), isFalse);
    final f = comicImageCacheFile(store, 'b', 'h', 0, url);
    f.createSync(recursive: true);
    expect(comicImageCached(store, 'b', 'h', 0, url), isFalse, reason: '0 字节');
    f.writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
    expect(comicImageCached(store, 'b', 'h', 0, url), isTrue);
  });

  test('一话的图片目录按章节链接分开', () {
    final a = comicChapterImageDir(store, 'b', 'https://s.com/ch/1');
    final b = comicChapterImageDir(store, 'b', 'https://s.com/ch/2');
    expect(a.path, isNot(b.path));
    expect(a.path, contains(comicImageKey('https://s.com/ch/1')));
  });
}
