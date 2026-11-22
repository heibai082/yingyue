// 「源仓库同步」的结果记录：这次到底新加了哪些书源。
//
// 为什么要落盘：同步是后台跑的（可能几分钟），结束时会话可能已经切走；
// 用户回头想核对「加了什么」，得能翻到。文件在 App files 目录下。
import 'dart:convert';
import 'dart:io';

import '../data/persistence.dart';
import '../platform/native_bridge.dart';

/// 一条新增书源记录。
class SourceSyncLogItem {
  const SourceSyncLogItem({
    required this.name,
    required this.url,
    required this.collection,
  });

  final String name;
  final String url;

  /// 来自哪个合集（标题）。
  final String collection;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'collection': collection,
  };

  factory SourceSyncLogItem.fromJson(Map<dynamic, dynamic> m) => SourceSyncLogItem(
    name: (m['name'] ?? '').toString(),
    url: (m['url'] ?? '').toString(),
    collection: (m['collection'] ?? '').toString(),
  );
}

/// 最近一次同步的汇总。
class SourceSyncLog {
  SourceSyncLog({
    this.at,
    this.items = const [],
    this.updated = 0,
    this.collections = 0,
    this.error,
  });

  /// 同步时间（null = 从没同步过）。
  final DateTime? at;

  /// 本次新增的书源（按合集顺序）。
  final List<SourceSyncLogItem> items;

  /// 被更新（同 URL 已存在）的数量。
  final int updated;

  /// 本次处理了几个合集。
  final int collections;

  final String? error;

  int get addedCount => items.length;

  bool get isEmpty => at == null || (items.isEmpty && updated == 0);

  /// 按合集分组（保持出现顺序）。
  Map<String, List<SourceSyncLogItem>> get byCollection {
    final out = <String, List<SourceSyncLogItem>>{};
    for (final it in items) {
      out.putIfAbsent(it.collection, () => []).add(it);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    if (at != null) 'at': at!.toIso8601String(),
    'items': items.map((e) => e.toJson()).toList(),
    'updated': updated,
    'collections': collections,
    if (error != null) 'error': error,
  };

  factory SourceSyncLog.fromJson(Map<dynamic, dynamic> m) => SourceSyncLog(
    at: DateTime.tryParse((m['at'] ?? '').toString()),
    items: [
      for (final e in (m['items'] as List? ?? const []))
        if (e is Map) SourceSyncLogItem.fromJson(e),
    ],
    updated: (m['updated'] as num?)?.toInt() ?? 0,
    collections: (m['collections'] as num?)?.toInt() ?? 0,
    error: m['error']?.toString(),
  );

  static Future<File?> file() async {
    try {
      final dirs = await NativeBridge.appDirs();
      return File('${dirs.files}/source_sync_log.json');
    } catch (_) {
      return null;
    }
  }

  static Future<SourceSyncLog> load() async {
    try {
      final f = await file();
      if (f == null || !await f.exists()) return SourceSyncLog();
      final data = jsonDecode(await f.readAsString());
      if (data is Map) return SourceSyncLog.fromJson(data);
    } catch (_) {}
    return SourceSyncLog();
  }

  Future<void> save() async {
    try {
      final f = await file();
      if (f == null) return;
      await f.parent.create(recursive: true);
      // 先写临时文件再改名，避免写到一半被杀留下坏 JSON
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }
}
