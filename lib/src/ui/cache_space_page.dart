// 缓存空间：每本书占多少、完整度、可删 / 只保留最近 N 章 / 导出。
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/book_store.dart';
import '../data/cache_export.dart';
import '../data/models.dart';
import '../data/prefs.dart';
import '../util/format.dart';
import 'widgets/cute.dart';

class CacheSpacePage extends StatefulWidget {
  const CacheSpacePage({
    super.key,
    required this.store,
    required this.prefs,
    this.exporter,
  });

  final BookStore store;
  final AppPrefs prefs;

  /// 测试可注入导出目录。
  final CacheExporter? exporter;

  @override
  State<CacheSpacePage> createState() => _CacheSpacePageState();
}

class _CacheSpacePageState extends State<CacheSpacePage> {
  final Map<String, int> _sizes = {};
  bool _loading = true;
  String? _busyId;

  BookStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    setState(() => _loading = true);
    final sizes = <String, int>{};
    for (final b in store.books) {
      sizes[b.id] = await store.bookCacheBytes(b.id);
      await store.refreshChapterCache(b.id);
    }
    if (!mounted) return;
    setState(() {
      _sizes
        ..clear()
        ..addAll(sizes);
      _loading = false;
    });
  }

  int get _total => _sizes.values.fold(0, (a, b) => a + b);

  String _fmt(int bytes) => formatBytes(bytes);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final limit = widget.prefs.cacheLimitMB;
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存空间'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loadSizes,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SoftCard(
            radius: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '共占用 ${_fmt(_total)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '上限 $limit MB · 超出会按「最久没读」整本清理',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _loading
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final orphans = await store.pruneOrphanCaches();
                              final freed = await store.enforceCacheLimit(
                                limit,
                              );
                              await _loadSizes();
                              if (!mounted) return;
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '已清理 $orphans 本孤儿缓存'
                                    '${freed > 0 ? '，释放 ${_fmt(freed)}' : ''}',
                                  ),
                                ),
                              );
                            },
                      icon: const Icon(Icons.auto_delete_rounded, size: 18),
                      label: const Text('立即清理'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (store.books.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('书架还是空的')),
            )
          else
            for (final book in store.books)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _BookCacheTile(
                  book: book,
                  size: _sizes[book.id] ?? 0,
                  busy: _busyId == book.id,
                  onTrim: () => _trim(book),
                  onClear: () => _clear(book),
                  onExport: () => _export(book),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _trim(Book book) async {
    setState(() => _busyId = book.id);
    try {
      final removed = await store.trimBookCache(book.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed == 0 ? '这本书没有可裁剪的缓存' : '已删掉 $removed 处缓存（保留最近 50 章）',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
      await _loadSizes();
    }
  }

  Future<void> _clear(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除《${book.title}》的缓存？'),
        content: const Text('正文 / 漫画图片都会删掉，阅读进度和书源保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.clearBookCache(book.id);
    await _loadSizes();
  }

  Future<void> _export(Book book) async {
    setState(() => _busyId = book.id);
    final exporter =
        widget.exporter ?? CacheExporter(filesFallback: store.appDirs.files);
    try {
      final result = book.format == BookFormat.online
          ? await _exportOnline(book, exporter)
          : await exporter.exportNovel(book, store);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${result.chapters} 章 · ${_fmt(result.bytes)}\n${result.path}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// 在线书：有图片缓存当漫画导 CBZ，否则当小说导 TXT。
  Future<ExportResult> _exportOnline(Book book, CacheExporter exporter) async {
    final imgRoot = Directory('${store.chapterCacheDir(book.id).path}/img');
    final hasImages = imgRoot.existsSync() && imgRoot.listSync().isNotEmpty;
    return hasImages
        ? exporter.exportComic(book, store)
        : exporter.exportNovel(book, store);
  }
}

class _BookCacheTile extends StatelessWidget {
  const _BookCacheTile({
    required this.book,
    required this.size,
    required this.busy,
    required this.onTrim,
    required this.onClear,
    required this.onExport,
  });

  final Book book;
  final int size;
  final bool busy;
  final VoidCallback onTrim;
  final VoidCallback onClear;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cached = book.chapterCache.length;
    final partial = book.partialCache.length;
    return SoftCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                formatBytes(size),
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '已缓存 $cached / ${book.chapterCount} 章'
            '${partial > 0 ? ' · $partial 章部分' : ''}'
            '${book.lastReadAt > 0 ? ' · ${_lastRead(book.lastReadAt)}' : ''}',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(minHeight: 3),
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onExport, child: const Text('导出')),
                TextButton(onPressed: onTrim, child: const Text('留最近 50 章')),
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  child: const Text('删缓存'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _lastRead(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前读过';
    if (diff.inHours < 24) return '${diff.inHours} 小时前读过';
    return '${diff.inDays} 天前读过';
  }
}
