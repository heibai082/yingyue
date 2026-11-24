// 缓存范围设置面板（书籍详情页 / 阅读器共用）。
//
// 用户反馈原话：「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从当前
// 章节缓存到最新（并且开启自动追剧模式缓存）」。
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/book_store.dart';
import '../data/cache_plan.dart';
import '../data/models.dart';

/// 弹出缓存设置面板；[onSave] 负责落库 + 开下。
Future<void> showBookCacheSettings(
  BuildContext context, {
  required Book book,
  required BookStore store,
  required Future<void> Function(BookCachePlan plan) onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BookCacheSettingsSheet(
      book: book,
      onPreview: (plan) async {
        // 预览「这个范围有多少章」，让用户点之前就知道要下多少
        final set = await store.refreshChapterCache(book.id);
        return buildCachePlan(book, plan: plan, cached: set);
      },
      onSave: onSave,
    ),
  );
}

/// 缓存范围设置面板。
///
/// 用户反馈原话：「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从当前
/// 章节缓存到最新（并且开启自动追剧模式缓存）」——所以这里给四条路：
///   全部 / 从当前章到最新 + 追更 / 只下一段 / 不缓存。
class BookCacheSettingsSheet extends StatefulWidget {
  const BookCacheSettingsSheet({
    super.key,
    required this.book,
    required this.onPreview,
    required this.onSave,
  });

  final Book book;

  /// 预览：算出「这个范围要下多少章、已经存了多少」。
  final Future<CacheDownloadPlan> Function(BookCachePlan plan) onPreview;

  final Future<void> Function(BookCachePlan plan) onSave;

  @override
  State<BookCacheSettingsSheet> createState() => _BookCacheSettingsSheetState();
}

class _BookCacheSettingsSheetState extends State<BookCacheSettingsSheet> {
  late CacheMode _mode = widget.book.cachePlan.mode;
  late int _start = widget.book.cachePlan.start ?? widget.book.safeChapterIndex;
  late int _end = widget.book.cachePlan.end ?? widget.book.chapterCount - 1;

  CacheDownloadPlan? _preview;
  bool _previewing = true;

  Book get book => widget.book;

  int get _total => book.chapterCount;

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  BookCachePlan get _plan => BookCachePlan(
    mode: _mode,
    start: switch (_mode) {
      CacheMode.from => _start,
      CacheMode.range => _start,
      _ => null,
    },
    end: _mode == CacheMode.range ? _end : null,
  );

  Future<void> _refreshPreview() async {
    if (!mounted) return;
    setState(() => _previewing = true);
    final r = await widget.onPreview(_plan);
    if (mounted) {
      setState(() {
        _preview = r;
        _previewing = false;
      });
    }
  }

  void _setMode(CacheMode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      // 「从当前章」永远以当前阅读位置为默认起点（每次点都重新对齐）
      if (m == CacheMode.from) _start = book.safeChapterIndex;
      if (m == CacheMode.range) {
        if (_end < _start) _end = _total - 1;
      }
    });
    _refreshPreview();
  }

  /// 输入章节号（1 起，用户看得懂的那个）。取消返回 null。
  Future<int?> _askChapter(String title, int current) async {
    final controller = TextEditingController(
      text: '${(current + 1).clamp(1, _total <= 0 ? 1 : _total)}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '章节序号',
            helperText: '1 ~ $_total',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    final n = int.tryParse(controller.text.trim());
    controller.dispose();
    if (n == null) return null;
    return (n - 1).clamp(0, _total <= 0 ? 0 : _total - 1).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _preview;
    final current = book.safeChapterIndex;

    Widget option({
      required CacheMode mode,
      required IconData icon,
      required String title,
      required String desc,
    }) {
      final on = _mode == mode;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          onTap: () => _setMode(mode),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: on
                  ? scheme.primary.withValues(alpha: .10)
                  : scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: on
                    ? scheme.primary.withValues(alpha: .55)
                    : scheme.outlineVariant.withValues(alpha: .5),
                width: on ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: on ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  on
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 19,
                  color: on ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget rangeRow(String label, int value, VoidCallback onTap) => Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5)),
        const Spacer(),
        TextButton(
          onPressed: onTap,
          child: Text(
            '第 ${readingChapterNumber(book.chapters, value)} 章',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_download_rounded, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '缓存设置',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  '共 $_total 章',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            option(
              mode: CacheMode.all,
              icon: Icons.download_done_rounded,
              title: '全部缓存',
              desc: '整本都下（含已读过的），断网随便翻',
            ),
            option(
              mode: CacheMode.from,
              icon: Icons.auto_mode_rounded,
              title: '从当前章缓存到最新',
              desc:
                  '只下「第 ${readingChapterNumber(book.chapters, current)} 章 → 最新」，'
                  '新章出来自动补（追更）',
            ),
            option(
              mode: CacheMode.range,
              icon: Icons.linear_scale_rounded,
              title: '只缓存一段',
              desc: '指定起止章节，省流量 / 省空间',
            ),
            option(
              mode: CacheMode.off,
              icon: Icons.notifications_off_outlined,
              title: '不自动缓存',
              desc: '只在读到哪存哪；启动时也不追更这本书',
            ),
            if (_mode == CacheMode.from || _mode == CacheMode.range) ...[
              const SizedBox(height: 2),
              rangeRow(
                _mode == CacheMode.from ? '起点' : '起始章',
                _start,
                () async {
                  final n = await _askChapter(
                    _mode == CacheMode.from ? '从第几章开始缓存？' : '起始章',
                    _start,
                  );
                  if (n == null) return;
                  setState(() {
                    _start = n;
                    if (_mode == CacheMode.range && _end < _start) {
                      _end = _total <= 0 ? 0 : _total - 1;
                    }
                  });
                  _refreshPreview();
                },
              ),
              if (_mode == CacheMode.range)
                rangeRow('结束章', _end, () async {
                  final n = await _askChapter('到第几章为止？', _end);
                  if (n == null) return;
                  setState(() {
                    _end = n;
                    if (_start > _end) _start = _end;
                  });
                  _refreshPreview();
                }),
            ],
            const SizedBox(height: 6),
            // 预览：让用户点「开始」前就知道要下多少
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _previewing || p == null
                    ? '正在统计…'
                    : _mode == CacheMode.off
                    ? '选择后：不再自动缓存这本书'
                    : p.total == 0
                    ? '这本书还没有目录'
                    : '范围内 ${p.total} 章 · 已存 ${p.cachedInRange} 章 · '
                          '要下 ${p.indices.length} 章',
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final plan = _plan.copyWith(
                        updatedAt: DateTime.now().millisecondsSinceEpoch,
                      );
                      Navigator.pop(context);
                      await widget.onSave(plan);
                    },
                    icon: Icon(
                      _mode == CacheMode.off
                          ? Icons.notifications_off_outlined
                          : Icons.download_rounded,
                      size: 19,
                    ),
                    label: Text(
                      _mode == CacheMode.off ? '关掉这本书的缓存' : '保存并开始缓存',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
