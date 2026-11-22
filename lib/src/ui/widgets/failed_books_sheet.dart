import 'package:flutter/material.dart';

import '../../data/book_store.dart';
import '../../data/failed_books_retry.dart';
import '../../data/import_fail_store.dart';
import '../../data/import_research.dart';
import '../../source/source_store.dart';

/// 打开「待搜源」面板：逐本重搜，结果直接用行内状态显示
/// （弹窗里用 SnackBar 会被面板挡住，用户看不到反馈）。
Future<void> showFailedBooksSheet(
  BuildContext context, {
  required BookStore store,
  required SourceStore sources,
  /// 点「重搜」时跳去搜书页（带书名），由调用方提供
  required Future<void> Function(BuildContext sheetCtx, String title) onOpenSources,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FailedBooksSheet(
      store: store,
      sources: sources,
      onOpenSources: onOpenSources,
    ),
  );
}

class _FailedBooksSheet extends StatefulWidget {
  const _FailedBooksSheet({
    required this.store,
    required this.sources,
    required this.onOpenSources,
  });

  final BookStore store;
  final SourceStore sources;
  final Future<void> Function(BuildContext sheetCtx, String title) onOpenSources;

  @override
  State<_FailedBooksSheet> createState() => _FailedBooksSheetState();
}

class _FailedBooksSheetState extends State<_FailedBooksSheet> {
  String? _busy; // 正在单本重搜的书名
  String? _status; // 行内提示
  bool _statusOk = false;

  /// 「全部重搜」是常驻后台任务：关掉面板 / 切 App 都继续跑。
  final _retry = FailedBooksRetryController.instance;

  @override
  void initState() {
    super.initState();
    _retry.addListener(_onRetryChanged);
  }

  @override
  void dispose() {
    _retry.removeListener(_onRetryChanged);
    super.dispose();
  }

  void _onRetryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _retryOne(String title, String author) async {
    if (_busy != null) return;
    setState(() {
      _busy = title;
      _status = '正在搜索《$title》…（先试最可能可用的 $kResearchMaxSources 个源）';
      _statusOk = false;
    });
    final r = await researchBook(
      title: title,
      author: author,
      shelf: widget.store,
      sources: widget.sources,
    );
    if (!mounted) return;
    setState(() {
      _busy = null;
      _status = r.message;
      _statusOk = r.ok;
    });
  }

  Future<void> _retryAll() async {
    if (_retry.running) return;
    await _retry.startAll(shelf: widget.store, sources: widget.sources);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([ImportFailStore.instance, _retry]),
      builder: (ctx, _) {
        // 已经在书架上的没必要再列出来（顺手从清单删掉）
        final onShelf =
            widget.store.books.map((b) => b.title.trim()).toSet();
        final items = ImportFailStore.instance.items
            .where((e) => !onShelf.contains(e.title.trim()))
            .toList();
        final line = _retry.running
            ? (_retry.currentTitle == null
                  ? '准备中… ${_retry.progressText}'
                  : '正在搜索《${_retry.currentTitle}》 · ${_retry.progressText}')
            : (_status ?? '');
        final lineOk = _retry.running ? true : _statusOk;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '待搜源 ${items.length} 本',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _retry.running
                          ? null
                          : (_busy == null && items.isNotEmpty
                                ? _retryAll
                                : null),
                      child: const Text('全部重搜', style: TextStyle(fontSize: 12)),
                    ),
                    if (_retry.running)
                      TextButton(
                        onPressed: _retry.cancel,
                        child: const Text('停止', style: TextStyle(fontSize: 12)),
                      )
                    else
                      TextButton(
                        onPressed: _busy == null && items.isNotEmpty
                            ? () => ImportFailStore.instance.clear()
                            : null,
                        child: const Text('清空', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),
              if (line.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: (lineOk ? scheme.primary : scheme.error)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (_retry.running || _busy != null)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          lineOk
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          size: 14,
                          color: lineOk ? scheme.primary : scheme.error,
                        ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          line,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: lineOk ? scheme.primary : scheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_retry.running)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _retry.total == 0
                          ? null
                          : (_retry.done / _retry.total).clamp(0.0, 1.0),
                      minHeight: 6,
                    ),
                  ),
                ),
              if (_retry.running)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '可以关掉这个面板或切到别的页面，任务会在后台继续（通知栏看进度）',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text('没有待搜源的书了 🎉'),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.5,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = items[i];
                      final isBusy = _busy == it.title ||
                          (_retry.running && _retry.currentTitle == it.title);
                      return ListTile(
                        dense: true,
                        title: Text(
                          it.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: it.reason.isEmpty
                            ? null
                            : Text(
                                it.reason,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: isBusy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '只重搜这一本',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                    ),
                                    onPressed: _busy == null && !_retry.running
                                        ? () => _retryOne(it.title, it.author)
                                        : null,
                                  ),
                                  TextButton(
                                    onPressed: _busy == null && !_retry.running
                                        ? () => widget.onOpenSources(
                                            context, it.title)
                                        : null,
                                    child: const Text('看来源',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
