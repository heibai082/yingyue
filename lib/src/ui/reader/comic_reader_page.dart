// 漫画阅读页：纵向连续滚动看一话，可切上一话 / 下一话 / 目录。
//
// 设计取舍：
//   - 不做分页手势（左右滑），先做「一条长图往下滚」，和站点本身一致，
//     也避免了每张图尺寸不一导致的翻页错位；
//   - 图片用 Image.network 的内存缓存，换话时清掉旧误差；
//   - 进度只记「第几话」（Book.chapterIndex），符合漫画的阅读习惯。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/book_store.dart';
import '../../data/models.dart';
import '../../data/prefs.dart';
import '../../source/analyze_url.dart';
import '../../source/models.dart';
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

  Book? get _book => widget.store.byId(widget.bookId);

  @override
  void initState() {
    super.initState();
    final book = _book;
    _chapterIndex = widget.initialChapter ?? book?.safeChapterIndex ?? 0;
    unawaited(_load(_chapterIndex));
  }

  @override
  void dispose() {
    // 退出阅读页时把系统栏放回来，别把沉浸式带到书架
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    setState(() {
      _chapterIndex = safe;
      _loading = true;
      _error = null;
      _images = const [];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      final href = resolveUrl(
        book.chapters[safe].href ?? '',
        widget.source.bookSourceUrl,
      );
      final urls = await _service.fetchComicImages(widget.source, href);
      if (!mounted) return;
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
      if (urls.isNotEmpty) {
        widget.store.updateProgress(book.id, chapter: safe, offset: 0);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  void _prev() {
    if (_chapterIndex <= 0) return;
    unawaited(_load(_chapterIndex - 1));
  }

  void _next() {
    final book = _book;
    if (book == null || _chapterIndex >= book.chapters.length - 1) return;
    unawaited(_load(_chapterIndex + 1));
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
              onPressed: _chapterIndex > 0 ? _prev : null,
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
              onPressed: _chapterIndex < last ? _next : null,
              icon: const Icon(Icons.chevron_right_rounded),
              label: const Text('下一话'),
            ),
          ],
        ),
      ),
    );
  }
}
