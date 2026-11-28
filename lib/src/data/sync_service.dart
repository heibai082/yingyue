// 缓存自动上传（0.56）：把「已缓存但还没上传」的章节在后台补齐，不用手动点。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import '../source/chapter_order.dart';
import '../source/models.dart';
import '../source/source_store.dart';
import 'book_store.dart';
import 'chapter_cache.dart';
import 'models.dart';
import 'prefs.dart';
import 'stats_store.dart';
import 'sync_client.dart';

class SyncService {
  SyncService({
    required this.prefs,
    required this.store,
    this.marks,
    this.stats,
    this.sources,
    SyncClient? client,
    String platform = 'android',
  }) : _client = client,
       _platform = platform {
    if (client != null) {
      _clientKey =
          '${prefs.syncBaseUrl}|${prefs.syncLanUrl}|${prefs.syncToken}';
    }
  }

  final AppPrefs prefs;
  final BookStore store;
  final BookmarkStore? marks;
  final StatsStore? stats;
  final SourceStore? sources;
  final String _platform;

  SyncClient? _client;
  String _clientKey = '';
  Timer? _debounce;
  bool _started = false;
  bool _applyingRemote = false;
  bool _busy = false;
  Set<String>? _uploaded;

  bool get enabled => prefs.syncEnabled && prefs.syncBaseUrl.trim().isNotEmpty;

  SyncClient get client {
    final key = '${prefs.syncBaseUrl}|${prefs.syncLanUrl}|${prefs.syncToken}';
    if (_client == null || _clientKey != key) {
      _client?.close();
      // 外网地址优先，其次家里内网；哪个能连就用哪个
      _client = SyncClient(
        baseUrls: [prefs.syncBaseUrl, prefs.syncLanUrl],
        token: prefs.syncToken,
      );
      _clientKey = key;
    }
    return _client!;
  }

  void start() {
    if (_started) return;
    _started = true;
    store.addListener(_onLocalChange);
    marks?.addListener(_onLocalChange);
    stats?.addListener(_onLocalChange);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    store.removeListener(_onLocalChange);
    marks?.removeListener(_onLocalChange);
    stats?.removeListener(_onLocalChange);
    _debounce?.cancel();
  }

  void _onLocalChange() {
    if (_applyingRemote || !enabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      unawaited(push(silent: true));
    });
  }

  Map<String, dynamic> _payload() => buildSyncPayload(
    store: store,
    marks: marks,
    stats: stats,
    deviceName: localDeviceLabel(prefs),
    platform: _platform,
  );

  /// 推本地状态到服务器。
  Future<SyncResult> push({bool silent = true}) async {
    if (!enabled || _busy) return const SyncResult(error: '未启用');
    _busy = true;
    try {
      await client.pushState(_payload());
      prefs.setLastSyncAt(DateTime.now().millisecondsSinceEpoch);
      return const SyncResult(pushed: true);
    } catch (e) {
      if (!silent) debugPrint('[sync] push failed: $e');
      return SyncResult(error: '$e');
    } finally {
      _busy = false;
    }
  }

  /// 拉服务器状态并合并（按时间取新）。
  Future<SyncResult> pull() async {
    if (!enabled || _busy) return const SyncResult(error: '未启用');
    _busy = true;
    try {
      final remote = await client.fetchState();
      _applyingRemote = true;
      await importRemoteBooks(remote);
      final applied = applyRemoteState(
        remote,
        store: store,
        marks: marks,
        stats: stats,
      );
      prefs.setLastSyncAt(DateTime.now().millisecondsSinceEpoch);
      return SyncResult(pulled: true, books: applied[0], bookmarks: applied[1]);
    } catch (e) {
      return SyncResult(error: '$e');
    } finally {
      _applyingRemote = false;
      _busy = false;
    }
  }

  /// 把服务器上「本地还没有」的书导入书架（网页「加入书架」用）。
  ///
  /// 需要服务器存了目录 meta、且本机有对应书源；一次最多导 [limit] 本。
  Future<int> importRemoteBooks(
    Map<String, dynamic> remote, {
    int limit = 10,
  }) async {
    final s = sources;
    final raw = remote['books'];
    if (s == null || raw is! List) return 0;
    final local = {for (final b in store.books) b.path};
    var created = 0;
    for (final item in raw) {
      if (created >= limit) break;
      if (item is! Map) continue;
      final path = (item['path'] ?? '').toString();
      if (path.isEmpty || local.contains(path)) continue;
      Map<String, dynamic> meta;
      try {
        final m = await client.fetchBookMeta(path);
        meta = {'sourceUrl': m.sourceUrl, 'chapters': m.chapters};
      } catch (_) {
        continue;
      }
      final chaptersRaw = meta['chapters'] as List? ?? const [];
      if (chaptersRaw.isEmpty) continue;
      BookSource? src;
      for (final x in s.sources) {
        if (x.bookSourceUrl == (meta['sourceUrl'] ?? '')) {
          src = x;
          break;
        }
      }
      if (src == null) continue;
      final chapters = <ChapterRef>[];
      for (final c in chaptersRaw) {
        if (c is! Map) continue;
        final title = (c['title'] ?? '').toString();
        final url = (c['url'] ?? '').toString();
        if (title.isEmpty || url.isEmpty) continue;
        chapters.add(ChapterRef(title: title, href: url));
      }
      if (chapters.isEmpty) continue;
      final sorted = normalizeChapterOrder(
        chapters,
        newestFirst: src.bookSourceType == 2,
      );
      final idx = (item['chapterIndex'] as num?)?.toInt() ?? 0;
      store.addOnline(
        Book(
          id: path,
          title: (item['title'] ?? path).toString(),
          author: (item['author'] ?? '').toString(),
          format: BookFormat.online,
          path: path,
          sourceUrl: (meta['sourceUrl'] ?? '').toString(),
          chapters: sorted,
          chapterIndex: idx.clamp(0, sorted.length - 1),
          lastReadAt: (item['lastReadAt'] as num?)?.toInt() ?? 0,
        ),
      );
      local.add(path);
      created++;
    }
    return created;
  }

  /// 把书源规则推到服务器（同步开启时才发）。
  Future<int> pushSources() async {
    final s = sources;
    if (!enabled || s == null || s.sources.isEmpty) return 0;
    try {
      return await client.uploadSources([
        for (final src in s.sources) src.toJson(),
      ]);
    } catch (e) {
      debugPrint('[sync] upload sources failed: $e');
      return 0;
    }
  }

  /// 从服务器拉书源并**合并**（按 URL 去重，本地已有的保留）。
  Future<int> pullSources() async {
    final s = sources;
    if (!enabled || s == null) return 0;
    try {
      final items = await client.fetchSources();
      if (items.isEmpty) return 0;
      final parsed = <BookSource>[];
      for (final item in items) {
        try {
          parsed.add(BookSource.fromJson(item));
        } catch (_) {}
      }
      if (parsed.isEmpty) return 0;
      s.addAll(parsed);
      await s.flush();
      return parsed.length;
    } catch (e) {
      debugPrint('[sync] pull sources failed: $e');
      return 0;
    }
  }

  /// 手动「立即同步」：先推后拉。
  Future<SyncResult> syncNow() async {
    final pushed = await push(silent: false);
    if (pushed.error != null) return pushed;
    await pushSources();
    final pulled = await pull();
    await pullSources();
    return SyncResult(
      pushed: true,
      pulled: pulled.pulled,
      books: pulled.books,
      bookmarks: pulled.bookmarks,
      error: pulled.error,
    );
  }

  /// 启动时拉一次（没启用就直接返回）。
  Future<SyncResult?> pullOnStartup() async {
    if (!enabled) return null;
    return pull();
  }

  /// 上传一章正文（开了「同步缓存」才发）。
  Future<void> uploadChapterText({
    required String path,
    required int index,
    required String title,
    required String text,
  }) async {
    if (!enabled || !prefs.syncCache) return;
    if (text.trim().isEmpty || text.length > 2 * 1024 * 1024) return;
    try {
      await client.uploadChapter({
        'path': path,
        'index': index,
        'title': title,
        'text': text,
      });
    } catch (e) {
      debugPrint('[sync] upload text failed: $e');
    }
  }

  /// 上传漫画这一话的图片地址（服务端下载图片，网页端直接看）。
  Future<void> uploadChapterImages({
    required String path,
    required int index,
    required String title,
    required List<String> urls,
    String referer = '',
  }) async {
    if (!enabled || !prefs.syncCache || urls.isEmpty) return;
    try {
      await client.uploadChapter({
        'path': path,
        'index': index,
        'title': title,
        'images': urls,
        'referer': referer,
      });
    } catch (e) {
      debugPrint('[sync] upload images failed: $e');
    }
  }
  // ==================== 缓存上传 ====================

  File _uploadedFile() => File('${store.appDirs.files}/sync_uploaded.json');

  Future<Set<String>> _loadUploaded() async {
    final cached = _uploaded;
    if (cached != null) return cached;
    final set = <String>{};
    try {
      final f = _uploadedFile();
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        if (data is List) {
          set.addAll(data.map((e) => '$e'));
        }
      }
    } catch (_) {}
    _uploaded = set;
    return set;
  }

  Future<void> _saveUploaded(Set<String> set) async {
    try {
      final f = _uploadedFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(set.toList()));
    } catch (_) {}
  }

  static String _keyOf(Book b, int idx) => '${b.id}#$idx';

  /// 上传一章（正文或漫画图片字节）。返回 true 表示成功。
  Future<bool> _uploadChapterAt(Book book, int idx) async {
    final dir = ChapterCache.imageDirFor(store.appDirs, book, idx);
    if (dir.existsSync()) {
      final manifest = ChapterCache.readManifest(dir);
      if (manifest == null || manifest.isEmpty) return false;
      final entries = <Map<String, String>>[];
      var bytes = 0;
      for (var i = 0; i < manifest.length; i++) {
        final url = manifest[i]['url'] ?? '';
        final file = ChapterCache.resolveImage(dir, i, url);
        if (file == null) continue;
        final data = await file.readAsBytes();
        bytes += data.length;
        if (bytes > 8 * 1024 * 1024) break;
        entries.add({
          'name': file.uri.pathSegments.last,
          'data': base64Encode(data),
        });
      }
      if (entries.isEmpty) return false;
      await client.uploadChapter({
        'path': book.path,
        'index': idx,
        'title': book.chapters.length > idx
            ? book.chapters[idx].title
            : '第 ${idx + 1} 话',
        'imagesBase64': entries,
      });
      return true;
    }
    final text = await store.readCachedChapter(book, idx);
    if (text == null || text.trim().isEmpty) return false;
    if (text.length > 2 * 1024 * 1024) return false;
    await client.uploadChapter({
      'path': book.path,
      'index': idx,
      'title': book.chapters.length > idx
          ? book.chapters[idx].title
          : '第 ${idx + 1} 章',
      'text': text,
    });
    return true;
  }

  /// 静默同步缓存：先问服务器每本书已有哪几章，只传缺的。
  ///
  /// 不弹窗、不打扰；返回本次上传章数。失败静默，下次再试。
  Future<int> silentSync({int limit = 60, bool force = false}) async {
    if (!enabled || !prefs.syncCache || !prefs.autoUploadCache) return 0;
    if (prefs.syncCacheWifiOnly && !force && !(await NativeBridge.isOnWifi())) {
      return 0;
    }
    Map<String, Set<int>> remote;
    try {
      remote = await client.fetchChapterIndex();
    } catch (e) {
      debugPrint('[sync] 读服务器索引失败，退回本地记录: $e');
      remote = const {};
    }
    final uploaded = await _loadUploaded();
    final pending = <({Book book, int idx})>[];
    for (final book in store.books) {
      if (book.chapterCache.isEmpty) continue;
      final have = remote[book.path] ?? const <int>{};
      for (final idx in book.chapterCache.toList()..sort()) {
        if (have.contains(idx)) {
          uploaded.add(_keyOf(book, idx)); // 服务器已有，记下来别再试
          continue;
        }
        if (!uploaded.contains(_keyOf(book, idx))) {
          pending.add((book: book, idx: idx));
        }
      }
    }
    if (pending.isEmpty) {
      await _saveUploaded(uploaded);
      return 0;
    }
    var done = 0;
    for (final item in pending.take(limit)) {
      try {
        if (await _uploadChapterAt(item.book, item.idx)) {
          uploaded.add(_keyOf(item.book, item.idx));
          done++;
        }
      } catch (e) {
        debugPrint('[sync] 静默上传失败: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await _saveUploaded(uploaded);
    return done;
  }

  /// 本地缓存里、服务器还没有的章节数（给界面提示用）。
  Future<int> pendingCacheCount() async {
    if (!enabled) return 0;
    Map<String, Set<int>> remote = const {};
    try {
      remote = await client.fetchChapterIndex();
    } catch (_) {}
    var n = 0;
    for (final book in store.books) {
      final have = remote[book.path] ?? const <int>{};
      for (final idx in book.chapterCache) {
        if (!have.contains(idx)) n++;
      }
    }
    return n;
  }

  /// 自动补齐：把「已缓存但没上传」的章节传上去，每次最多 [limit] 章。
  ///
  /// 只在开了自动上传、且（可选）在 Wi-Fi 下运行；失败不抛错，下次再试。
  Future<int> autoPushPending({int limit = 20, bool force = false}) async {
    if (!enabled || !prefs.syncCache || !prefs.autoUploadCache) return 0;
    if (prefs.syncCacheWifiOnly && !force) {
      final wifi = await NativeBridge.isOnWifi();
      if (!wifi) return 0;
    }
    final uploaded = await _loadUploaded();
    final pending = <({Book book, int idx})>[];
    for (final book in store.books) {
      if (book.chapterCache.isEmpty) continue;
      for (final idx in book.chapterCache.toList()..sort()) {
        if (!uploaded.contains(_keyOf(book, idx))) {
          pending.add((book: book, idx: idx));
        }
      }
    }
    if (pending.isEmpty) return 0;
    var done = 0;
    for (final item in pending.take(limit)) {
      try {
        if (await _uploadChapterAt(item.book, item.idx)) {
          uploaded.add(_keyOf(item.book, item.idx));
          done++;
        }
      } catch (e) {
        debugPrint('[sync] auto upload failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _saveUploaded(uploaded);
    return done;
  }

  /// 手动「上传本机缓存」：一次把全部待传的传完。
  Future<({int books, int chapters, int skipped})> pushCachedContent({
    void Function(int done, int total)? onProgress,
  }) async {
    if (!enabled || !prefs.syncCache)
      return (books: 0, chapters: 0, skipped: 0);
    final uploaded = await _loadUploaded();
    final targets = [
      for (final b in store.books)
        if (b.chapterCache.isNotEmpty) b,
    ];
    var total = 0;
    for (final b in targets) {
      total += b.chapterCache.length;
    }
    var done = 0;
    var okCount = 0;
    var skipped = 0;
    for (final book in targets) {
      for (final idx in book.chapterCache.toList()..sort()) {
        done++;
        onProgress?.call(done, total);
        try {
          if (await _uploadChapterAt(book, idx)) {
            uploaded.add(_keyOf(book, idx));
            okCount++;
          } else {
            skipped++;
          }
        } catch (e) {
          debugPrint('[sync] 上传缓存失败 ${book.title}#$idx: $e');
          skipped++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    await _saveUploaded(uploaded);
    return (books: targets.length, chapters: okCount, skipped: skipped);
  }

  void dispose() {
    stop();
    _client?.close();
  }
}
