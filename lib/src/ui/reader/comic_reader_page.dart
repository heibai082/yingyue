// 漫画阅读页：纵向连续滚动看一话，可切上一话 / 下一话 / 目录。
//
// 设计取舍：
//   - 不做分页手势（左右滑），先做「一条长图往下滚」，和站点本身一致，
//     也避免了每张图尺寸不一导致的翻页错位；
//   - 图片用 Image.network 的内存缓存，换话时清掉旧误差；
//   - 进度只记「第几话」（Book.chapterIndex），符合漫画的阅读习惯。
import 'dart:async';

import 'package:flutter/material.dart';

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
    _scroll.dispose();
    _service.dispose();
    super.dispose();
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: .85),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
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
        actions: [
          IconButton(
            tooltip: '目录',
            onPressed: _openToc,
            icon: const Icon(Icons.list_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _bottomBar(book),
        ],
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
