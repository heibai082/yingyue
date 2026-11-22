import 'package:flutter/foundation.dart';

import '../platform/import_foreground.dart';
import '../source/source_store.dart';
import 'book_store.dart';
import 'legado_import.dart';

/// 全局导入任务：进度不跟着页面走，退出页面后照常跑，重新进来还能看到。
class ImportTaskController extends ChangeNotifier {
  ImportTaskController._();

  static final ImportTaskController instance = ImportTaskController._();

  bool running = false;
  int done = 0;
  int total = 0;
  int ok = 0;
  int fail = 0;
  String current = '';
  String? error;
  LegadoImportResult? result;
  final Set<String> failedTitles = <String>{};
  DateTime? startedAt;

  bool get isBusy => running;

  Future<void> start({
    required String path,
    required BookStore shelf,
    required SourceStore sources,
    required Duration timeout,
    required int concurrency,
    Set<String>? onlyTitles,
  }) async {
    if (running) return;

    running = true;
    done = 0;
    total = 0;
    ok = 0;
    fail = 0;
    current = '';
    error = null;
    result = null;
    failedTitles.clear();
    startedAt = DateTime.now();
    notifyListeners();

    // 先把服务拉起来（Android 14 要 serviceTypes，失败也不影响导入本身）
    await ImportForeground.start('准备中…');

    final read = await LegadoImporter.readBackupFile(path);
    if (read.error != null) {
      running = false;
      error = read.error;
      notifyListeners();
      await ImportForeground.stop();
      return;
    }

    var books = read.books;
    if (onlyTitles != null && onlyTitles.isNotEmpty) {
      final picked = books.where((b) => onlyTitles.contains(b.name)).toList();
      if (picked.isNotEmpty) books = picked;
    }
    total = books.length;
    notifyListeners();

    try {
      result = await LegadoImporter().importBooks(
        books: books,
        shelf: shelf,
        sources: sources,
        bookTimeout: timeout,
        concurrency: concurrency,
        onCurrent: (title) {
          current = title;
          notifyListeners();
          ImportForeground.update('正在处理：$title');
        },
        onBookDone: (title, good) {
          if (good) {
            ok++;
          } else {
            fail++;
            failedTitles.add(title);
          }
          notifyListeners();
          ImportForeground.update('已处理 $done / $total　✅ $ok　❌ $fail');
        },
        onProgress: (d, t, title) {
          done = d;
          total = t;
          current = title;
          notifyListeners();
        },
      );
    } catch (e) {
      error = e.toString();
    } finally {
      running = false;
      current = '';
      notifyListeners();
      await ImportForeground.stop();
    }
  }

  void reset() {
    if (running) return;
    done = 0;
    total = 0;
    ok = 0;
    fail = 0;
    current = '';
    error = null;
    result = null;
    notifyListeners();
  }
}
