import 'package:flutter/material.dart';

import '../../data/book_store.dart';
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
  String? _busy; // 正在重搜的书名
  String? _status; // 行内提示
  bool _statusOk = false;

  Future<void> _retry(String title, String author) async {
    if (_busy != null) return;
    setState(() {
      _busy = title;
      _status = '正在搜索《$title》…';
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
    if (_busy != null) return;
    final items = List.of(ImportFailStore.instance.items);
    var okCount = 0;
    for (final it in items) {
      if (!mounted) return;
      setState(() {
        _busy = it.title;
        _status = '正在搜索《${it.title}》（已成功 $okCount / ${items.length}）';
        _statusOk = false;
      });
      final r = await researchBook(
        title: it.title,
        author: it.author,
        shelf: widget.store,
        sources: widget.sources,
      );
      if (r.ok) okCount++;
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _status = '全部重搜结束：成功 $okCount / ${items.length}';
      _statusOk = okCount > 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: ImportFailStore.instance,
      builder: (ctx, _) {
        final items = ImportFailStore.instance.items;
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
                      onPressed: _busy == null && items.isNotEmpty
                          ? _retryAll
                          : null,
                      child: const Text('全部重搜', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: _busy == null && items.isNotEmpty
                          ? () => ImportFailStore.instance.clear()
                          : null,
                      child: const Text('清空', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              if (_status != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: (_statusOk ? scheme.primary : scheme.error)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (_busy != null)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          _statusOk
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          size: 14,
                          color: _statusOk ? scheme.primary : scheme.error,
                        ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _status!,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: _statusOk ? scheme.primary : scheme.error,
                          ),
                        ),
                      ),
                    ],
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
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = items[i];
                      final isBusy = _busy == it.title;
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
                            : TextButton(
                                onPressed: _busy == null
                                    ? () => widget.onOpenSources(
                                        context, it.title)
                                    : null,
                                child: const Text('看来源',
                                    style: TextStyle(fontSize: 12)),
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
