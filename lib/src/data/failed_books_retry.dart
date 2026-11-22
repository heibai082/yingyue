// 「待搜源 → 全部重搜」的后台任务。
//
// 为什么要抽成常驻控制器：
//   - 154 本书 × 每本几秒到几十秒，必须能在切页面 / 切 App 后继续跑；
//   - 通知栏要能看进度（借前台服务）；
//   - 看书时让路，别跟阅读抢网络。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/import_foreground.dart';
import '../source/source_store.dart';
import 'app_activity.dart';
import 'book_store.dart';
import 'import_fail_store.dart';
import 'import_research.dart';

/// 单本重搜的实现（测试可注入假实现）。
///
/// 传整条 [ImportFailBook]，因为里面还带着备份里的阅读位置。
typedef ResearchFn = Future<ResearchResult> Function(ImportFailBook book);

/// 全局单例：同一时间只跑一个重搜任务。
class FailedBooksRetryController extends ChangeNotifier {
  FailedBooksRetryController({ResearchFn? research}) : _research = research;

  static final FailedBooksRetryController instance =
      FailedBooksRetryController();

  ResearchFn? _research;
  BookStore? _shelf;
  SourceStore? _sources;

  bool running = false;
  bool _cancelled = false;
  bool paused = false;

  String? currentTitle;
  int done = 0;
  int total = 0;
  int okCount = 0;
  int failCount = 0;
  String? lastMessage;

  /// 通知栏 / 面板上的一行进度。
  String get progressText {
    final parts = <String>[
      if (paused) '已暂停（正在看书）',
      '已处理 $done/$total',
      '成功 $okCount',
      if (failCount > 0) '失败 $failCount',
    ];
    return parts.join(' · ');
  }

  /// 开始把「待搜源」里的书全部重搜一遍。
  ///
  /// [shelf] / [sources] 用来走默认实现；测试里可以直接给 [research]。
  Future<void> startAll({
    BookStore? shelf,
    SourceStore? sources,
    ResearchFn? research,
  }) async {
    if (running) return;
    final items = List.of(ImportFailStore.instance.items);
    if (items.isEmpty) return;

    _shelf = shelf;
    _sources = sources;
    if (research != null) _research = research;

    running = true;
    _cancelled = false;
    paused = false;
    done = 0;
    okCount = 0;
    failCount = 0;
    total = items.length;
    currentTitle = null;
    lastMessage = null;
    notifyListeners();

    await ImportForeground.startTask(
      title: '嘤阅 · 正在重搜待搜源',
      text: '准备中… 共 $total 本',
    );

    for (final it in items) {
      if (_cancelled) break;
      await _waitWhileReading();
      if (_cancelled) break;
      currentTitle = it.title;
      notifyListeners();
      _tell('第 ${done + 1}/$total 本：《${it.title}》');

      ResearchResult r;
      try {
        r = await _researchFor(it);
      } catch (e) {
        r = ResearchResult(ok: false, message: '$e');
      }
      done++;
      if (r.ok) {
        okCount++;
      } else {
        failCount++;
      }
      lastMessage = r.message;
      notifyListeners();
      _tell(progressText);
    }

    running = false;
    currentTitle = null;
    paused = false;
    notifyListeners();
    unawaited(ImportForeground.stop());
  }

  /// 请求停止（正在搜的那本会自然结束）。
  void cancel() {
    if (!running) return;
    _cancelled = true;
    notifyListeners();
  }

  Future<ResearchResult> _researchFor(ImportFailBook book) {
    final fn = _research;
    if (fn != null) return fn(book);
    final shelf = _shelf;
    final sources = _sources;
    if (shelf == null || sources == null) {
      return Future.value(
        const ResearchResult(ok: false, message: '重搜任务没有书源上下文'),
      );
    }
    return researchBook(
      title: book.title,
      author: book.author,
      chapterIndex: book.chapterIndex,
      charOffset: book.charOffset,
      lastReadAt: book.lastReadAt,
      shelf: shelf,
      sources: sources,
    );
  }

  void _tell(String text) {
    unawaited(
      ImportForeground.updateTask(title: '嘤阅 · 正在重搜待搜源', text: text),
    );
  }

  /// 阅读中就让路：不占网、不占 CPU。
  Future<void> _waitWhileReading() async {
    if (!kReaderActive.value) {
      if (paused) {
        paused = false;
        notifyListeners();
      }
      return;
    }
    paused = true;
    notifyListeners();
    _tell('已暂停（正在看书）');
    while (kReaderActive.value && !_cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    paused = false;
    notifyListeners();
  }
}
