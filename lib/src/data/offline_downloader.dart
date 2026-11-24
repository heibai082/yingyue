// 在线书籍「离线缓存」：把整本（或一段章节）提前抓下来存本地。
//
// 用户反馈：「不支持离线缓存」——原先只有「读到哪缓存到哪」（翻页时顺手
// 存一章），没法提前把书下好，地铁 / 飞机上就断粮。这里提供批量预下载。
//
// 0.41 起支持「按计划下」：下哪些章、什么顺序由 cache_plan.dart 决定
// （全部 / 从当前章到最新 / 一段区间），这里只负责按序抓取 + 落盘 + 报进度。
//
// 设计要点：
//   - 并发受控（默认 4）：书源站点对并发敏感，太多会被限流 / 封；
//   - 逐章落盘（复用 OnlineBookContent 的缓存文件名），**随时中断不白干**；
//   - 已缓存的章节直接跳过（可续传，重跑只补缺的）；
//   - 失败不中断整轮：记录失败章节，最后汇总（部分成功也是成功）。
import 'dart:async';

import 'book_source.dart';
import 'comic_image_cache.dart';
import 'book_store.dart';
import 'models.dart';

/// 下载进度快照（供 UI 显示）。
class OfflineDownloadProgress {
  const OfflineDownloadProgress({
    required this.done,
    required this.total,
    required this.failed,
    required this.currentChapter,
    required this.finished,
    required this.cancelled,
    this.cachedBefore = 0,
    this.newChapters = 0,
    this.failureReasons = const {},
  });

  /// 已完成（含跳过 + 成功）。
  final int done;

  /// 计划下载的总章节数。
  final int total;

  /// 失败章节数。
  final int failed;

  /// 当前正在抓的章节序号（从 0 开始）。
  final int currentChapter;

  /// 是否已全部结束。
  final bool finished;

  /// 是否被用户取消。
  final bool cancelled;

  /// 本次计划范围内「开跑前就已经缓存好」的章数（进度文案用）。
  final int cachedBefore;

  /// 本次追更新追加的章节数（0 = 只是补缓存，没有新章）。
  final int newChapters;

  /// 失败原因 → 章数（给用户看「为什么缺」）。
  final Map<String, int> failureReasons;

  double get fraction => total <= 0
      ? (finished ? 1 : 0)
      : ((done + failed) / total).clamp(0.0, 1.0);
}

/// 离线缓存下载器。
///
/// 一次只允许一个任务（同一实例内）；UI 持有一个实例即可。
class OfflineDownloader {
  OfflineDownloader({
    this.concurrency = 4,
    BookContent Function(Book, BookStore)? contentFactory,
  }) : _contentFactory =
           contentFactory ??
           ((book, store) =>
               createBookContent(book, store, requireCacheWrite: true)) {
    if (concurrency < 1) {
      throw RangeError.range(concurrency, 1, null, 'concurrency');
    }
  }

  final BookContent Function(Book, BookStore) _contentFactory;

  /// 并发抓取数（站点限流友好）。
  final int concurrency;

  bool _cancelled = false;
  bool _running = false;

  bool get running => _running;

  /// 请求取消（正在进行的章节会跑完当前请求）。
  void cancel() {
    if (_running) _cancelled = true;
  }

  /// 下载 [book] 的 [from, to] 章节区间（含两端）。
  ///
  /// - [onProgress]：每完成一章回调一次（UI 刷新进度条）；
  /// - 返回最终进度（含失败数与取消标记）。
  Future<OfflineDownloadProgress> download(
    Book book,
    BookStore store, {
    int from = 0,
    int? to,
    void Function(OfflineDownloadProgress)? onProgress,
  }) async {
    if (_running) {
      throw StateError('已有下载任务在进行');
    }
    final total = book.chapters.length;
    final start = from.clamp(0, total);
    final end = total == 0 ? -1 : (to ?? total - 1).clamp(-1, total - 1);
    final indices = end < start
        ? const <int>[]
        : [for (var i = start; i <= end; i++) i];
    return downloadChapters(
      book,
      store,
      indices: indices,
      onProgress: onProgress,
    );
  }

  /// 按计划下载（0.41）：只抓 [indices] 里的章节，顺序就是优先级。
  ///
  /// 与 [download] 的区别：章节不必连续，也不用按序号顺序下——「从当前章到
  /// 最新」要先给用户看到新章，所以计划里新章排前面。
  Future<OfflineDownloadProgress> downloadChapters(
    Book book,
    BookStore store, {
    required List<int> indices,
    int cachedBefore = 0,
    int newChapters = 0,
    void Function(OfflineDownloadProgress)? onProgress,
  }) async {
    if (_running) {
      throw StateError('已有下载任务在进行');
    }
    _running = true;
    _cancelled = false;

    var done = 0;
    var failed = 0;
    var current = indices.isEmpty ? 0 : indices.first;
    final reasons = <String, int>{};
    final total = indices.length;
    var finished = false;

    OfflineDownloadProgress snapshot() => OfflineDownloadProgress(
      done: done,
      total: total,
      failed: failed,
      currentChapter: current,
      finished: finished,
      cancelled: _cancelled,
      cachedBefore: cachedBefore,
      newChapters: newChapters,
      failureReasons: Map.unmodifiable(reasons),
    );

    void report() => onProgress?.call(snapshot());
    void fail(String reason) {
      failed++;
      reasons[reason] = (reasons[reason] ?? 0) + 1;
    }

    BookContent? content;
    try {
      report();
      if (total > 0 && !_cancelled) {
        content = _contentFactory(book, store);
      }
      // 工作池：固定 concurrency 个 worker 按顺序抢 [indices] 里的下一章。
      // 用游标而不是 removeAt(0)，避免每章搬移剩余队列造成 O(n²)。
      var next = 0;
      Future<void> worker() async {
        while (true) {
          if (_cancelled) return;
          if (next >= indices.length) return;
          final index = indices[next++];
          current = index;
          try {
            final text = await content!.chapterText(index);
            if (text.trim().isEmpty) {
              // 空正文 = 没真的存下来，按失败算（否则「断网能读」是假的）
              fail('正文为空');
            } else {
              done++;
            }
          } on ComicChapterException catch (e) {
            // 漫画章节：正文抽不出来是正常的。真正的「缓存」= 图片字节落盘，
            // 只存 URL 清单的话下次进来还是要一张张联网（用户反馈的转圈）。
            if (e.images.isEmpty) {
              fail('这一话没取到图片');
            } else {
              final saved = await cacheComicImages(
                store,
                book.id,
                book.chapters[index].href ?? '',
                e.images,
              );
              if (saved > 0) {
                done++;
              } else {
                fail('图片下载失败');
              }
            }
          } catch (e) {
            fail(_shortReason(e));
          }
          report();
        }
      }

      final workers = <Future<void>>[
        for (var i = 0; i < concurrency && i < total; i++) worker(),
      ];
      await Future.wait(workers);
    } finally {
      try {
        await content?.dispose();
      } finally {
        _running = false;
      }
    }

    finished = true;
    final result = snapshot();
    onProgress?.call(result);
    return result;
  }

  /// 把异常压成一句能显示在进度条下面的话（同一类失败会被合并计数）。
  static String _shortReason(Object e) {
    final s = e.toString();
    if (s.contains('书源缺失')) return '书源缺失';
    if (s.contains('缺少链接')) return '章节缺链接';
    if (s.contains('拦截') || s.contains('改版')) return '站点拦截';
    if (s.contains('Timeout') || s.contains('超时')) return '超时';
    if (s.contains('Socket') || s.contains('网络')) return '网络错误';
    return '抓取失败';
  }
}
