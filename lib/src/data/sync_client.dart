// 跟「嘤阅同步服务」通信：状态推送/拉取、备份上传（0.52）。
//
// 设计：
//   - 只传「书架进度 + 书签 + 统计」，不传正文 / 缓存 / 书源规则；
//   - 合并规则永远是「按时间取新」，双设备不会互相回退；
//   - 网络失败静默（下次再推），不阻断阅读。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'book_store.dart';
import 'prefs.dart';
import 'stats_store.dart';

/// 设备信息（面板里显示）。
String localDeviceLabel(AppPrefs prefs) {
  final custom = prefs.syncDeviceName.trim();
  if (custom.isNotEmpty) return custom;
  return '我的设备';
}

/// 组装要推给服务器的状态。
Map<String, dynamic> buildSyncPayload({
  required BookStore store,
  BookmarkStore? marks,
  StatsStore? stats,
  required String deviceName,
  required String platform,
}) {
  return {
    'version': 1,
    'devices': {
      deviceName: {'name': deviceName, 'platform': platform},
    },
    'books': [
      for (final b in store.books)
        {
          'path': b.path,
          'id': b.id,
          'title': b.title,
          'author': b.author,
          'chapterIndex': b.chapterIndex,
          'charOffset': b.charOffset,
          'lastReadAt': b.lastReadAt,
          'finished': b.finished,
          'group': b.group,
          'total': b.chapterCount,
          'format': b.format.name,
        },
    ],
    'bookmarks': [
      for (final m in marks?.items ?? const <Bookmark>[]) m.toJson(),
    ],
    'stats': {
      'totalSeconds': stats?.totalSeconds ?? 0,
      'finishedBooks': stats?.finishedBooks ?? 0,
      'days': stats?.days ?? const <String, int>{},
    },
  };
}

/// 把服务器状态合并进本地；返回 [booksApplied, bookmarksAdded]。
List<int> applyRemoteState(
  Map<String, dynamic> remote, {
  required BookStore store,
  BookmarkStore? marks,
  StatsStore? stats,
}) {
  var books = 0;
  var added = 0;
  final rawBooks = remote['books'];
  if (rawBooks is List) {
    for (final item in rawBooks) {
      if (item is! Map) continue;
      final path = (item['path'] ?? '').toString();
      if (path.isEmpty) continue;
      final changed = store.applyRemoteProgress(
        path,
        chapterIndex: (item['chapterIndex'] as num?)?.toInt() ?? 0,
        charOffset: (item['charOffset'] as num?)?.toInt() ?? 0,
        finished: item['finished'] as bool? ?? false,
        lastReadAt: (item['lastReadAt'] as num?)?.toInt() ?? 0,
      );
      if (changed) books++;
    }
  }
  final rawMarks = remote['bookmarks'];
  if (rawMarks is List && marks != null) {
    for (final item in rawMarks) {
      if (item is! Map) continue;
      try {
        final before = marks.count;
        marks.addNote(Bookmark.fromJson(Map<String, dynamic>.from(item)));
        if (marks.count > before) added++;
      } catch (_) {}
    }
  }
  final rawStats = remote['stats'];
  if (rawStats is Map && stats != null) {
    final days = <String, int>{};
    final rawDays = rawStats['days'];
    if (rawDays is Map) {
      for (final e in rawDays.entries) {
        final v = (e.value as num?)?.toInt();
        if (v != null) days['${e.key}'] = v;
      }
    }
    stats.mergeRemote(
      totalSeconds: (rawStats['totalSeconds'] as num?)?.toInt(),
      finishedBooks: (rawStats['finishedBooks'] as num?)?.toInt(),
      days: days,
    );
  }
  return [books, added];
}

/// HTTP 客户端（可注入 MockClient 测试）。
class SyncClient {
  SyncClient({
    required String baseUrl,
    required this.token,
    http.Client? client,
  }) : _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client();

  final String _base;
  final String token;
  final http.Client _client;

  bool get configured => _base.isNotEmpty;

  Uri _u(String path) => Uri.parse('$_base$path');

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json; charset=utf-8',
  };

  /// 健康检查（不需要令牌）。
  Future<bool> ping() async {
    if (!configured) return false;
    try {
      final r = await _client
          .get(_u('/api/health'))
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> fetchState() async {
    final r = await _client
        .get(_u('/api/state'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw StateError('拉取失败（HTTP ${r.statusCode}）');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<void> pushState(Map<String, dynamic> payload) async {
    final r = await _client
        .post(_u('/api/state'), headers: _headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) {
      throw StateError('推送失败（HTTP ${r.statusCode}）');
    }
  }

  /// 上传备份 zip（走 /api/backups，服务端自动保留最近 N 份）。
  Future<String?> uploadBackup(List<int> zipBytes) async {
    final r = await _client
        .post(
          _u('/api/backups'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/zip',
          },
          body: zipBytes,
        )
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw StateError('上传备份失败（HTTP ${r.statusCode}）');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    return data is Map ? data['name']?.toString() : null;
  }

  void close() => _client.close();
}

/// 一次同步的结果。
class SyncResult {
  const SyncResult({
    this.pushed = false,
    this.pulled = false,
    this.books = 0,
    this.bookmarks = 0,
    this.error,
  });

  final bool pushed;
  final bool pulled;
  final int books;
  final int bookmarks;
  final String? error;

  bool get ok => error == null;
  String get summary {
    if (error != null) return '同步失败：$error';
    final parts = <String>[];
    if (pushed) parts.add('已推送');
    if (books > 0) parts.add('拉回 $books 本进度');
    if (bookmarks > 0) parts.add('$bookmarks 条书签');
    return parts.isEmpty ? '已是最新' : parts.join('，');
  }
}
