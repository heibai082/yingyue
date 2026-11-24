import 'dart:io';

import 'package:flutter/foundation.dart';

import '../source/models.dart' show BookSource;
import '../source/online_book_service.dart';
import '../source/source_store.dart';
import 'book_store.dart';
import 'epub_parser.dart';
import 'models.dart';
import 'txt_parser.dart';

/// 「这一章其实是图片」——上层据此切到漫画模式。
class ComicChapterException implements Exception {
  ComicChapterException(this.images);

  final List<String> images;

  @override
  String toString() => 'ComicChapterException(${images.length} 张图)';
}

/// 章节内容读取接口。
abstract class BookContent {
  Future<String> chapterText(int index);

  /// 这一章是否**已经在本地**（缓存命中就必然秒开，不该再转圈）。
  ///
  /// 阅读页据此决定：命中的章节不弹 loading（磁盘读几十毫秒，弹一下反而更慢）；
  /// 没命中的才显示「加载中…」。实现必须是同步的、极轻的（只 stat 文件）。
  bool isCached(int index) => false;

  Future<void> dispose() async {}
}

/// TXT：整文件解码后在内存中按字符偏移切片。
class TxtBookContent implements BookContent {
  TxtBookContent(this.book);

  final Book book;
  String? _text;
  Future<String>? _loading;

  /// 本地文件，读起来就是毫秒级 —— 永远算「命中」。
  @override
  bool isCached(int index) => index >= 0 && index < book.chapters.length;

  Future<String> _ensureText() {
    final cached = _text;
    if (cached != null) return Future.value(cached);
    return _loading ??= () async {
      final bytes = await File(book.path).readAsBytes();
      final text = await compute(_decodeTxtIsolate, bytes);
      _text = text;
      return text;
    }();
  }

  @override
  Future<String> chapterText(int index) async {
    if (index < 0 || index >= book.chapters.length) return '';
    final text = await _ensureText();
    final ch = book.chapters[index];
    final start = (ch.start ?? 0).clamp(0, text.length);
    final end = (ch.end ?? text.length).clamp(start, text.length);
    return text.substring(start, end);
  }

  @override
  Future<void> dispose() async {
    _text = null;
  }
}

/// EPUB：读取导入时缓存的章节文本；缓存丢失时从源文件重新提取。
class EpubBookContent implements BookContent {
  EpubBookContent(this.book, this.store);

  final Book book;
  final BookStore store;
  final Map<int, String> _memo = {};

  File _cacheFile(int index) => File(
    '${store.chapterCacheDir(book.id).path}/'
    'ch_${index.toString().padLeft(4, '0')}.txt',
  );

  @override
  bool isCached(int index) {
    if (index < 0 || index >= book.chapters.length) return false;
    if (_memo.containsKey(index)) return true;
    try {
      final f = _cacheFile(index);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> chapterText(int index) async {
    if (index < 0 || index >= book.chapters.length) return '';
    final memo = _memo[index];
    if (memo != null) return memo;

    final loaded = await _load(index);
    _memo[index] = loaded;
    if (_memo.length > 3) {
      _memo.remove(_memo.keys.first);
    }
    return loaded;
  }

  Future<String> _load(int index) async {
    final file = _cacheFile(index);
    try {
      if (await file.exists()) {
        final cached = await file.readAsString();
        if (cached.isNotEmpty) return cached;
      }
    } catch (_) {}

    final href = book.chapters[index].href ?? '';
    final fresh = await compute(_extractEpubChapterIsolate, {
      'path': book.path,
      'href': href,
      'cacheDir': store.chapterCacheDir(book.id).path,
    });
    if (fresh.isNotEmpty) {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(fresh, flush: false);
      } catch (_) {}
    }
    return fresh;
  }

  @override
  Future<void> dispose() async {
    _memo.clear();
  }
}

/// 在线书籍：隐藏 WebView 渲染正文 + 磁盘缓存。
///
/// 章节链接、正文解析依赖书源规则（[BookSource]）：
/// 通过 [Book.sourceUrl]（书源地址）在 [SourceStore.shared] 中查找。
class OnlineBookContent implements BookContent {
  OnlineBookContent(this.book, this.store, {this.requireCacheWrite = false});

  final bool requireCacheWrite;

  final Book book;
  final BookStore store;
  final OnlineBookService _service = OnlineBookService();
  final Map<int, String> _memo = {};

  /// 缓存文件的命名 / 位置统一由 BookStore + ChapterCache 决定：
  /// 存在**持久**目录里（不是系统缓存目录），文件名按章节链接算，
  /// 所以升级、清理、目录插新章都不会让缓存失效。
  @override
  bool isCached(int index) {
    if (index < 0 || index >= book.chapters.length) return false;
    if (_memo.containsKey(index)) return true;
    return store.hasCachedChapter(book, index);
  }

  @override
  Future<String> chapterText(int index) async {
    if (index < 0 || index >= book.chapters.length) return '';
    final memo = _memo[index];
    if (memo != null) return memo;
    final loaded = await _load(index);
    _memo[index] = loaded;
    if (_memo.length > 3) {
      _memo.remove(_memo.keys.first);
    }
    return loaded;
  }

  Future<String> _load(int index) async {
    try {
      final cached = await store.readCachedChapter(book, index);
      if (cached != null) return cached;
    } catch (_) {}

    final sourceUrl = book.sourceUrl;
    final source = sourceUrl == null
        ? null
        : SourceStore.shared?.byUrl(sourceUrl);
    if (source == null) {
      throw StateError(
        '这一章还没缓存，书源也不在本机（${sourceUrl ?? '未知'}，可能已被删除）。\n'
        '联网后打开这一章会自动存下来，之后断网也能看。',
      );
    }
    final chapter = book.chapters[index];
    final href = (chapter.href ?? '').trim();
    if (href.isEmpty) {
      throw StateError(
        '章节缺少链接（第 ${readingChapterNumber(book.chapters, index)} 章）',
      );
    }
    final text = await _fetchOrExplain(source, href, index);
    if (text.trim().isEmpty) {
      // 有些「章节」其实是图片（漫画 / 图楼）：文字抽不出来，但页面上有图。
      // 这里先探一下图片，交给上层切到漫画模式，而不是直接报「正文为空」。
      try {
        final images = await _service.fetchComicImages(source, href);
        if (images.isNotEmpty) throw ComicChapterException(images);
      } catch (e) {
        if (e is ComicChapterException) rethrow;
      }
      throw StateError('正文为空（站点可能拦截或改版）。如果这是漫画，请到「搜书」切到「漫画源」重新找这本书');
    }
    try {
      await store.writeCachedChapter(
        book,
        index,
        text,
        flush: requireCacheWrite,
      );
    } catch (_) {
      if (requireCacheWrite) rethrow;
    }
    return text;
  }

  /// 联网取正文；失败时说清楚「是不是还没缓存」——断网时最需要这句话。
  Future<String> _fetchOrExplain(dynamic source, String href, int index) async {
    try {
      return await _service.fetchChapterText(source, href);
    } catch (e) {
      throw StateError(
        '这一章还没缓存，现在也抓不到正文（没网 / 站点拦截 / 改版）。\n'
        '之前缓存过的章节断网也能看；联网后打开这一章，就会自动存下来。\n'
        '（原因：$e）',
      );
    }
  }

  @override
  Future<void> dispose() async {
    _memo.clear();
    _service.dispose();
  }
}

/// 按书籍格式创建内容读取器。
BookContent createBookContent(
  Book book,
  BookStore store, {
  bool requireCacheWrite = false,
}) {
  switch (book.format) {
    case BookFormat.txt:
      return TxtBookContent(book);
    case BookFormat.epub:
      return EpubBookContent(book, store);
    case BookFormat.online:
      return OnlineBookContent(
        book,
        store,
        requireCacheWrite: requireCacheWrite,
      );
  }
}

// ---------- isolate 入口 ----------

String _decodeTxtIsolate(Uint8List bytes) {
  final text = TxtParser.decodeBytes(bytes).text;
  // 章节偏移是按 CRLF 归一化后的文本计算的（见 TxtParser.parseText），
  // 这里必须同样归一化，否则 Windows 换行文本（\r\n）会让章节切片
  // 逐章向前偏移，出现“标题是第 N 章、正文却是第 N-5 章”的问题。
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

String _extractEpubChapterIsolate(Map<String, dynamic> args) {
  final path = args['path'] as String;
  final href = args['href'] as String;
  final parsed = EpubParser.parse(File(path).readAsBytesSync());
  final chapter = parsed.chapters.where((c) => c.href == href).firstOrNull;
  if (chapter == null) return '';
  final dir = Directory('${args['cacheDir']}/img')..createSync(recursive: true);
  for (final image in chapter.images) {
    File('${dir.path}/${image.name}').writeAsBytesSync(image.bytes);
  }
  return chapter.text;
}
