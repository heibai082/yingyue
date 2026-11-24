// 漫画阅读页：纵向连续滚动看一话，可切上一话 / 下一话 / 目录。
//
// 设计取舍：
//   - 不做分页手势（左右滑），先做「一条长图往下滚」，和站点本身一致，
//     也避免了每张图尺寸不一导致的翻页错位；
//   - 图片用 Image.network 的内存缓存，换话时清掉旧误差；
//   - 进度只记「第几话」（Book.chapterIndex），符合漫画的阅读习惯。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/book_store.dart';
import '../../data/models.dart';
import '../../data/prefs.dart';
import '../../source/analyze_url.dart';
import '../../source/models.dart';
import '../../source/chapter_order.dart';
import '../../source/comic_chapter_cache.dart';
import '../../source/online_book_service.dart';

class ComicReaderPage extends StatefulWidget {
  const ComicReaderPage({
    super.key,
    required this.store,
    required this.prefs,
    required this.bookId,
    required this.source,
    this.initialChapter,
  });

  final BookStore store;
  final AppPrefs prefs;
  final String bookId;
  final BookSource source;

  /// 从文字阅读器切过来时，指定从哪一话开始。
  final int? initialChapter;

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  final OnlineBookService _service = OnlineBookService();
  final ScrollController _scroll = ScrollController();

  late int _chapterIndex;
  List<String> _images = const [];
  bool _loading = true;
  String? _error;

  /// 顶栏 / 底栏是否露出。横屏默认收起，点画面中间切换（沉浸式看漫画）。
  bool _chrome = true;
  bool? _wasLandscape;

  /// 每本书一份「章节地址 → 图片列表」缓存：翻回来 / 预取过的直接出图，
  /// 并且会落到这本书的缓存目录，下次打开 App 也算预取过。
  static final Map<String, ComicChapterCache> _caches = {};
  static final Set<String> _loadedBooks = {};

  /// 正在预取的章节，避免重复请求。
  static final Set<String> _prefetching = {};

  Timer? _cacheSaveTimer;

  ComicChapterCache get _chapterCache =>
      _caches.putIfAbsent(widget.bookId, ComicChapterCache.new);

  File get _cacheFile => File(
    '${widget.store.chapterCacheDir(widget.bookId).path}/comic_list_cache.json',
  );

  Future<void> _ensureCacheLoaded() async {
    if (!_loadedBooks.add(widget.bookId)) return;
    await _chapterCache.loadFrom(_cacheFile);
    if (mounted) setState(() {});
  }

  void _scheduleCacheSave() {
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_chapterCache.saveTo(_cacheFile));
    });
  }

  Book? get _book => widget.store.byId(widget.bookId);

  @override
  void initState() {
    super.initState();
    final book = _book;
    _chapterIndex = widget.initialChapter ?? book?.safeChapterIndex ?? 0;
    unawaited(_ensureCacheLoaded());
    unawaited(_load(_chapterIndex));
  }

  @override
  void dispose() {
    // 退出阅读页时把系统栏放回来，别把沉浸式带到书架
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _cacheSaveTimer?.cancel();
    unawaited(_chapterCache.saveTo(_cacheFile));
    _scroll.dispose();
    _service.dispose();
    super.dispose();
  }

  void _setImmersive(bool hide) {
    SystemChrome.setEnabledSystemUIMode(
      hide ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    // 横屏时连系统状态栏一起收，才算真全屏
    _setImmersive(!_chrome && _wasLandscape == true);
  }

  Future<void> _load(int index) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final safe = index.clamp(0, book.chapters.length - 1);
    final href = resolveUrl(
      book.chapters[safe].href ?? '',
      widget.source.bookSourceUrl,
    );
    // 先把「看到第几话」记下来：哪怕这一话取不到图，退出再进来也该回到这儿
    widget.store.updateProgress(book.id, chapter: safe, offset: 0);
    // 这一话刚看过（或后台预取过）：直接出图，不再转圈
    final cached = _chapterCache[href];
    setState(() {
      _chapterIndex = safe;
      _loading = cached == null;
      _error = null;
      _images = cached ?? const [];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (cached != null) {
      _afterLoaded(book, safe, href, cached);
      return;
    }
    try {
      final urls = await _service.fetchComicImages(widget.source, href);
      if (!mounted) return;
      _putCache(href, urls);
      setState(() {
        _images = urls;
        _loading = false;
        if (urls.isEmpty) {
          _error =
              '这一话没取到图片：站点网页版可能只给 App/会员看（包子漫画的'
              '「最新一话」就是这样）。\n试试上一话 / 下一话，或者换个漫画源。\n'
              '（章节地址：$href）';
        }
      });
      if (urls.isNotEmpty) _afterLoaded(book, safe, href, urls);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // ComicUnavailable 自带给读者看的解释，别再加一层「加载失败」
        _error = e is ComicUnavailable ? '$e' : '加载失败：$e';
      });
    }
  }

  /// 出图之后的后台活儿：预热前几页、去掉广告页、把下一话预备好。
  ///
  /// 都不挡当前这一话的显示 —— 这是「打开不转圈」的关键。
  void _afterLoaded(Book book, int index, String href, List<String> urls) {
    widget.store.updateProgress(book.id, chapter: index, offset: 0);
    _warmFirstPages(urls);
    unawaited(_stripAdsInBackground(href, urls));
    // 默认往后缓存两章：看完这一话点「下一话」基本秒开
    if (widget.prefs.autoPrefetchChapters) {
      final step = olderStep(book.chapters);
      for (var d = 1; d <= 2; d++) {
        // 「下一话」的方向（漫画是索引 -1）
        unawaited(_prefetch(index - step * d));
      }
    }
  }

  /// 先把前 3 页拉进 Flutter 的图片缓存，滚下去时就不用一张张转圈。
  void _warmFirstPages(List<String> urls) {
    for (final u in urls.take(3)) {
      unawaited(
        precacheImage(NetworkImage(u), context).catchError((Object _) {}),
      );
    }
  }

  /// 广告页探测比较慢（要读每张图尺寸），放后台；有删减再刷新列表。
  Future<void> _stripAdsInBackground(String href, List<String> urls) async {
    if (urls.length < 4) return;
    List<String> kept;
    try {
      kept = await _service.removeAdPages(urls);
    } catch (_) {
      return;
    }
    if (!mounted || kept.length == urls.length) return;
    _putCache(href, kept);
    // 用户已经翻到别的话了就别动当前画面
    if (_images.length != urls.length) return;
    setState(() => _images = kept);
  }

  void _putCache(String href, List<String> urls) {
    _chapterCache.put(href, urls);
    _scheduleCacheSave();
  }

  /// 后台把下一话的图片列表取好，点「下一话」就是秒开。
  Future<void> _prefetch(int index) async {
    final book = _book;
    if (book == null || index < 0 || index >= book.chapters.length) return;
    final href = resolveUrl(
      book.chapters[index].href ?? '',
      widget.source.bookSourceUrl,
    );
    if (_chapterCache.contains(href) || !_prefetching.add(href)) return;
    try {
      final urls = await _service.fetchComicImages(widget.source, href);
      _putCache(href, urls);
    } catch (_) {
      // 预取失败无所谓，点进去时会再试
    } finally {
      _prefetching.remove(href);
    }
  }

  /// 漫画目录是「最新话在前」（降序），所以「上一话」是索引 +1、「下一话」是 -1。
  /// 以前写死 ±1，结果上一话跑到更新的一话去了。
  void _prev() {
    final book = _book;
    if (book == null) return;
    final i = olderIndex(book.chapters, _chapterIndex);
    if (i == null) return;
    unawaited(_load(i));
  }

  void _next() {
    final book = _book;
    if (book == null) return;
    final i = newerIndex(book.chapters, _chapterIndex);
    if (i == null) return;
    unawaited(_load(i));
  }

  Future<void> _openToc() async {
    final book = _book;
    if (book == null) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView.builder(
            itemCount: book.chapters.length,
            itemBuilder: (_, i) {
              final cur = i == _chapterIndex;
              return ListTile(
                dense: true,
                selected: cur,
                title: Text(
                  book.chapters[i].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: cur
                    ? const Icon(Icons.play_arrow_rounded, size: 18)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              );
            },
          ),
        ),
      ),
    );
    if (picked != null && picked != _chapterIndex) {
      unawaited(_load(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    if (book == null) {
      return const Scaffold(body: Center(child: Text('这本书不见了')));
    }
    final chapter = book.chapters.isEmpty
        ? null
        : book.chapters[_chapterIndex.clamp(0, book.chapters.length - 1)];

    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (_wasLandscape != landscape) {
      _wasLandscape = landscape;
      // 横屏默认收起顶栏/底栏 + 隐藏系统栏：画面铺满整屏，不留黑边
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _chrome = !landscape);
        _setImmersive(landscape);
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      // 顶栏 / 底栏不再占布局空间，改成浮在画面上的叠加层：
      // 这样图片能顶到屏幕边缘，点画面中间可以随时收起/唤出
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleChrome,
              child: _buildBody(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _overlay(visible: _chrome, child: _topBar(book, chapter)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _overlay(visible: _chrome, child: _bottomBar(book)),
          ),
        ],
      ),
    );
  }

  /// 叠加层：隐藏时不接手势，避免挡住「点一下切换」。
  Widget _overlay({required bool visible, required Widget child}) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: child,
      ),
    );
  }

  Widget _topBar(Book book, ChapterRef? chapter) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: .78),
            Colors.black.withValues(alpha: .0),
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
                color: Colors.white,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, color: Colors.white),
                    ),
                    if (chapter != null)
                      Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: .7),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '目录',
                onPressed: _openToc,
                icon: const Icon(Icons.list_rounded),
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (_images.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? '这一话是空的',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.6),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(_chapterIndex),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: _images.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Image.network(
          _images[i],
          fit: BoxFit.fitWidth,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final p = progress.expectedTotalBytes;
            return AspectRatio(
              aspectRatio: 3 / 4,
              child: Center(
                child: CircularProgressIndicator(
                  value: p == null ? null : progress.cumulativeBytesLoaded / p,
                  strokeWidth: 2,
                ),
              ),
            );
          },
          errorBuilder: (context, error, stack) => Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '第 ${i + 1} 张加载失败（长按重试）',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(Book book) {
    final last = book.chapters.length - 1;
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black.withValues(alpha: .9),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: olderIndex(book.chapters, _chapterIndex) == null
                  ? null
                  : _prev,
              icon: const Icon(Icons.chevron_left_rounded),
              label: const Text('上一话'),
            ),
            Expanded(
              child: Text(
                '${_chapterIndex + 1}/${book.chapters.length}'
                '${_images.isNotEmpty ? ' · ${_images.length} 张' : ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: newerIndex(book.chapters, _chapterIndex) == null
                  ? null
                  : _next,
              icon: const Icon(Icons.chevron_right_rounded),
              label: const Text('下一话'),
            ),
          ],
        ),
      ),
    );
  }
}
