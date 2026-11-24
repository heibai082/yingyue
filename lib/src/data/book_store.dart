import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'persistence.dart';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import 'epub_parser.dart';
import 'file_scan.dart';
import 'cache_plan.dart';
import 'chapter_cache.dart';
import 'models.dart';
import '../source/chapter_order.dart';
import 'stats_store.dart';
import 'txt_parser.dart';

/// 导入结果。
class ImportResult {
  ImportResult.ok(Book this.book) : error = null;

  ImportResult.fail(this.error) : book = null;

  final Book? book;
  final String? error;

  bool get success => book != null;
}

/// 书架数据：JSON 持久化 + 导入 + 阅读进度。
class BookStore extends ChangeNotifier with ReliablePersistence {
  BookStore({this._dirsOverride});

  final AppDirs? _dirsOverride;
  final List<Book> _books = [];
  AppDirs? _dirs;
  File? _file;
  Timer? _saveTimer;
  bool _disposed = false;

  List<Book> get books => List.unmodifiable(_books);

  Directory get coverDir =>
      Directory('${_dirs?.files ?? Directory.systemTemp.path}/covers');

  AppDirs get _dirsOrTemp =>
      _dirs ??
      AppDirs(
        files: Directory.systemTemp.path,
        cache: Directory.systemTemp.path,
      );

  /// 正文缓存根：**持久目录**（`<files>/books`）。
  ///
  /// 用户反馈「每次升级就重新开始缓存」——以前这里是 `<cache>/books`，
  /// 系统 / 手机管家 / 覆盖安装都可能清掉。见 `chapter_cache.dart`。
  Directory get chapterCacheRoot => ChapterCache.root(_dirsOrTemp);

  /// 一本书的缓存目录（在线书按「书页地址 + 书源」算，重新导入也对得上）。
  Directory chapterCacheDir(String bookId) {
    final book = byId(bookId);
    if (book != null) return ChapterCache.dirFor(_dirsOrTemp, book);
    return Directory('${chapterCacheRoot.path}/$bookId');
  }

  /// 这一章是否已经在磁盘上（空文件不算）。
  ///
  /// - 小说：正文文件存在且非空；
  /// - 漫画：没有正文文件，看「这一话的图片目录」里有没有图（0.42 起图片真的落盘）。
  bool hasCachedChapter(Book book, int index) {
    if (index < 0 || index >= book.chapters.length) return false;
    try {
      final f = ChapterCache.fileFor(_dirsOrTemp, book, index);
      if (f.existsSync() && f.lengthSync() > 0) return true;
      final img = ChapterCache.imageDirFor(_dirsOrTemp, book, index);
      if (!img.existsSync()) return false;
      for (final e in img.listSync(followLinks: false)) {
        if (e is File) {
          try {
            if (e.lengthSync() > 0) return true;
          } catch (_) {}
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 读缓存正文；没有 / 读失败返回 null。
  Future<String?> readCachedChapter(Book book, int index) async {
    if (!hasCachedChapter(book, index)) return null;
    try {
      final text = await ChapterCache.fileFor(
        _dirsOrTemp,
        book,
        index,
      ).readAsString();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 写缓存正文（落盘失败会抛，调用方按需要吞）。
  Future<void> writeCachedChapter(
    Book book,
    int index,
    String text, {
    bool flush = false,
  }) async {
    final file = ChapterCache.fileFor(_dirsOrTemp, book, index);
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: flush);
  }

  Future<void> load() async {
    _dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${_dirs!.files}/library.json');
    try {
      if (await _file!.exists()) {
        final data = await readJson(_file!);
        if (data is Map && data['books'] is List) {
          for (final item in data['books'] as List) {
            if (item is Map) {
              try {
                final book = Book.fromJson(Map<String, dynamic>.from(item));
                _repairChapterOrder(book);
                _books.add(book);
              } catch (_) {
                // 跳过坏数据
              }
            }
          }
        }
      }
    } catch (_) {
      // 读取失败时以空书架启动
    }
    notifyListeners();
    // 老版本的缓存放在「系统缓存目录 + 按章序号命名」的地方：能搬的搬过来，
    // 搬不动的（对不上号）就别当缓存用，免得把别的章正文当成这一章。
    unawaited(migrateLegacyCaches());
  }

  /// 把旧位置的章节缓存搬进持久目录（`<files>/books`）。
  ///
  /// 背景：0.43 及以前正文缓存在 `<cache>/books/<book.id>/ch_v2_<序号>.txt`，
  /// 系统清理 / 覆盖安装会把它清空（用户反馈「每次升级就重新开始缓存」）；
  /// 而且按序号命名，漫画目录一插新话就整体错位。
  ///
  /// 搬家规则：
  ///   - 漫画（目录里有 `img/` 或 `comic_list_cache.json`）：图片与清单本来就按
  ///     章节链接命名，直接整个目录改名，零风险；
  ///   - 小说：用「章节标题出现在缓存正文里」来核对序号位移（漫画源会往最前面
  ///     插新话，老序号要整体 +k），对得上才搬；对不上就留在原地不用。
  Future<void> migrateLegacyCaches() async {
    if (_disposed) return;
    final dirs = _dirsOrTemp;
    final legacyRoot = ChapterCache.legacyRoot(dirs);
    try {
      if (!await legacyRoot.exists()) return;
    } catch (_) {
      return;
    }
    var changed = false;
    for (final book in List<Book>.of(_books)) {
      if (book.format != BookFormat.online) continue;
      try {
        final target = ChapterCache.dirFor(dirs, book);
        if (await target.exists()) continue;
        final legacy = Directory('${legacyRoot.path}/${book.id}');
        if (!await legacy.exists()) continue;
        if (await _migrateOneBook(book, legacy, target)) changed = true;
      } catch (_) {
        // 单本失败不影响其它书
      }
    }
    if (changed && !_disposed) notifyListeners();
  }

  Future<bool> _migrateOneBook(
    Book book,
    Directory legacy,
    Directory target,
  ) async {
    // ---- 漫画：图片 + 清单都按链接命名，整目录搬 ----
    final imgDir = Directory('${legacy.path}/img');
    final listCache = File('${legacy.path}/comic_list_cache.json');
    final isComic = await imgDir.exists() || await listCache.exists();
    if (isComic) {
      await target.parent.create(recursive: true);
      await legacy.rename(target.path);
      // 0.42~0.43 的图片目录名是 32 位 hash，改成新的 64 位（否则「已缓存」会算 0）
      await _renameLegacyImageDirs(book, target);
      return true;
    }

    // ---- 小说：先收集旧文件 ----
    final legacyFiles = <int, File>{};
    await for (final e in legacy.list(followLinks: false)) {
      if (e is! File) continue;
      final m = RegExp(r'^ch_v2_(\d+)\.txt$')
          .firstMatch(e.uri.pathSegments.last);
      if (m == null) continue;
      final index = int.tryParse(m.group(1)!);
      if (index == null) continue;
      try {
        if (await e.length() > 0) legacyFiles[index] = e;
      } catch (_) {}
    }
    if (legacyFiles.isEmpty) return false;

    // ---- 找序号位移：漫画插新话会让老文件整体后移 ----
    final shift = await _guessShift(book, legacyFiles);
    if (shift == null) return false;
    await target.create(recursive: true);
    var moved = 0;
    for (final entry in legacyFiles.entries) {
      final index = entry.key + shift;
      if (index < 0 || index >= book.chapters.length) continue;
      final dest = ChapterCache.fileFor(_dirsOrTemp, book, index);
      try {
        if (await dest.exists()) continue;
        final bytes = await entry.value.readAsBytes();
        await dest.writeAsBytes(bytes, flush: false);
        moved++;
      } catch (_) {}
    }
    if (moved > 0) {
      try {
        await legacy.delete(recursive: true);
      } catch (_) {}
    }
    return moved > 0;
  }

  /// 把老图片目录 `img/<32位hash>` 改名成现在的 `img/<64位hash>`。
  Future<void> _renameLegacyImageDirs(Book book, Directory bookDir) async {
    final imgRoot = Directory('${bookDir.path}/img');
    try {
      if (!await imgRoot.exists()) return;
    } catch (_) {
      return;
    }
    for (final chapter in book.chapters) {
      final href = (chapter.href ?? '').trim();
      if (href.isEmpty) continue;
      try {
        final from = Directory(
          '${imgRoot.path}/${ChapterCache.legacyImageKey(href)}',
        );
        if (!await from.exists()) continue;
        final to = Directory(
          '${imgRoot.path}/${ChapterCache.chapterKey(chapter, book.chapters.indexOf(chapter))}',
        );
        if (await to.exists()) continue;
        await from.rename(to.path);
      } catch (_) {}
    }
  }

  /// 猜「旧文件序号 → 现在序号」的位移；猜不出返回 null。
  Future<int?> _guessShift(Book book, Map<int, File> legacyFiles) async {
    final total = book.chapters.length;
    if (total == 0) return null;
    // 站点只会往「最新」那头插新话：降序目录 → 老序号整体 +k（k ≥ 0）
    final maxShift = looksNewestFirst(book.chapters) ? 120 : 0;
    // 抽样：均匀取最多 8 章核对标题
    final samples = <int>[];
    final step = total <= 8 ? 1 : total ~/ 8;
    for (var i = 0; i < total && samples.length < 8; i += step) {
      if (_titleNeedle(book.chapters[i]) != null) samples.add(i);
    }
    if (samples.isEmpty) {
      // 标题都没法用来核对：这本书从没追更过（lastTrackedAt == 0）时，
      // 序号可以认为没变；否则宁可不搬。
      return book.lastTrackedAt == 0 ? 0 : null;
    }
    int bestShift = 0;
    var bestScore = -1;
    for (var shift = 0; shift <= maxShift; shift++) {
      var score = 0;
      var checked = 0;
      for (final i in samples) {
        final old = legacyFiles[i + shift];
        if (old == null) continue;
        checked++;
        final needle = _titleNeedle(book.chapters[i]);
        if (needle == null) continue;
        try {
          final text = await old.readAsString();
          if (text.contains(needle)) score++;
        } catch (_) {}
      }
      if (checked == 0) continue;
      if (score > bestScore) {
        bestScore = score;
        bestShift = shift;
      }
    }
    if (bestScore <= 0) return null;
    // 至少要过半命中，避免把错位的文件当成缓存
    return bestScore * 2 >= samples.length ? bestShift : null;
  }

  /// 从标题里取一段「正文里一定会出现」的字：去掉「第 12 话」前缀，取正文味最浓的片段。
  static String? _titleNeedle(ChapterRef chapter) {
    var t = chapter.title.trim();
    if (t.isEmpty) return null;
    t = t.replaceFirst(RegExp(r'^第\s*\d+\s*[话話章集回卷篇节]\s*'), '').trim();
    if (t.length < 2) return null;
    return t.length > 12 ? t.substring(0, 12) : t;
  }

  /// 老数据修复：漫画目录被站点「最新几话前置」搞成重复 + 乱序时，
  /// 按序号重排一次（只对「第一话序号 > 最后一话序号」的书动手）。
  static void _repairChapterOrder(Book book) {
    if (book.format != BookFormat.online) return;
    if (book.chapters.length < 2) return;
    if (!looksNewestFirst(book.chapters)) return;
    // 记住「当前看的是哪一话」，重排后再按链接找回它的新位置，
    // 否则进度序号会指到别的章节上
    final currentHref =
        book.chapterIndex >= 0 && book.chapterIndex < book.chapters.length
        ? book.chapters[book.chapterIndex].href
        : null;
    final fixed = normalizeChapterOrder(book.chapters, newestFirst: true);
    book.chapters
      ..clear()
      ..addAll(fixed);
    if (currentHref != null && currentHref.isNotEmpty) {
      final idx = book.chapters.indexWhere((c) => c.href == currentHref);
      if (idx >= 0) book.chapterIndex = idx;
    }
  }

  Book? byId(String id) {
    for (final b in _books) {
      if (b.id == id) return b;
    }
    return null;
  }

  bool containsPath(String path) => _books.any((b) => b.path == path);

  /// 在线书籍：按书页地址查找。
  Book? onlineByPath(String path) {
    for (final b in _books) {
      if (b.format == BookFormat.online && b.path == path) return b;
    }
    return null;
  }

  /// 加入一本在线书籍（同一书页地址已存在时直接返回已有条目）。
  Book addOnline(Book book) {
    final existing = onlineByPath(book.path);
    if (existing != null) return existing;
    _books.add(book);
    _saveSoon();
    notifyListeners();
    return book;
  }

  /// 在线书籍：切换书源（更新书页地址 / 源地址 / 目录，并清空该书的章节缓存）。
  ///
  /// 保留阅读进度（章节序号夹取到新目录范围，章内偏移归零）。
  Future<void> switchOnlineSource(
    String id, {
    required String path,
    required String sourceUrl,
    required List<ChapterRef> chapters,
    String? title,
    String? author,
    String? intro,
  }) async {
    final b = byId(id);
    if (b == null || b.format != BookFormat.online) return;
    b.path = path;
    b.sourceUrl = sourceUrl;
    b.chapters
      ..clear()
      ..addAll(chapters);
    final t = (title ?? '').trim();
    if (t.isNotEmpty) b.title = t;
    final a = (author ?? '').trim();
    if (a.isNotEmpty) b.author = a;
    final i = (intro ?? '').trim();
    if (i.isNotEmpty) b.intro = i;
    b.chapterIndex = chapters.isEmpty
        ? 0
        : b.chapterIndex.clamp(0, chapters.length - 1).toInt();
    b.charOffset = 0;
    b.lastReadAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final dir = chapterCacheDir(id);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _saveSoon();
    notifyListeners();
  }

  /// 从书架移除一本书。
  ///
  /// [deleteLocalFile] 为 true 时顺带删除这本书的本地文件（用户反馈：
  /// 想把书移走时直接连着本地文件一起删掉）。只删书架里登记的那个文件，
  /// 同一路径被另一本书引用时保留，避免误删别人还在用的书。
  Future<void> removeById(String id, {bool deleteLocalFile = false}) async {
    final book = byId(id);
    if (book == null) return;
    final before = _books.length;
    _books.removeWhere((b) => b.id == id);
    if (_books.length == before) return;
    // 移除书时联动清理其书签
    BookmarkStore.shared?.removeForBook(id);
    _saveSoon();
    notifyListeners();
    if (!deleteLocalFile) return;
    final path = book.path;
    if (path.isEmpty) return;
    // 还有别的书在用同一个文件 → 不删
    final shared = _books.any((b) => b.path == path);
    if (shared) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败（权限 / 文件已被外部删掉）不影响「移除」本身
    }
  }

  void rename(String id, String title) {
    final b = byId(id);
    if (b == null) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed == b.title) return;
    b.title = trimmed;
    _saveSoon();
    notifyListeners();
  }

  /// 设置书籍分组（'' = 未分组）。
  ///
  /// 用户反馈：「书架里的书籍可以分组吗自定义分组」——分组只是书架上的
  /// 归类标签，不动文件、不影响阅读进度。
  void setGroup(String id, String group) {
    final b = byId(id);
    if (b == null) return;
    final trimmed = group.trim();
    if (b.group == trimmed) return;
    b.group = trimmed;
    _saveSoon();
    notifyListeners();
  }

  void touch(String id) {
    final b = byId(id);
    if (b == null) return;
    b.lastReadAt = DateTime.now().millisecondsSinceEpoch;
    _saveSoon();
  }

  void updateProgress(String id, {int? chapter, int? offset, bool? finished}) {
    final b = byId(id);
    if (b == null) return;
    if (chapter != null) b.chapterIndex = chapter;
    if (offset != null) b.charOffset = offset;
    if (finished != null) b.finished = finished;
    b.lastReadAt = DateTime.now().millisecondsSinceEpoch;
    _saveSoon();
    notifyListeners();
  }

  void markUnread(String id) {
    final b = byId(id);
    if (b == null) return;
    b.chapterIndex = 0;
    b.charOffset = 0;
    b.finished = false;
    _saveSoon();
    notifyListeners();
  }

  /// 换掉某本书的封面（「一键更新封面」用）。返回是否真的更新了。
  bool setCover(String id, String coverPath) {
    final b = byId(id);
    if (b == null) return false;
    if (b.coverPath == coverPath && !b.generatedCover) return false;
    b.coverPath = coverPath;
    b.generatedCover = false;
    _saveSoon();
    notifyListeners();
    return true;
  }

  void markFinished(String id) {
    final b = byId(id);
    if (b == null) return;
    b.finished = true;
    _saveSoon();
    notifyListeners();
  }

  // ---------- 导入 ----------

  Future<ImportResult> importFile(
    String path, {
    void Function(String message)? onProgress,
  }) async {
    if (containsPath(path)) return ImportResult.fail('已经在书架里了');
    final ext = pathExtension(path);
    try {
      if (ext == 'txt') {
        return ImportResult.ok(await _importTxt(path, onProgress));
      }
      if (ext == 'epub') {
        return ImportResult.ok(await _importEpub(path, onProgress));
      }
      return ImportResult.fail('不支持的格式 .$ext（仅支持 txt / epub）');
    } on EpubException catch (e) {
      return ImportResult.fail(e.message);
    } catch (e) {
      return ImportResult.fail('导入失败：$e');
    }
  }

  void _add(Book book) {
    _books.add(book);
    _saveSoon();
    notifyListeners();
  }

  Future<Book> _importTxt(
    String path,
    void Function(String)? onProgress,
  ) async {
    onProgress?.call('读取 TXT…');
    final bytes = await File(path).readAsBytes();
    onProgress?.call('解析编码与章节…');
    final map = await compute(_parseTxtIsolate, bytes);
    final rawChapters = map['chapters'] as List;
    final chapters = <ChapterRef>[];
    for (final item in rawChapters) {
      final m = item as Map;
      final start = (m['start'] as num).toInt();
      final end = (m['end'] as num).toInt();
      chapters.add(
        ChapterRef(
          title: m['title'] as String,
          start: start,
          end: end,
          charCount: end - start,
        ),
      );
    }
    final book = Book(
      id: Book.newId(),
      title: pathBaseName(path),
      author: (map['author'] as String?) ?? '',
      format: BookFormat.txt,
      path: path,
      intro: (map['intro'] as String?) ?? '',
      chapters: chapters,
      totalChars: chapters.fold(0, (sum, c) => sum + c.charCount),
    );
    _add(book);
    return book;
  }

  Future<Book> _importEpub(
    String path,
    void Function(String)? onProgress,
  ) async {
    onProgress?.call('读取 EPUB…');
    final bytes = await File(path).readAsBytes();
    final id = Book.newId();
    final cacheDir = chapterCacheDir(id);
    onProgress?.call('解析 EPUB 结构…');
    final map = await compute(_parseEpubIsolate, {
      'bytes': bytes,
      'cacheDir': cacheDir.path,
    });
    final meta = (map['meta'] as Map?) ?? const {};
    final rawChapters = map['chapters'] as List;
    final chapters = <ChapterRef>[];
    var total = 0;
    for (final item in rawChapters) {
      final m = item as Map;
      final count = (m['charCount'] as num).toInt();
      total += count;
      chapters.add(
        ChapterRef(
          title: m['title'] as String,
          href: m['href'] as String,
          charCount: count,
        ),
      );
    }

    String? coverPath;
    var generatedCover = true;
    final coverBytes = map['cover'] as Uint8List?;
    if (coverBytes != null && coverBytes.length > 100) {
      final ext = (map['coverExt'] as String?) ?? 'png';
      final dir = coverDir;
      await dir.create(recursive: true);
      final f = File('${dir.path}/$id.$ext');
      await f.writeAsBytes(coverBytes, flush: false);
      coverPath = f.path;
      generatedCover = false;
    }

    final title = ((meta['title'] as String?) ?? '').trim();
    final book = Book(
      id: id,
      title: title.isNotEmpty ? title : pathBaseName(path),
      author: ((meta['author'] as String?) ?? '').trim(),
      format: BookFormat.epub,
      path: path,
      coverPath: coverPath,
      generatedCover: generatedCover,
      intro: ((meta['intro'] as String?) ?? '').trim(),
      chapters: chapters,
      totalChars: total,
    );
    _add(book);
    return book;
  }

  // ---------- 缓存管理 ----------

  Future<int> cacheSizeBytes() async {
    var total = 0;
    try {
      if (await chapterCacheRoot.exists()) {
        await for (final e in chapterCacheRoot.list(
          recursive: true,
          followLinks: false,
        )) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> clearCache() async {
    try {
      if (await chapterCacheRoot.exists()) {
        await chapterCacheRoot.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 某本书已缓存的章节数（在线书离线缓存用）。
  ///
  /// 按「章节链接 → 文件名」逐个核对：只有真正抓到正文才会写文件，
  /// 所以这个数字就是「断网也能读的章节数」。目录顺序变了也不会算错。
  Future<int> cachedChapterCount(String bookId) async {
    final book = byId(bookId);
    if (book == null) return 0;
    var n = 0;
    for (var i = 0; i < book.chapters.length; i++) {
      if (hasCachedChapter(book, i)) n++;
    }
    return n;
  }

  /// 某本书的缓存占用（字节）。
  Future<int> bookCacheBytes(String bookId) async {
    var total = 0;
    try {
      final dir = chapterCacheDir(bookId);
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return total;
  }

  /// 清除某本书的章节缓存（该书改源 / 想重新抓取时用）。
  Future<void> clearBookCache(String bookId) async {
    try {
      final dir = chapterCacheDir(bookId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    byId(bookId)?.chapterCache = const {};
    notifyListeners();
  }

  /// 扫一遍这本书的缓存，把「真正存了正文」的章节序号记到 [Book.chapterCache]。
  ///
  /// 文件名按章节链接算（见 [ChapterCache]），所以「同目录不同序号」也能认出来。
  Future<Set<int>> refreshChapterCache(String bookId) async {
    final book = byId(bookId);
    if (book == null) return <int>{};
    final set = <int>{};
    for (var i = 0; i < book.chapters.length; i++) {
      if (hasCachedChapter(book, i)) set.add(i);
    }
    book.chapterCache = set;
    return set;
  }

  /// 更新一本书的缓存范围偏好（详情页「缓存设置」）。
  void setCachePlan(String id, BookCachePlan plan) {
    final b = byId(id);
    if (b == null) return;
    b.cachePlan = plan.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // 换了范围就丢掉上一轮的追更结果，免得把旧新章混进来
    b.discoveredChapters = const [];
    _saveSoon();
    notifyListeners();
  }

  /// 记下「这本书刚跟站点对过目录」（追更节流用）。
  void markTracked(String id) {
    final b = byId(id);
    if (b == null) return;
    b.lastTrackedAt = DateTime.now().millisecondsSinceEpoch;
    _saveSoon();
  }

  /// 把追更发现的新章节并入目录。
  ///
  /// 阅读进度按「章节链接」找回原章节的新位置（目录方向可能变、新章可能插在
  /// 最前面）；找不到就夹取到合法范围，绝不抛异常。
  void applyChapterUpdates(String id) {
    final b = byId(id);
    if (b == null) return;
    final added = b.discoveredChapters;
    if (added.isEmpty) return;

    final prevHref = b.chapterIndex >= 0 && b.chapterIndex < b.chapters.length
        ? b.chapters[b.chapterIndex].href
        : null;
    // 目录方向以原有目录为准（新章只有一两条时判断不出方向）
    final newestFirst = b.chapters.length >= 2
        ? looksNewestFirst(b.chapters)
        : looksNewestFirst(added);
    final merged = appendNewChapters(
      b.chapters,
      added,
      newestFirst: newestFirst,
    );
    b.chapters
      ..clear()
      ..addAll(merged);
    b.discoveredChapters = const [];

    // 进度：按章节链接找回去；老数据没链接就按原序号夹取
    var index = prevHref == null || prevHref.isEmpty
        ? -1
        : b.chapters.indexWhere((c) => c.href == prevHref);
    if (b.chapters.isEmpty) {
      b.chapterIndex = 0;
    } else {
      b.chapterIndex = (index < 0 ? b.chapterIndex : index)
          .clamp(0, b.chapters.length - 1)
          .toInt();
    }
    b.totalChars = b.chapters.fold<int>(0, (n, c) => n + c.charCount);
    // 目录变了 → 缓存序号的含义也变了，让上层重新扫
    b.chapterCache = const {};
    _saveSoon();
    notifyListeners();
  }

  // ---------- 持久化 ----------

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save().catchError((Object _) {}));
    });
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    return _save();
  }

  Future<void> _save() {
    final file = _file;
    if (file == null) return Future.value();
    return writeJson(
      file,
      jsonEncode({
        'version': 1,
        'books': _books.map((b) => b.toJson()).toList(),
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    unawaited(flush().catchError((Object _) {}));
    super.dispose();
  }
}

// ---------- isolate 入口（避免大文件解析卡 UI） ----------

Map<String, dynamic> _parseTxtIsolate(Uint8List bytes) {
  final r = TxtParser.parseBytes(bytes);
  return {
    'chapters': r.chapters
        .map((c) => {'title': c.title, 'start': c.start, 'end': c.end})
        .toList(),
    'author': guessAuthor(r.text),
    'intro': guessIntro(r.text),
  };
}

Map<String, dynamic> _parseEpubIsolate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final cacheDirPath = args['cacheDir'] as String;
  final r = EpubParser.parse(bytes);
  Directory(cacheDirPath).createSync(recursive: true);
  // 插图目录（用户反馈「书里的插图不能加载」）
  final imgDir = Directory('$cacheDirPath/img');
  var imgTotal = 0;
  final chapters = <Map<String, dynamic>>[];
  for (var i = 0; i < r.chapters.length; i++) {
    final c = r.chapters[i];
    // 先把本章插图落盘（正文里的占位标记按文件名查找）
    for (final img in c.images) {
      try {
        imgDir.createSync(recursive: true);
        File('${imgDir.path}/${img.name}').writeAsBytesSync(img.bytes);
        imgTotal++;
      } catch (_) {
        // 单张图失败不影响正文
      }
    }
    final name = 'ch_${i.toString().padLeft(4, '0')}.txt';
    File('$cacheDirPath/$name').writeAsStringSync(c.text);
    chapters.add({'href': c.href, 'title': c.title, 'charCount': c.charCount});
  }
  return {
    'meta': {
      'title': r.meta.title,
      'author': r.meta.author,
      'intro': r.meta.intro,
    },
    'chapters': chapters,
    'cover': r.coverBytes,
    'coverExt': r.coverExtension,
    'imageCount': imgTotal,
  };
}

/// 从开头文本猜测作者（"作者：xxx"）。
String guessAuthor(String text) {
  final head = text.length > 1500 ? text.substring(0, 1500) : text;
  final match = RegExp(r'作\s*者[：:\s]\s*([^\n\r]{1,30})').firstMatch(head);
  final author = match?.group(1)?.trim() ?? '';
  return author.length > 20 ? '' : author;
}

/// 从开头文本猜测简介。
String guessIntro(String text) {
  final lines = text.split('\n');
  final picked = <String>[];
  for (final line in lines.take(12)) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^作\s*者|^简\s*介|^第.{1,12}[章回节]').hasMatch(t)) continue;
    picked.add(t);
    if (picked.length >= 2) break;
  }
  var intro = picked.join(' ');
  if (intro.length > 120) intro = '${intro.substring(0, 120)}…';
  return intro;
}
