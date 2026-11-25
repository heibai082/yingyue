// 同步调度：变化就推（防抖 3 秒），启动拉一次（0.52）。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'book_store.dart';
import 'prefs.dart';
import 'stats_store.dart';
import 'sync_client.dart';

class SyncService {
  SyncService({
    required this.prefs,
    required this.store,
    this.marks,
    this.stats,
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
  final String _platform;

  SyncClient? _client;
  String _clientKey = '';
  Timer? _debounce;
  bool _started = false;
  bool _applyingRemote = false;
  bool _busy = false;

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

  /// 手动「立即同步」：先推后拉。
  Future<SyncResult> syncNow() async {
    final pushed = await push(silent: false);
    if (pushed.error != null) return pushed;
    final pulled = await pull();
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

  void dispose() {
    stop();
    _client?.close();
  }
}
