// 章节正文 / 漫画图片的磁盘缓存「住哪儿、叫什么名字」。
//
// 用户反馈：「每次升级，这个就重新开始缓存，跟存不住一样」。两个原因：
//   1. 以前存的是 Android 的**缓存目录**（`filesDir` 旁边的 `cacheDir`）——
//      系统、MIUI 手机管家、覆盖安装时都可能把它清掉，天生就「存不住」；
//   2. 文件名是 `ch_v2_<章序号>.txt`，而漫画目录是「最新话在前」：追更插入
//      一话，后面所有序号整体错位，老文件不但作废，还会被当成别的章。
//
// 现在改成：
//   - 根目录放 **App 私有 files**（只有卸载才会没）；
//   - 每本书一个目录，key 用「书页地址 + 书源」的 hash（重新导入同一本书、
//     换设备恢复备份后还能对上，不再依赖随机生成的 book.id）；
//   - 每章一个文件，名字用**章节链接**的 hash：目录怎么变、序号怎么挪，
//     这一章永远是同一个文件。
import 'dart:io';

import '../platform/native_bridge.dart';
import 'models.dart';

/// 章节缓存的位置与命名规则（纯函数，方便单测）。
class ChapterCache {
  ChapterCache._();

  /// 正文缓存根：`<files>/books`。
  static Directory root(AppDirs dirs) => Directory('${dirs.files}/books');

  /// 旧版本放正文的地方：`<cache>/books`（会被系统清理，仅用于搬家）。
  static Directory legacyRoot(AppDirs dirs) => Directory('${dirs.cache}/books');

  /// 一本书的缓存目录名。
  ///
  /// 在线书用「书页地址 + 书源」算 hash（稳定）；本地书用 book.id（本地文件
  /// 路径不会变，id 也就跟着稳定）。
  static String bookKey(Book book) {
    final path = book.path.trim();
    if (book.format == BookFormat.online && path.isNotEmpty) {
      return 'b${fnv64('$path|${(book.sourceUrl ?? '').trim()}')}';
    }
    return book.id;
  }

  /// 一本书的缓存目录。
  static Directory dirFor(AppDirs dirs, Book book) =>
      Directory('${root(dirs).path}/${bookKey(book)}');

  /// 一章的缓存键：优先章节链接，其次标题，最后才退回序号。
  static String chapterKey(ChapterRef chapter, int index) {
    final href = (chapter.href ?? '').trim();
    if (href.isNotEmpty) return 'h${fnv64(href)}';
    final title = chapter.title.trim();
    if (title.isNotEmpty) return 't${fnv64(title)}';
    return 'i$index';
  }

  /// 一章正文的缓存文件。
  static File fileFor(AppDirs dirs, Book book, int index) {
    final chapter = book.chapters[index];
    return File(
      '${dirFor(dirs, book).path}/ch3_${chapterKey(chapter, index)}.txt',
    );
  }

  /// 这一话的图片目录（漫画）：`<书目录>/img/<章节 key>`
  static Directory imageDirFor(AppDirs dirs, Book book, int index) {
    final chapter = book.chapters[index];
    return Directory(
      '${dirFor(dirs, book).path}/img/${chapterKey(chapter, index)}',
    );
  }

  /// 旧的「按序号」缓存文件名（搬迁时识别用）。
  static File legacyFileFor(Directory legacyBookDir, int index) => File(
    '${legacyBookDir.path}/ch_v2_${index.toString().padLeft(4, '0')}.txt',
  );

  /// 0.42~0.43 图片目录用的 32 位 hash（搬迁时识别老目录）。
  static String legacyImageKey(String href) {
    var hash = 0x811c9dc5;
    for (final unit in href.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 目录指纹：章节链接拼起来的 hash。缓存里的内容属于哪一版目录，用它核对。
  static String catalogHash(List<ChapterRef> chapters) {
    final buffer = StringBuffer();
    for (final c in chapters) {
      final href = (c.href ?? '').trim();
      buffer.write(href.isEmpty ? 't:${c.title.trim()}' : href);
      buffer.write('\n');
    }
    return fnv64(buffer.toString());
  }

  /// FNV-1a 64 位（拆成两段 32 位算，Dart 里够快也不会溢出）。
  static String fnv64(String input) {
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    for (final unit in input.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xffffffff;
      h2 = ((h2 ^ (unit + 0x9e3779b9)) * 0x85ebca6b) & 0xffffffff;
    }
    final a = h1.toRadixString(16).padLeft(8, '0');
    final b = h2.toRadixString(16).padLeft(8, '0');
    return '$a$b';
  }
}
