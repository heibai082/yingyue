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
///
/// 支持配置多个地址（例如「外网域名 + 家里内网 IP」）：每次同步先探测哪个能连，
/// 连上就用哪个；中途断线自动换下一个。这样一个 App 在家/在外都不用改设置。
class SyncClient {
  SyncClient({
    String? baseUrl,
    List<String>? baseUrls,
    required this.token,
    http.Client? client,
  }) : _bases = _normalize([if (baseUrl != null) baseUrl, ...?baseUrls]),
       _client = client ?? http.Client();

  final List<String> _bases;
  final String token;
  final http.Client _client;
  String? _active;

  static List<String> _normalize(Iterable<String> urls) {
    final out = <String>[];
    for (final u in urls) {
      final s = u.trim().replaceAll(RegExp(r'/+$'), '');
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  bool get configured => _bases.isNotEmpty;

  /// 当前用哪个地址（没探测过时给第一个）。
  String get activeBase => _active ?? (_bases.isEmpty ? '' : _bases.first);

  List<String> get bases => List.unmodifiable(_bases);

  Uri _u(String base, String path) => Uri.parse('$base$path');

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json; charset=utf-8',
  };

  /// 探测能用的地址（/api/health 不需要令牌）。
  Future<String?> _probe() async {
    for (final base in _bases) {
      try {
        final r = await _client
            .get(_u(base, '/api/health'))
            .timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) return base;
      } catch (_) {
        // 试下一个
      }
    }
    return null;
  }

  Future<bool> ping() async {
    _active = await _probe();
    return _active != null;
  }

  /// 依次尝试：当前地址优先，然后其它；都失败抛最后一个错。
  Future<T> _withFallback<T>(Future<T> Function(String base) run) async {
    final order = <String>[
      if (_active != null && _bases.contains(_active)) _active!,
      ..._bases.where((b) => b != _active),
    ];
    if (order.isEmpty) throw StateError('还没配置同步地址');
    Object? last;
    for (final base in order) {
      try {
        final r = await run(base);
        _active = base;
        return r;
      } catch (e) {
        last = e;
        _active = null;
      }
    }
    throw StateError('所有同步地址都连不上（$last）');
  }

  Future<Map<String, dynamic>> fetchState() => _withFallback((base) async {
    final r = await _client
        .get(_u(base, '/api/state'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw StateError('拉取失败（HTTP ${r.statusCode}）');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  });

  Future<void> pushState(Map<String, dynamic> payload) =>
      _withFallback((base) async {
        final r = await _client
            .post(
              _u(base, '/api/state'),
              headers: _headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 12));
        if (r.statusCode != 200) {
          throw StateError('推送失败（HTTP ${r.statusCode}）');
        }
      });

  /// 上传备份 zip（服务端自动保留最近 N 份）。
  Future<String?> uploadBackup(List<int> zipBytes) =>
      _withFallback((base) async {
        final r = await _client
            .post(
              _u(base, '/api/backups'),
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
      });

  /// 上传书源规则（只传规则，不传正文）。
  Future<int> uploadSources(List<Map<String, dynamic>> sources) =>
      _withFallback((base) async {
        final r = await _client
            .post(
              _u(base, '/api/sources'),
              headers: _headers,
              body: jsonEncode({'items': sources}),
            )
            .timeout(const Duration(seconds: 60));
        if (r.statusCode != 200) {
          throw StateError('上传书源失败（HTTP ${r.statusCode}）');
        }
        final data = jsonDecode(utf8.decode(r.bodyBytes));
        return data is Map
            ? (data['count'] as num?)?.toInt() ?? sources.length
            : sources.length;
      });

  /// 拉服务器上的书源（新设备第一次用）。
  Future<List<Map<String, dynamic>>> fetchSources() =>
      _withFallback((base) async {
        final r = await _client
            .get(_u(base, '/api/sources'), headers: _headers)
            .timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) {
          throw StateError('拉取书源失败（HTTP ${r.statusCode}）');
        }
        final data = jsonDecode(utf8.decode(r.bodyBytes));
        final raw = data is Map ? data['items'] : data;
        if (raw is! List) return <Map<String, dynamic>>[];
        return [
          for (final item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ];
      });

  /// 服务器上每本书已有哪几章：{path: {index...}}。
  Future<Map<String, Set<int>>> fetchChapterIndex() =>
      _withFallback((base) async {
        final r = await _client
            .get(_u(base, '/api/chapters/index'), headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          throw StateError('读取章节索引失败（HTTP ${r.statusCode}）');
        }
        final data = jsonDecode(utf8.decode(r.bodyBytes));
        final raw = data is Map ? data['items'] : null;
        final out = <String, Set<int>>{};
        if (raw is Map) {
          raw.forEach((k, v) {
            if (v is List) {
              out['$k'] = {
                for (final x in v)
                  if (x is num) x.toInt(),
              };
            }
          });
        }
        return out;
      });

  /// 上传一章：正文（小说）或图片地址（漫画，服务端会自己下载图片）。
  Future<void> uploadChapter(Map<String, dynamic> payload) =>
      _withFallback((base) async {
        final r = await _client
            .post(
              _u(base, '/api/chapters'),
              headers: _headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 90));
        if (r.statusCode != 200) {
          throw StateError('上传章节失败（HTTP ${r.statusCode}）');
        }
      });
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
