import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 「书源标记」：记住哪些源不好用，下次换源时提醒。
///
/// key 是 bookSourceUrl，value 是用户写的备注（空字符串表示标记过但没写原因）。
class SourceMarkStore extends ChangeNotifier {
  SourceMarkStore._();

  static final SourceMarkStore instance = SourceMarkStore._();

  final Map<String, String> marks = <String, String>{};
  bool _loaded = false;
  Future<void>? _loading;

  Future<File> _file() async {
    final dirs = await NativeBridge.appDirs();
    return File('${dirs.files}/source_marks.json');
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
      if (data is Map) {
        marks
          ..clear()
          ..addAll(data.map((k, v) => MapEntry(k.toString(), v.toString())));
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(marks), flush: true);
    } catch (_) {}
  }

  bool isMarked(String sourceUrl) => marks.containsKey(sourceUrl);

  String noteOf(String sourceUrl) => marks[sourceUrl] ?? '';

  Future<void> mark(String sourceUrl, String note) async {
    if (sourceUrl.trim().isEmpty) return;
    marks[sourceUrl] = note.trim();
    notifyListeners();
    await _save();
  }

  Future<void> unmark(String sourceUrl) async {
    if (marks.remove(sourceUrl) == null) return;
    notifyListeners();
    await _save();
  }
}
