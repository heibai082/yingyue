import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 一本「导入失败、待重新搜源」的书。
///
/// 除了书名/作者，还带着备份里的阅读位置（章节、章内偏移、最后阅读时间）：
/// 不然重新搜到之后只能从第 1 章开始，用户会觉得「以前的阅读记录全没了」。
class ImportFailBook {
  const ImportFailBook({
    required this.title,
    this.author = '',
    this.reason = '',
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.charOffset = 0,
    this.lastReadAt = 0,
  });

  final String title;
  final String author;
  final String reason;

  /// 备份里读到的章节序号（0 起）。
  final int chapterIndex;

  /// 备份里读到的章节名（给用户看的提示用）。
  final String chapterTitle;

  /// 章节内偏移（字符数）。
  final int charOffset;

  /// 最后阅读时间（毫秒，0 = 未知）。
  final int lastReadAt;

  bool get hasProgress => chapterIndex > 0 || charOffset > 0;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'reason': reason,
    if (chapterIndex > 0) 'chapterIndex': chapterIndex,
    if (chapterTitle.isNotEmpty) 'chapterTitle': chapterTitle,
    if (charOffset > 0) 'charOffset': charOffset,
    if (lastReadAt > 0) 'lastReadAt': lastReadAt,
  };

  static ImportFailBook fromJson(Map<String, dynamic> m) => ImportFailBook(
    title: (m['title'] ?? '').toString(),
    author: (m['author'] ?? '').toString(),
    reason: (m['reason'] ?? '').toString(),
    chapterIndex: (m['chapterIndex'] as num?)?.toInt() ?? 0,
    chapterTitle: (m['chapterTitle'] ?? '').toString(),
    charOffset: (m['charOffset'] as num?)?.toInt() ?? 0,
    lastReadAt: (m['lastReadAt'] as num?)?.toInt() ?? 0,
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

  /// 记一条待搜源；已存在时补齐阅读位置（备份里的进度不能丢）。
  Future<void> add(
    String title, {
    String author = '',
    String reason = '',
    int chapterIndex = 0,
    String chapterTitle = '',
    int charOffset = 0,
    int lastReadAt = 0,
  }) async {
    final i = items.indexWhere((e) => e.title == title);
    if (i >= 0) {
      final old = items[i];
      // 只补不覆盖：新信息更全时才更新
      if (chapterIndex > old.chapterIndex ||
          (charOffset > old.charOffset && chapterIndex == old.chapterIndex)) {
        items[i] = ImportFailBook(
          title: title,
          author: author.isEmpty ? old.author : author,
          reason: reason.isEmpty ? old.reason : reason,
          chapterIndex: chapterIndex > old.chapterIndex
              ? chapterIndex
              : old.chapterIndex,
          chapterTitle:
              chapterTitle.isEmpty ? old.chapterTitle : chapterTitle,
          charOffset: charOffset,
          lastReadAt: lastReadAt > 0 ? lastReadAt : old.lastReadAt,
        );
        notifyListeners();
        await _save();
      }
      return;
    }
    items.add(
      ImportFailBook(
        title: title,
        author: author,
        reason: reason,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        charOffset: charOffset,
        lastReadAt: lastReadAt,
      ),
    );
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
