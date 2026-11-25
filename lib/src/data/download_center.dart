// 全局下载中心：所有「缓存 / 追更 / 批量」都排进同一个队列。
//
// 以前的问题：详情页自己 new 一个 OfflineDownloader，一次只能跑一本，
// 页面一关就看不到进度，多本书也没法排队。
//
// 这里统一成：
//   - 队列串行执行（同一时刻只下一本，章节内部仍并发 4，站点友好）；
//   - 每本书一个任务，可暂停 / 继续 / 取消 / 重试；
//   - 进度、失败原因都挂在任务上，下载中心页和详情页共用；
//   - 通知栏进度（前台服务）由 [onProgress] 回调接出去，不在这里耦合平台。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/book_store.dart';
import 'cache_plan.dart';
import 'models.dart';
import 'offline_downloader.dart';

/// 任务状态。
enum DownloadTaskStatus { queued, running, paused, done, failed }

/// 一次缓存任务的快照。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.bookId,
    required this.name,
    required this.indices,
    required this.cachedBefore,
    this.plan,
  });

  final String id;
  final String bookId;
  final String name;

  /// 排队时算好的待下章节（优先级顺序）。
  final List<int> indices;

  /// 排队时已经缓存好的章数（进度分母用）。
  final int cachedBefore;

  final BookCachePlan? plan;

  DownloadTaskStatus status = DownloadTaskStatus.queued;
  OfflineDownloadProgress? progress;
  String? error;

  /// 0~1：按「范围内已下好 / 范围内总数」算，和详情页进度条一致。
  double get fraction {
    final p = progress;
    final total = indices.length + cachedBefore;
    if (total <= 0) return status == DownloadTaskStatus.done ? 1 : 0;
    if (p == null) {
      return (cachedBefore / total).clamp(0.0, 1.0);
    }
    return ((p.done + p.failed + cachedBefore) / total).clamp(0.0, 1.0);
  }

  String get label => switch (status) {
    DownloadTaskStatus.queued => '排队中',
    DownloadTaskStatus.running =>
      progress == null
          ? '准备中'
          : '缓存中 ${progress!.done + progress!.failed}/${progress!.total}',
    DownloadTaskStatus.paused => '已暂停',
    DownloadTaskStatus.done => '已完成',
    DownloadTaskStatus.failed => '失败${error == null ? '' : '：$error'}',
  };

  bool get finished =>
      status == DownloadTaskStatus.done || status == DownloadTaskStatus.failed;
}

/// 下载中心（单例 + 可注入 store / downloader 方便测试）。
class DownloadCenter extends ChangeNotifier {
  DownloadCenter({OfflineDownloader? downloader})
    : _downloader = downloader ?? OfflineDownloader();

  static final DownloadCenter instance = DownloadCenter();

  final OfflineDownloader _downloader;
  final List<DownloadTask> _tasks = [];
  BookStore? _store;
  DownloadTask? _running;
  bool _pauseRequested = false;
  Timer? _throttle;

  /// 通知栏回调：任务开始 / 进度更新 / 全部结束。
  void Function(DownloadTask? task, double fraction)? onProgress;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get busy => _running != null;
  DownloadTask? get running => _running;
  int get queuedCount =>
      _tasks.where((t) => t.status == DownloadTaskStatus.queued).length;

  void bind(BookStore store) => _store = store;

  Future<DownloadTask> enqueue(
    Book book, {
    required List<int> indices,
    int cachedBefore = 0,
    BookCachePlan? plan,
  }) async {
    final task = DownloadTask(
      id: '${book.id}-${DateTime.now().microsecondsSinceEpoch}',
      bookId: book.id,
      name: book.title,
      indices: List<int>.of(indices),
      cachedBefore: cachedBefore,
      plan: plan ?? book.cachePlan,
    );
    _tasks.add(task);
    _notify();
    unawaited(_pump());
    return task;
  }

  /// 暂停当前任务（排队中的不受影响）。
  ///
  /// 注意「已开始但还没真正下载」的窗口（要等一次缓存扫描）：这时 downloader
  /// 还没在跑，cancel() 是空操作，所以额外记一个标记，真正开跑前就停住。
  void pauseCurrent() {
    _pauseRequested = true;
    _downloader.cancel();
  }

  /// 继续最后一个暂停的任务（重新排到队尾也行；这里保持原顺序）。
  void resumeTask(String id) {
    final t = _byId(id);
    if (t == null || t.status != DownloadTaskStatus.paused) return;
    t.status = DownloadTaskStatus.queued;
    t.progress = null;
    _notify();
    unawaited(_pump());
  }

  /// 重试失败的任务。
  void retry(String id) {
    final t = _byId(id);
    if (t == null || t.status != DownloadTaskStatus.failed) return;
    t.status = DownloadTaskStatus.queued;
    t.progress = null;
    t.error = null;
    _notify();
    unawaited(_pump());
  }

  /// 从队列里删掉（正在跑的先暂停）。
  void remove(String id) {
    final t = _byId(id);
    if (t == null) return;
    if (identical(t, _running)) _downloader.cancel();
    _tasks.remove(t);
    _notify();
  }

  /// 清掉已完成 / 失败的任务。
  void clearFinished() {
    _tasks.removeWhere((t) => t.finished);
    _notify();
  }

  DownloadTask? _byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_running != null) return;
    final store = _store;
    if (store == null) return;
    while (true) {
      DownloadTask? next;
      for (final t in _tasks) {
        if (t.status == DownloadTaskStatus.queued) {
          next = t;
          break;
        }
      }
      if (next == null) {
        onProgress?.call(null, 0);
        return;
      }
      final task = next;
      final book = store.byId(task.bookId);
      if (book == null) {
        task.status = DownloadTaskStatus.failed;
        task.error = '书已不在书架';
        _notify();
        continue;
      }
      _running = task;
      task.status = DownloadTaskStatus.running;
      _notify();
      onProgress?.call(task, task.fraction);
      if (_pauseRequested) {
        _pauseRequested = false;
        _running = null;
        task.status = DownloadTaskStatus.paused;
        _notify();
        continue;
      }
      try {
        // 重新扫一遍缓存：排队期间可能已经读过几章
        await store.refreshChapterCache(book.id);
        final plan = buildCachePlan(
          book,
          cached: book.chapterCache,
          plan: task.plan,
        );
        final indices = plan.indices.isEmpty ? task.indices : plan.indices;
        final cachedBefore = plan.indices.isEmpty
            ? task.cachedBefore
            : plan.cachedInRange;
        // 扫描期间点了暂停：这时还没开始下载，直接停在暂停态
        if (_pauseRequested) {
          _pauseRequested = false;
          task.status = DownloadTaskStatus.paused;
          continue;
        }
        final result = await _downloader.downloadChapters(
          book,
          store,
          indices: indices,
          cachedBefore: cachedBefore,
          onProgress: (p) {
            task.progress = p;
            onProgress?.call(task, task.fraction);
            _notifyThrottled();
          },
        );
        await store.refreshChapterCache(book.id);
        if (result.cancelled) {
          task.status = DownloadTaskStatus.paused;
        } else if (result.failed > 0 && result.done == 0) {
          task.status = DownloadTaskStatus.failed;
          task.error = result.failureReasons.isEmpty
              ? '全部章节下载失败'
              : result.failureReasons.keys.first;
        } else {
          task.status = DownloadTaskStatus.done;
        }
      } catch (e) {
        next.status = DownloadTaskStatus.failed;
        next.error = '$e';
      } finally {
        _running = null;
        _notify();
        onProgress?.call(task, task.fraction);
      }
    }
  }

  void _notifyThrottled() {
    _throttle?.cancel();
    _throttle = Timer(const Duration(milliseconds: 300), _notify);
  }

  void _notify() => notifyListeners();

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }
}
