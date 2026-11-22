// 书源体检：批量测活 + 连续失败自动删除。
//
// 为什么单独抽一层：检测逻辑（并发 / 累计失败 / 自动删除 / 撤销）要能脱离
// 网络与界面单独测；页面只负责把它跑起来、把进度写到通知栏。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'source_store.dart';

/// 单次检测的结果（由调用方注入的 [SourceChecker] 产出）。
class SourceCheckOutcome {
  const SourceCheckOutcome({required this.ok, this.error, this.elapsedMs = 0});

  final bool ok;
  final String? error;
  final int elapsedMs;
}

/// 检测一个书源是否还能用。
typedef SourceChecker =
    Future<SourceCheckOutcome> Function(BookSource source, String keyword);

/// 本次体检里某个源的结局。
enum SourceVerdict {
  /// 通过（失败计数清零）。
  ok,

  /// 失败但还没到删除门槛。
  failed,

  /// 连续失败达到门槛，已自动删除。
  removed,
}

/// 一个源的体检记录（给列表展示）。
class SourceHealthEntry {
  const SourceHealthEntry({
    required this.source,
    required this.verdict,
    this.error,
    this.failCount = 0,
    this.elapsedMs = 0,
  });

  final BookSource source;
  final SourceVerdict verdict;
  final String? error;

  /// 累计连续失败次数（删除后仍是删除前的值）。
  final int failCount;

  final int elapsedMs;
}

/// 体检控制器（可监听，页面与通知栏都靠它刷新）。
class SourceHealthController extends ChangeNotifier {
  SourceHealthController({
    required this.store,
    required this.checker,
    this.concurrency = 6,
    this.autoRemoveAfter = 2,
    this.autoRemove = true,
    this.shouldPause,
    this.maxChecksPerRun = 0,
    this.onProgress,
  });

  final SourceStore store;
  final SourceChecker checker;

  /// 同时检测几个源（开跑前可改）。
  int concurrency;

  /// 连续失败几次就删（默认 2）。
  final int autoRemoveAfter;

  /// 是否自动删除（页面上的开关）。
  bool autoRemove;

  /// 返回 true 时暂停领新任务（阅读中让路用）。
  final bool Function()? shouldPause;

  /// 单轮最多检多少个（0 = 全量；按「最久没检过」顺序轮转）。
  final int maxChecksPerRun;

  /// 每检完一个源回调一次（页面用它刷通知栏）。
  final void Function(SourceHealthController c)? onProgress;

  /// 本次体检的明细（按完成顺序）。
  final List<SourceHealthEntry> entries = [];

  /// 本次被自动删掉的书源（用于「撤销删除」）。
  final List<BookSource> removedSources = [];

  bool running = false;
  bool _cancelRequested = false;
  int total = 0;
  String keyword = '';
  DateTime? startedAt;

  int get checkedCount => entries.length;

  int get okCount =>
      entries.where((e) => e.verdict == SourceVerdict.ok).length;

  int get failedCount =>
      entries.where((e) => e.verdict == SourceVerdict.failed).length;

  int get removedCount => removedSources.length;

  bool get cancelled => _cancelRequested;

  /// 因为「正在看书」而临时停手（不进新任务，已发出的请求等它自然结束）。
  bool paused = false;

  /// 通知栏 / 标题栏的一行进度文案。
  String get progressText {
    final parts = <String>[
      if (paused) '已暂停（正在看书）',
      '已检 $checkedCount/$total',
      '正常 $okCount',
      '失败 $failedCount',
    ];
    if (removedCount > 0) parts.add('已删 $removedCount');
    return parts.join(' · ');
  }

  /// 跑一轮体检；[keyword] 是测试用的书名/作者。
  Future<void> run(String keyword) async {
    if (running) return;
    this.keyword = keyword.trim();
    entries.clear();
    removedSources.clear();
    _cancelRequested = false;
    paused = false;
    startedAt = DateTime.now();
    final targets = _planTargets();
    total = targets.length;
    running = true;
    notifyListeners();
    onProgress?.call(this);

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_cancelRequested) return;
        await _yieldWhileReading();
        if (_cancelRequested) return;
        final i = next++;
        if (i >= total) return;
        final source = targets[i];
        var outcome = const SourceCheckOutcome(ok: false, error: '未检测');
        try {
          outcome = await checker(source, this.keyword);
        } catch (e) {
          outcome = SourceCheckOutcome(ok: false, error: e.toString());
        }
        if (_cancelRequested) return;

        final fails = store.noteHealth(
          source.bookSourceUrl,
          ok: outcome.ok,
          error: outcome.error,
        );
        var verdict = outcome.ok ? SourceVerdict.ok : SourceVerdict.failed;
        if (!outcome.ok && autoRemove && fails >= autoRemoveAfter) {
          store.remove(source.bookSourceUrl);
          removedSources.add(source);
          verdict = SourceVerdict.removed;
        }
        entries.add(
          SourceHealthEntry(
            source: source,
            verdict: verdict,
            error: outcome.error,
            failCount: fails,
            elapsedMs: outcome.elapsedMs,
          ),
        );
        notifyListeners();
        onProgress?.call(this);
      }
    }

    final workers = concurrency.clamp(1, targets.isEmpty ? 1 : targets.length);
    await Future.wait(List.generate(workers, (_) => worker()));
    running = false;
    paused = false;
    notifyListeners();
    onProgress?.call(this);
  }

  /// 挑这一轮要检的源。
  ///
  /// - 优先捡「最久没体检过」的（`healthCheckedAt` 升序），这样限制了单轮数量
  ///   也能保证所有源轮流被查到；
  /// - [maxChecksPerRun] > 0 时只取前 N 个（默认全量）。
  List<BookSource> _planTargets() {
    final list = store.enabled.toList()
      ..sort((a, b) => a.healthCheckedAt.compareTo(b.healthCheckedAt));
    if (maxChecksPerRun > 0 && list.length > maxChecksPerRun) {
      return list.sublist(0, maxChecksPerRun);
    }
    return list;
  }

  /// 阅读中就让路：不打网络、不占 CPU，等退出阅读页再继续。
  Future<void> _yieldWhileReading() async {
    final pause = shouldPause;
    if (pause == null) return;
    if (!pause()) {
      if (paused) {
        paused = false;
        notifyListeners();
        onProgress?.call(this);
      }
      return;
    }
    if (!paused) {
      paused = true;
      notifyListeners();
      onProgress?.call(this);
    }
    while (pause() && !_cancelRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    paused = false;
    notifyListeners();
    onProgress?.call(this);
  }

  /// 请求停止（正在跑的请求会自然结束，不再领新活）。
  void cancel() {
    if (!running) return;
    _cancelRequested = true;
    notifyListeners();
  }

  /// 撤销本次的自动删除，返回恢复数量。
  int undoRemovals() {
    if (removedSources.isEmpty) return 0;
    final restore = removedSources
        .map((s) => s.copyWith(healthFailCount: 0, clearHealthError: true))
        .toList();
    final n = restore.length;
    removedSources.clear();
    // 走 restoreSources：顺便清掉「今天删过」的标记，否则撤销了也会被同步跳过
    store.restoreSources(restore);
    // 列表里对应的条目改回「失败」，别显示成已删
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.verdict == SourceVerdict.removed) {
        entries[i] = SourceHealthEntry(
          source: e.source,
          verdict: SourceVerdict.failed,
          error: e.error,
          failCount: 0,
          elapsedMs: e.elapsedMs,
        );
      }
    }
    notifyListeners();
    return n;
  }
}
