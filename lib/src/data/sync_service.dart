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
    if (client != null) _clientKey = '${prefs.syncBaseUrl}|${prefs.syncToken}';
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
    final key = '${prefs.syncBaseUrl}|${prefs.syncToken}';
    if (_client == null || _clientKey != key) {
      _client?.close();
      _client = SyncClient(baseUrl: prefs.syncBaseUrl, token: prefs.syncToken);
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

  void dispose() {
    stop();
    _client?.close();
  }
}
