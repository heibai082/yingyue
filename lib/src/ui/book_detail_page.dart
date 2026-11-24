import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/book_store.dart';
import '../data/cache_plan.dart';
import '../data/cache_tracker.dart';
import '../data/models.dart';
import '../data/offline_downloader.dart';
import '../data/prefs.dart';
import '../platform/native_bridge.dart';
import '../platform/share_service.dart';
import '../source/source_store.dart';
import '../theme/app_theme.dart';
import '../util/book_share.dart';
import 'reader/reader_page.dart';
import 'cache_settings_sheet.dart';
import 'folder_picker_page.dart';
import 'source/source_switch_sheet.dart';
import 'widgets/book_cover.dart';
import 'widgets/cute.dart';

/// 书籍详情页：封面 / 信息 / 简介 / 目录 / 离线缓存。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    super.key,
    required this.store,
    required this.prefs,
    required this.bookId,
  });

  final BookStore store;
  final AppPrefs prefs;
  final String bookId;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  /// 离线下载器（一次一个任务）。
  final OfflineDownloader _downloader = OfflineDownloader();

  /// 追更 / 检查新章（同一时刻只跑一轮）。
  late final CacheTracker _tracker = CacheTracker(store: widget.store);

  /// 当前下载进度（null = 没在下载）。
  OfflineDownloadProgress? _progress;

  /// 正在追更检查（抓目录那几秒）。
  bool _checking = false;

  /// 已缓存章节数（进度展示用）。
  int? _cachedCount;

  BookStore get store => widget.store;

  Book? get _book => store.byId(widget.bookId);

  @override
  void initState() {
    super.initState();
    _refreshCachedCount();
  }

  @override
  void dispose() {
    _tracker.dispose();
    super.dispose();
  }

  /// 扫一遍缓存目录 + 刷新展示数字。
  ///
  /// 以前只统计「有几个文件」，没法回答「缓存的是哪几章」。现在把序号也记到
  /// Book 上，按范围算计划时就能跳过已缓存的章节。
  Future<void> _refreshCachedCount() async {
    final set = await store.refreshChapterCache(widget.bookId);
    if (mounted) setState(() => _cachedCount = set.length);
  }

  /// 按本书的「缓存范围」下载（详情页的「缓存」入口）。
  Future<void> _downloadByPlan() async {
    final book = _book;
    if (book == null) return;
    if (_downloader.running) return;
    final messenger = ScaffoldMessenger.of(context);
    // 只在 Wi-Fi 下缓存：移动网络时先问一句，别偷偷跑流量
    if (widget.prefs.wifiOnlyDownloads && !await NativeBridge.isOnWifi()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('已开启「只在 Wi-Fi 下缓存」，连上 Wi-Fi 再试')),
      );
      return;
    }

    await _refreshCachedCount();
    if (!mounted) return;
    final plan = buildCachePlan(book, cached: book.chapterCache);
    if (plan.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('当前范围内的章节都缓存好啦 🎀')));
      return;
    }

    setState(() {
      _progress = OfflineDownloadProgress(
        done: 0,
        total: plan.indices.length,
        failed: 0,
        currentChapter: plan.indices.first,
        finished: false,
        cancelled: false,
        cachedBefore: plan.cachedInRange,
      );
    });

    final result = await _downloader.downloadChapters(
      book,
      store,
      indices: plan.indices,
      cachedBefore: plan.cachedInRange,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );

    if (!mounted) return;
    setState(() => _progress = null);
    await _refreshCachedCount();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.cancelled
              ? '已暂停（本次存了 ${result.done} 章，再点一次继续）'
              : result.failed == 0
              ? '缓存完成 ${result.done} 章，断网也能读啦 🎀'
              : '缓存 ${result.done} 章，${result.failed} 章失败（可重试）',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 「检查更新」：抓站点目录看有没有新章，有就按范围补下来。
  Future<void> _checkUpdates() async {
    final book = _book;
    if (book == null || _checking || _downloader.running) return;
    if (book.cachePlan.isOff) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这本书关掉了自动缓存，先在「缓存设置」里打开')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      final r = await _tracker.trackOne(book.id, force: true);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.skipped
                ? '${r.name}：${r.reason ?? '没有新章节'}'
                : '《${r.name}》${r.summary}',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
      await _refreshCachedCount();
    }
  }

  /// 缓存范围设置面板（全部 / 从当前章到最新 + 追更 / 一段区间 / 不缓存）。
  Future<void> _showCacheSettings() async {
    final book = _book;
    if (book == null) return;
    await showBookCacheSettings(
      context,
      book: book,
      store: store,
      onSave: (plan) async {
        store.setCachePlan(book.id, plan);
        if (plan.isOff) return;
        // 选完立即按新范围开下（用户反馈：点完就该动起来）
        unawaited(_downloadByPlan());
      },
    );
  }

  Future<void> _changeCover() async {
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) =>
            const FolderPickerPage(mode: PickerMode.images, title: '选择新封面'),
      ),
    );
    if (picked == null || picked.isEmpty || _book == null) return;
    try {
      final src = File(picked.first);
      if (await src.length() > 20 * 1024 * 1024) throw StateError('too large');
      await store.coverDir.create(recursive: true);
      final target =
          '${store.coverDir.path}/${_book!.id}-${DateTime.now().microsecondsSinceEpoch}.img';
      await src.copy(target);
      _book!
        ..coverPath = target
        ..generatedCover = false;
      await store.flush();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('封面导入失败')));
      }
    }
  }

  /// 清空本书缓存。
  Future<void> _clearCache() async {
    await store.clearBookCache(widget.bookId);
    await _refreshCachedCount();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清除本书缓存')));
  }

  /// 目录区锚点：「查看目录」快捷入口直接滚到这里。
  final GlobalKey _chaptersKey = GlobalKey();

  void _jumpToChapters() {
    final ctx = _chaptersKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final book = store.byId(widget.bookId);
        if (book == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('这本书不在书架里了')),
          );
        }
        final isOnline = book.format == BookFormat.online;
        return Scaffold(
          floatingActionButton: FloatingActionButton.small(
            heroTag: 'edit-cover-${book.id}',
            tooltip: '更换封面',
            onPressed: _changeCover,
            child: const Icon(Icons.image_outlined),
          ),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _Header(
                  book: book,
                  store: store,
                  onShare: () => _shareBook(book),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: _Actions(
                    book: book,
                    onContinue: () => _openReader(context, book),
                    onOpenChapters: _jumpToChapters,
                    onSwitchSource: isOnline
                        ? () => _switchSource(context, book)
                        : null,
                    onDownload: isOnline && !_downloader.running
                        ? _showCacheSettings
                        : null,
                  ),
                ),
              ),
              // 离线缓存状态 / 下载进度（仅在线书）
              if (isOnline)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: _OfflineCard(
                      book: book,
                      cachedCount: _cachedCount,
                      progress: _progress,
                      checking: _checking,
                      onDownload: _downloadByPlan,
                      onSettings: _showCacheSettings,
                      onCheck: _checkUpdates,
                      onCancel: () {
                        _tracker.cancel();
                        _downloader.cancel();
                      },
                      onClear: _clearCache,
                    ),
                  ),
                ),
              if (book.intro.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: _IntroCard(intro: book.intro),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Row(
                    key: _chaptersKey,
                    children: [
                      Icon(
                        Icons.format_list_numbered_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '目录 · 共 ${book.chapterCount} 章',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 30),
                sliver: SliverList.separated(
                  itemCount: book.chapterCount,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) => _ChapterTile(
                    book: book,
                    index: index,
                    onTap: () => _openChapter(context, book, index),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openReader(BuildContext context, Book book) {
    store.touch(book.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          store: store,
          prefs: widget.prefs,
          bookId: book.id,
          chapterIndex: book.safeChapterIndex,
          charOffset: book.charOffset,
        ),
      ),
    );
  }

  void _openChapter(BuildContext context, Book book, int index) {
    store.touch(book.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          store: store,
          prefs: widget.prefs,
          bookId: book.id,
          chapterIndex: index,
          charOffset: index == book.safeChapterIndex ? book.charOffset : 0,
        ),
      ),
    );
  }

  /// 在线书换源：自动搜索候选 → 选择 → 切换（保留阅读进度）。
  /// 分享这本书：书名 + 作者 + 书源 + 书籍地址，另一台手机照着做就能打开。
  Future<void> _shareBook(Book book) async {
    final sourceStore = SourceStore.shared;
    String? sourceName;
    if (sourceStore != null && book.sourceUrl != null) {
      for (final s in sourceStore.sources) {
        if (s.bookSourceUrl == book.sourceUrl) {
          sourceName = s.bookSourceName;
          break;
        }
      }
    }
    final isOnline = book.format == BookFormat.online;
    final text = buildBookShareText(
      title: book.title,
      author: book.author,
      sourceName: sourceName,
      sourceUrl: book.sourceUrl,
      bookUrl: isOnline ? book.path : null,
      isOnline: isOnline,
    );
    final ok = await shareText(text, title: '分享这本书');
    if (!mounted) return;
    if (ok) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('没有可用的分享应用，已复制到剪贴板')));
  }

  Future<void> _switchSource(BuildContext context, Book book) async {
    final sourceStore = SourceStore.shared;
    if (sourceStore == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showSourceSwitchSheet(
      context,
      bookStore: store,
      sourceStore: sourceStore,
      book: book,
    );
    if (ok) {
      messenger.showSnackBar(const SnackBar(content: Text('已换源 🎀')));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.book,
    required this.store,
    required this.onShare,
  });

  final Book book;
  final BookStore store;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    // 头部即渐变容器本身：渐变铺满整个头部（含状态栏区域），状态栏透明 →
    // 头部颜色直接透到状态栏底下（用户偏好这种透明观感）。
    return Stack(
      children: [
        // 背景：封面模糊 + 主题渐变
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: SakuraTheme.headerGradient(context),
            ),
          ),
        ),
        Positioned.fill(
          child: ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Opacity(
                opacity: .45,
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: 240,
                      height: 320,
                      child: BookCover(book: book, radius: 0),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(8, topPad + 4, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '分享这本书',
                    onPressed: onShare,
                    icon: const Icon(Icons.share_rounded, color: Colors.white),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 112,
                    height: 156,
                    child: BookCover(book: book, radius: 14),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            book.author.isEmpty ? '佚名' : book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .9),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _chip(book.formatLabel),
                              _chip('${book.chapterCount} 章'),
                              if (book.totalChars > 0)
                                _chip(_charsLabel(book.totalChars)),
                              if (book.finished) _chip('已读完'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _charsLabel(int chars) {
    if (chars >= 10000) {
      return '${(chars / 10000).toStringAsFixed(1)} 万字';
    }
    return '$chars 字';
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .22),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.book,
    required this.onContinue,
    required this.onOpenChapters,
    this.onSwitchSource,
    this.onDownload,
  });

  final Book book;
  final VoidCallback onContinue;
  final VoidCallback onOpenChapters;
  final VoidCallback? onSwitchSource;

  /// 「缓存整本」入口（仅在线书提供）。
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final started = book.lastReadAt > 0 && !book.finished;
    final scheme = Theme.of(context).colorScheme;
    // 用户反馈（截图借鉴「阅读」详情页）：四个圆角图标入口 + 底部主按钮，
    // 比原来「一排按钮 + 进度胶囊」更好扫读。
    Widget tile(IconData icon, String label, VoidCallback? onTap) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: onTap == null
                      ? scheme.onSurfaceVariant.withValues(alpha: .4)
                      : scheme.primary,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: onTap == null
                        ? scheme.onSurfaceVariant.withValues(alpha: .5)
                        : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        SoftCard(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          color: scheme.surface,
          child: Row(
            children: [
              tile(Icons.menu_book_rounded, '目录', onOpenChapters),
              tile(Icons.swap_horiz_rounded, '换源', onSwitchSource),
              tile(Icons.cloud_download_rounded, '缓存', onDownload),
              tile(Icons.insights_rounded, '进度 ${book.progressLabel}', null),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onContinue,
            icon: const Icon(Icons.auto_stories_rounded, size: 20),
            label: Text(
              book.finished
                  ? '重新阅读'
                  : started
                  ? '继续阅读 · ${book.chapter?.title ?? '第 ${readingChapterNumber(book.chapters, book.safeChapterIndex)} 章'}'
                  : '开始阅读',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

/// 离线缓存卡片（仅在线书）：缓存范围 / 进度 / 操作按钮。
///
/// 用户反馈「不支持离线缓存」：这里让用户能把整本提前下好，
/// 之后地铁 / 飞机上断网也能接着读。
///
/// 0.41 起多了「范围」：全部 / 从当前章到最新（追更）/ 一段区间 / 不缓存。
class _OfflineCard extends StatelessWidget {
  const _OfflineCard({
    required this.book,
    required this.cachedCount,
    required this.progress,
    required this.checking,
    required this.onDownload,
    required this.onSettings,
    required this.onCheck,
    required this.onCancel,
    required this.onClear,
  });

  final Book book;

  /// 已缓存章节数（null = 还在统计）。
  final int? cachedCount;

  /// 下载进度（null = 空闲）。
  final OfflineDownloadProgress? progress;

  /// 正在抓目录检查新章（还没开始下）。
  final bool checking;

  final VoidCallback onDownload;
  final VoidCallback onSettings;
  final VoidCallback onCheck;
  final VoidCallback onCancel;
  final VoidCallback onClear;

  /// 进度条：范围内已下好的章 / 范围内总章数（不是「本次任务的百分比」）。
  double _bookFraction(OfflineDownloadProgress p) {
    final rangeTotal = p.total + p.cachedBefore;
    if (rangeTotal <= 0) return p.finished ? 1 : 0;
    return ((p.done + p.failed + p.cachedBefore) / rangeTotal).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = book.chapterCount;
    final cached = cachedCount ?? 0;
    final p = progress;
    final downloading = p != null;
    final plan = book.cachePlan;
    final off = plan.isOff;
    // 降序目录（漫画）里「第 N 章」的编号不是索引 +1
    final newestFirst = looksNewestFirst(book.chapters);

    // 文案：先回答「缓存哪一段」，再回答「存了多少」
    final String hint;
    if (cached >= total && total > 0) {
      hint = '整本已缓存，断网也能读啦～';
    } else if (off) {
      hint = '这本书不自动缓存（阅读时也不再预取）';
    } else if (plan.mode == CacheMode.from) {
      final n = readingChapterNumber(
        book.chapters,
        plan.start ?? book.safeChapterIndex,
      );
      hint = '从第 $n 章缓存到最新，新章自动补';
    } else if (plan.mode == CacheMode.range) {
      hint = '只缓存 ${plan.describe(total, newestFirst: newestFirst)}';
    } else {
      hint = '提前缓存整本，没网时也能接着看';
    }

    final String primaryLabel;
    if (downloading) {
      primaryLabel = '暂停';
    } else if (off) {
      primaryLabel = '打开缓存';
    } else if (cached > 0 && cached < total) {
      primaryLabel = '继续缓存';
    } else {
      primaryLabel = '开始缓存';
    }

    return SoftCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_download_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                '离线缓存',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                cachedCount == null
                    ? '统计中…'
                    : book.partialCache.isEmpty
                    ? '已缓存 $cached / $total 章'
                    : '已缓存 $cached / $total 章 · ${book.partialCache.length} 章部分',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 范围：一行小字 + 「改」，比再塞一排按钮省地方
          InkWell(
            onTap: downloading ? null : onSettings,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    off ? Icons.notifications_off_outlined : Icons.tune_rounded,
                    size: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '范围：${plan.describe(total, newestFirst: newestFirst)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '修改',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (downloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                // 按「这本书的位置」画：漫画从第 35 话缓存到最新只下 35 话，
                // 光看 34/35 会以为是整本快下完了。
                value: _bookFraction(p),
                minHeight: 7,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '正在缓存第 ${readingChapterNumber(book.chapters, p.currentChapter)} 章 · '
                    '${p.done}/${p.total}'
                    '${p.failed > 0 ? '（${p.failed} 章失败）' : ''}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('暂停', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ] else ...[
            Text(
              checking ? '正在检查有没有新章节…' : hint,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: checking ? null : onDownload,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 17),
                  label: Text(
                    primaryLabel,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                if (!off)
                  TextButton.icon(
                    onPressed: checking ? null : onCheck,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: checking
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('检查更新', style: TextStyle(fontSize: 12.5)),
                  ),
                if (cached > 0)
                  TextButton.icon(
                    onPressed: onClear,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 17),
                    label: const Text('清除缓存', style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _IntroCard extends StatefulWidget {
  const _IntroCard({required this.intro});

  final String intro;

  @override
  State<_IntroCard> createState() => _IntroCardState();
}

class _IntroCardState extends State<_IntroCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(icon: Icons.menu_book_rounded, title: '简介'),
          const SizedBox(height: 10),
          Text(
            widget.intro,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: scheme.onSurface.withValues(alpha: .86),
            ),
          ),
          if (widget.intro.length > 90)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? '收起' : '展开'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.book,
    required this.index,
    required this.onTap,
  });

  final Book book;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chapter = book.chapters[index];
    final isCurrent = index == book.safeChapterIndex && book.lastReadAt > 0;
    // 「已读」按阅读顺序判断（漫画目录降序，比当前话新的其实还没读）
    final isRead = isChapterRead(book, index);
    return Material(
      color: isCurrent ? scheme.primary.withValues(alpha: .12) : scheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: isRead
                    ? Icon(Icons.check_rounded, size: 17, color: scheme.primary)
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                          color: isCurrent ? scheme.primary : null,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.w900 : FontWeight.w500,
                    fontSize: 14,
                    color: isRead && !isCurrent
                        ? scheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                chapter.charCount > 0 ? '${chapter.charCount} 字' : '',
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: scheme.primary,
                  size: 22,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
