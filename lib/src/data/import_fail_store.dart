import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 一本「导入失败、待重新搜源」的书。
class ImportFailBook {
  const ImportFailBook({
    required this.title,
    this.author = '',
    this.reason = '',
  });

  final String title;
  final String author;
  final String reason;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'reason': reason,
  };

  static ImportFailBook fromJson(Map<String, dynamic> m) => ImportFailBook(
    title: (m['title'] ?? '').toString(),
    author: (m['author'] ?? '').toString(),
    reason: (m['reason'] ?? '').toString(),
  );
}

/// 失败清单：落盘到应用私有目录，书架和导入页共享同一份。
///
/// 单例 + ChangeNotifier：搜到书之后 `remove()` 一处，两个界面同时刷新。
class ImportFailStore extends ChangeNotifier {
  ImportFailStore._();

  static final ImportFailStore instance = ImportFailStore._();

  final List<ImportFailBook> items = <ImportFailBook>[];
  bool _loaded = false;
  Future<void>? _loading;

  Future<File> _file() async {
    final dirs = await NativeBridge.appDirs();
    return File('${dirs.files}/import_failed.json');
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
      final list = (data is Map ? data['items'] : data) as List?;
      if (list == null) return;
      items
        ..clear()
        ..addAll(
          list.map(
            (e) => ImportFailBook.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
      notifyListeners();
    } catch (_) {
      // 文件损坏就当空清单，不影响书架
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({'items': items.map((e) => e.toJson()).toList()}),
        flush: true,
      );
    } catch (_) {}
  }

  bool contains(String title) => items.any((e) => e.title == title);

  Future<void> add(String title, {String author = '', String reason = ''}) async {
    if (contains(title)) return;
    items.add(ImportFailBook(title: title, author: author, reason: reason));
    notifyListeners();
    await _save();
  }

  Future<void> remove(String title) async {
    final before = items.length;
    items.removeWhere((e) => e.title == title);
    if (items.length == before) return;
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    if (items.isEmpty) return;
    items.clear();
    notifyListeners();
    await _save();
  }
}
