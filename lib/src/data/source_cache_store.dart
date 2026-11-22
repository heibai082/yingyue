import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 一条缓存的换源候选。
class CachedCandidate {
  const CachedCandidate({
    required this.sourceUrl,
    required this.name,
    required this.author,
    required this.bookUrl,
    this.coverUrl = '',
    this.score = 0,
  });

  final String sourceUrl;
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final int score;

  Map<String, dynamic> toJson() => {
    'sourceUrl': sourceUrl,
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
    'coverUrl': coverUrl,
    'score': score,
  };

  static CachedCandidate fromJson(Map<String, dynamic> m) => CachedCandidate(
    sourceUrl: (m['sourceUrl'] ?? '').toString(),
    name: (m['name'] ?? '').toString(),
    author: (m['author'] ?? '').toString(),
    bookUrl: (m['bookUrl'] ?? '').toString(),
    coverUrl: (m['coverUrl'] ?? '').toString(),
    score: (m['score'] as num?)?.toInt() ?? 0,
  );
}

/// 换源结果缓存：没点「刷新」之前，一直用上次搜到的结果。
class SourceCacheStore {
  SourceCacheStore._();

  static final SourceCacheStore instance = SourceCacheStore._();

  final Map<String, List<CachedCandidate>> _cache = {};
  bool _loaded = false;
  Future<void>? _loading;

  Future<File> _file() async {
    final dirs = await NativeBridge.appDirs();
    return File('${dirs.files}/source_cache.json');
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loading ??= _load();
    await _loading;
    _loaded = true;
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return;
      _cache.clear();
      data.forEach((k, v) {
        if (v is List) {
          _cache[k.toString()] = v
              .whereType<Map>()
              .map((e) => CachedCandidate.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      final data = _cache.map(
        (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList()),
      );
      await f.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  List<CachedCandidate>? get(String key) {
    final v = _cache[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> put(String key, List<CachedCandidate> list) async {
    if (list.isEmpty) return;
    _cache[key] = list;
    await _save();
  }

  Future<void> remove(String key) async {
    if (_cache.remove(key) == null) return;
    await _save();
  }
}
