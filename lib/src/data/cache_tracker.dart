// 追更 + 自动补缓存：让「全部」/「从当前章到最新」这两种范围真的自动跟进。
//
// 用户反馈：「从当前章节缓存到最新（并且开启自动追剧模式缓存）」——光有范围
// 选择还不够，站点更新之后得自动把新章补下来，不然第二天还是要手动点。
//
// 一次「追一轮」做三件事：
//   1. 抓站点目录，和本地目录比对，找出新章节（只认链接，防止重名误判）；
//   2. 按本书的缓存范围把「还没缓存的章」下下来（新章优先）；
//   3. 新章正文落盘成功后才并入本地目录——保证「目录里有的，断网也读得到」。
//
// 省流设计：
//   - 同一本书 30 分钟内不重复抓目录（[trackInterval]）；
//   - 用户正在看书（[kReaderActive]）时整轮让路，免得抢带宽 / 掉帧；
//   - 一次只跑一轮（[running]），UI 可以随时 [cancel]。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../source/chapter_order.dart';
import '../source/online_book_service.dart';
import '../source/source_store.dart';
import 'app_activity.dart';
import 'book_store.dart';
import 'download_center.dart';
import 'cache_plan.dart';
import 'models.dart';
import 'offline_downloader.dart';

/// 一轮追更的结果（给 UI / 日志用）。
class CacheTrackResult {
  const CacheTrackResult({
    required this.bookId,
    required this.name,
    this.added = 0,
    this.downloaded = 0,
    this.failed = 0,
    this.cachedBefore = 0,
    this.total = 0,
    this.skipped = false,
    this.reason,
  });

  final String bookId;
  final String name;

  /// 这次追到的新章节数。
  final int added;

  /// 这次真正下好的章数。
  final int downloaded;

  /// 失败章数。
  final int failed;

  /// 计划范围内的总章数。
  final int total;

  /// 范围里原本就已缓存的章数。
  final int cachedBefore;

  /// 是否整本跳过（不缓存 / 还没到追更时间 / 正在看书）。
  final bool skipped;

  /// 跳过 / 失败的原因（一句话）。
  final String? reason;

  bool get changed => added > 0 || downloaded > 0;

  String get summary {
    if (skipped) return reason ?? '跳过';
    final parts = <String>[];
    if (added > 0) parts.add('新 $added 章');
    if (downloaded > 0) parts.add('下好 $downloaded 章');
    if (failed > 0) parts.add('$failed 章失败');
    if (parts.isEmpty) return '已是最新';
    return parts.join('，');
  }
}

/// 抓目录的抽象（生产用 [OnlineBookService]，测试可注入假实现）。
typedef TocFetcher = Future<List<ChapterRef>> Function(
  BookSourceInfo source,
  String bookUrl,
);

/// 追更需要的最小书源信息（避免 tracking 层依赖整个 BookSource 类）。
class BookSourceInfo {
  const BookSourceInfo({required this.bookSourceUrl, this.isComic = false});

  final String bookSourceUrl;
  final bool isComic;
}

/// 不依赖屏幕的追更 / 补缓存服务。
///
/// 单个实例即可（App 里挂在 HomePage 上），同一时刻只跑一轮。
class CacheTracker {
  CacheTracker({
    required this.store,
    OfflineDownloader? downloader,
    TocFetcher? tocFetcher,
    this.trackInterval = const Duration(minutes: 30),
  }) : _downloader = downloader ?? OfflineDownloader(),
       _fetchToc = tocFetcher ?? _defaultTocFetcher();

  final BookStore store;
  final OfflineDownloader _downloader;
  final TocFetcher _fetchToc;

  /// 同一本书两次抓目录的最小间隔（省流量；手动「立即检查」不受限）。
  final Duration trackInterval;

  /// 当前这一轮的进度（null = 没在跑）。
  final ValueNotifier<OfflineDownloadProgress?> progress =
      ValueNotifier<OfflineDownloadProgress?>(null);

  /// 正在处理哪本书（进度文案用）。
  final ValueNotifier<String?> activeBook = ValueNotifier<String?>(null);

  /// 本轮已经处理过的书（结果列表，UI 可以拿来提示）。
  final ValueNotifier<List<CacheTrackResult>> lastResults =
      ValueNotifier<List<CacheTrackResult>>(const []);

  bool get running => _downloader.running;

  /// 正在跑的是哪本书（没有就是 null）。
  String? get activeBookId => activeBook.value;

  /// 按「这本书当前的缓存范围」补缓存（阅读页的缓存按钮用）。
  ///
  /// 与 [trackOne] 的区别：这里**不抓目录**（只是把计划范围内缺的章节下好），
  /// 有新章要追更走 [trackOne] / [trackAll]。
  Future<OfflineDownloadProgress?> downloadByPlan(
    String bookId, {
    void Function(OfflineDownloadProgress)? onProgress,
  }) async {
    final book = store.byId(bookId);
    if (book == null || book.format != BookFormat.online) return null;
    if (book.cachePlan.isOff) return null;
    if (running) throw StateError('已有下载任务在进行');
    await store.refreshChapterCache(bookId);
    final plan = buildCachePlan(book, cached: book.chapterCache);
    if (plan.isEmpty) return null;
    activeBook.value = book.title;
    try {
      final result = await _downloader.downloadChapters(
        book,
        store,
        indices: plan.indices,
        cachedBefore: plan.cachedInRange,
        onProgress: (p) {
          progress.value = p;
          onProgress?.call(p);
        },
      );
      await store.refreshChapterCache(bookId);
      return result;
    } finally {
      progress.value = null;
      activeBook.value = null;
    }
  }

  void cancel() => _downloader.cancel();

  /// 抓目录的默认实现：按书源地址找书源 → fetchInfo → 取章节。
  static TocFetcher _defaultTocFetcher() {
    final service = OnlineBookService();
    return (source, bookUrl) async {
      final stores = SourceStore.shared;
      final bs = stores?.byUrl(source.bookSourceUrl);
      if (bs == null) {
        throw StateError('书源缺失（${source.bookSourceUrl}）');
      }
      final info = await service.fetchInfo(bs, bookUrl);
      return info.chapters;
    };
  }

  /// 对书架里所有「开了自动追更」的在线书各追一轮。
  ///
  /// - [force]：true = 无视 [trackInterval]（用户点「立即检查」时用）；
  /// - 返回每本书的结果（跳过的也在里面，[CacheTrackResult.skipped] = true）。
  Future<List<CacheTrackResult>> trackAll({bool force = false}) async {
    if (running) return const [];
    final results = <CacheTrackResult>[];
    for (final book in List<Book>.of(store.books)) {
      if (book.format != BookFormat.online) continue;
      if (!book.cachePlan.autoTrack) continue;
      try {
        results.add(await trackOne(book.id, force: force));
      } catch (e) {
        results.add(
          CacheTrackResult(
            bookId: book.id,
            name: book.title,
            skipped: true,
            reason: '追更失败：${_short(e)}',
          ),
        );
      }
    }
    lastResults.value = List.unmodifiable(results);
    return results;
  }

  /// 追一本（可以单独点某本书的「检查更新」）。
  Future<CacheTrackResult> trackOne(String bookId, {bool force = false}) async {
    final book = store.byId(bookId);
    if (book == null || book.format != BookFormat.online) {
      return CacheTrackResult(
        bookId: bookId,
        name: book?.title ?? '',
        skipped: true,
        reason: '不是在线书',
      );
    }
    final plan = book.cachePlan;
    if (plan.isOff) {
      return CacheTrackResult(
        bookId: bookId,
        name: book.title,
        skipped: true,
        reason: '这本书关掉了自动缓存',
      );
    }
    if (running || DownloadCenter.instance.busy) {
      return CacheTrackResult(
        bookId: bookId,
        name: book.title,
        skipped: true,
        reason: '已有缓存任务在进行',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        book.lastTrackedAt > 0 &&
        now - book.lastTrackedAt < trackInterval.inMilliseconds) {
      return CacheTrackResult(
        bookId: bookId,
        name: book.title,
        skipped: true,
        reason: '刚查过目录（${trackInterval.inMinutes} 分钟内不重复）',
      );
    }
    // 用户正在看书：让路，下一轮再来
    if (kReaderActive.value) {
      return CacheTrackResult(
        bookId: bookId,
        name: book.title,
        skipped: true,
        reason: '正在阅读，稍后再追',
      );
    }

    final sourceUrl = book.sourceUrl;
    if (sourceUrl == null || sourceUrl.trim().isEmpty) {
      return CacheTrackResult(
        bookId: bookId,
        name: book.title,
        skipped: true,
        reason: '这本书没有书源信息',
      );
    }

    // 1) 抓目录，找新章
    var added = 0;
    try {
      final fresh = await _fetchToc(
        BookSourceInfo(bookSourceUrl: sourceUrl),
        book.path,
      );
      store.markTracked(bookId);
      if (fresh.isNotEmpty) {
        final news = newChaptersOf(book.chapters, fresh);
        if (news.isNotEmpty) {
          book.discoveredChapters = news;
          added = news.length;
        }
      }
    } catch (e) {
      // 目录抓不到不算致命：至少把「按计划还缺的章」补上
      debugPrint('[cache_tracker] 《${book.title}》目录抓取失败：$e');
    }

    // 2) 扫已有缓存 → 3) 按范围算计划
    //
    // 顺序很关键：**先下、再并入目录**。新章正文还没落地就把目录写进书架的话，
    // 用户断网点进去会报「抓不到正文」；反过来，下好了再合并，目录里有的就一定
    // 读得到（这也是「断网也能读」的承诺）。
    await store.refreshChapterCache(bookId);
    final newestFirst = book.chapters.length >= 2
        ? looksNewestFirst(book.chapters)
        : looksNewestFirst(book.discoveredChapters);
    final mergedChapters = appendNewChapters(
      book.chapters,
      book.discoveredChapters,
      newestFirst: newestFirst,
    );
    // 下载用的「合并目录视图」：同一个 bookId（缓存目录不变），只是章节多了新章
    final view = Book(
      id: book.id,
      title: book.title,
      author: book.author,
      format: book.format,
      path: book.path,
      sourceUrl: book.sourceUrl,
      chapters: mergedChapters,
      chapterIndex: book.chapterIndex,
      cachePlan: plan,
    )..chapterCache = {...book.chapterCache};

    final computed = buildCachePlan(
      view,
      cached: view.chapterCache,
      anchor: book.safeChapterIndex,
    );
    OfflineDownloadProgress? result;
    if (!computed.isEmpty) {
      activeBook.value = book.title;
      try {
        result = await _downloader.downloadChapters(
          view,
          store,
          indices: computed.indices,
          cachedBefore: computed.cachedInRange,
          newChapters: added,
          onProgress: (p) => progress.value = p,
        );
      } finally {
        progress.value = null;
        activeBook.value = null;
      }
    }

    // 5) 收尾：新章并入正式目录、刷新缓存快照
    store.applyChapterUpdates(bookId);
    await store.refreshChapterCache(bookId);
    return CacheTrackResult(
      bookId: bookId,
      name: book.title,
      added: added,
      downloaded: result?.done ?? 0,
      failed: result?.failed ?? 0,
      total: computed.total,
      cachedBefore: computed.cachedInRange,
      skipped: added == 0 && (result == null || result.done == 0),
      reason: added == 0 && (result?.done ?? 0) == 0 ? '已是最新' : null,
    );
  }

  void dispose() {
    progress.dispose();
    activeBook.dispose();
    lastResults.dispose();
  }

  static String _short(Object e) {
    final s = e.toString();
    if (s.length <= 60) return s;
    return '${s.substring(0, 60)}…';
  }
}
