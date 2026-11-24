// 换源面板：为一本在线书（书架 / 阅读中）重新搜索并切换到新的书源。
//
// 流程：自动用当前书名搜索所有启用书源 → 按相关性排序展示候选
// → 选择后先拉取详情/目录校验，再切换（保留阅读进度，清空旧源章节缓存）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/book_store.dart';
import '../../data/models.dart';
import '../../source/models.dart';
import '../../source/online_book_service.dart';
import '../../data/source_cache_store.dart';
import '../../data/source_mark_store.dart';
import '../../source/online_repo.dart';
import '../../source/source_store.dart';

/// 打开换源面板；成功换源返回 true。
Future<bool> showSourceSwitchSheet(
  BuildContext context, {
  required BookStore bookStore,
  required SourceStore sourceStore,
  required Book book,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SourceSwitchSheet(
      bookStore: bookStore,
      sourceStore: sourceStore,
      book: book,
    ),
  );
  return ok == true;
}

class _Candidate {
  _Candidate(this.source, this.book, this.score, this.order);

  final BookSource source;
  final SearchBook book;
  final int score;
  final int order;

  String get name => (book.name ?? '').trim();
  String get author => (book.author ?? '').trim();
  String get url => (book.bookUrl ?? '').trim();
}

/// 换源时搜哪一类源。
enum _KindFilter {
  /// 跟着本书现在用的源走（漫画书只搜漫画源）。
  auto,
  comic,
  text,
}

class _SourceSwitchSheet extends StatefulWidget {
  const _SourceSwitchSheet({
    required this.bookStore,
    required this.sourceStore,
    required this.book,
  });

  final BookStore bookStore;
  final SourceStore sourceStore;
  final Book book;

  @override
  State<_SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

class _SourceSwitchSheetState extends State<_SourceSwitchSheet> {
  final OnlineBookService _service = OnlineBookService();

  bool _searching = true;
  String? _error;
  List<_Candidate> _candidates = const [];
  int? _busyIndex;
  bool _fromCache = false;

  // ---- 搜索进度（以前只有个转圈，几百个源要等十几分钟，看着像卡死）----
  int _searched = 0;
  int _total = 0;
  int _found = 0;
  bool _stopped = false;
  DateTime? _startedAt;
  Timer? _ticker;

  /// 搜哪一类源：漫画书默认只搜漫画源，避免搜出一堆同名同人文。
  _KindFilter _kind = _KindFilter.auto;

  String get _cacheKey => '${widget.book.title}|${widget.book.author}';

  /// 这本书现在用的源是不是漫画源。
  bool get _bookIsComic =>
      widget.sourceStore.byUrl(widget.book.sourceUrl ?? '')?.isComic ?? false;

  /// 这一轮要搜漫画源还是小说源。
  bool get _wantComic => switch (_kind) {
    _KindFilter.comic => true,
    _KindFilter.text => false,
    _KindFilter.auto => _bookIsComic,
  };

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }



  OnlineRepo? _repo;
  Future<void> _bootstrap() async {
    await SourceCacheStore.instance.ensureLoaded();
    await SourceMarkStore.instance.ensureLoaded();
    if (!mounted) return;
    await _search();
  }

  Future<void> _search({bool force = false}) async {
    // 这一轮要搜的源：漫画书只搜漫画源，避免搜出一堆同名同人文
    final wantComic = _wantComic;
    final pool = widget.sourceStore.enabled
        .where((s) => wantComic ? s.isComic : s.isText)
        .toList();

    // 没点「刷新」就先用上次的结果，避免每次打开都重新联网搜一遍
    if (!force) {
      await SourceCacheStore.instance.ensureLoaded();
      final cached = SourceCacheStore.instance.get(_cacheKey);
      if (cached != null && mounted) {
        final list = <_Candidate>[];
        var order = 0;
        for (final cc in cached) {
          final src = widget.sourceStore.byUrl(cc.sourceUrl);
          if (src == null) continue;
          if (src.isComic != wantComic) continue; // 只留同一类的缓存
          list.add(
            _Candidate(
              src,
              SearchBook(
                name: cc.name,
                author: cc.author,
                bookUrl: cc.bookUrl,
                coverUrl: cc.coverUrl,
                origin: cc.sourceUrl,
              ),
              cc.score,
              order++,
            ),
          );
        }
        if (list.isNotEmpty) {
          setState(() {
            _searching = false;
            _fromCache = true;
            _candidates = list;
            _total = pool.length;
            _found = list.length;
          });
          return;
        }
      }
    }
    if (mounted) {
      setState(() {
        _searching = true;
        _error = null;
        _candidates = [];
        _searched = 0;
        _found = 0;
        _stopped = false;
        _total = pool.length;
        _startedAt = DateTime.now();
      });
    }
    // 秒表：让「已用 xx s」能走起来（不然界面里永远是 0s）
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _searching) setState(() {});
    });
    SourceStore? scoped;
    try {
      if (pool.isEmpty) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _error = wantComic
              ? '没有启用的漫画源：先导入/启用一个「类型：图片」的书源'
              : '没有启用的小说源';
        });
        return;
      }
      scoped = SourceStore(initial: pool);
      final repo = _repo = OnlineRepo(
        store: scoped,
        perSourceTimeout: const Duration(seconds: 10),
      );
      final seen = <String>{};
      var good = 0;
      // 兜底：25 秒还没搜完，就先展示已经找到的，别让用户干等
      final deadline = Timer(const Duration(seconds: 25), () {
        if (mounted && _searching) {
          _stopped = true;
          repo.cancel();
        }
      });
      // 边搜边显示：哪个源先回来就先摆出来
      await repo.searchAll(
        widget.book.title,
        onSourceDone: (r) {
          if (!mounted) return;
          _searched++;
          if (r.ok) {
            for (final b in r.books) {
              final url = (b.bookUrl ?? '').trim();
              if (url.isEmpty) continue;
              if (!seen.add('${r.source.bookSourceUrl}|$url')) continue;
              final score = bookRelevanceScore(b, widget.book.title);
              // 只收与书名 / 作者沾边的候选，避免展示无关书
              if (score < 480) continue;
              _candidates = [
                ..._candidates,
                _Candidate(r.source, b, score, _candidates.length),
              ];
              good++;
            }
            if (good > 0) {
              _candidates = [..._candidates]
                ..sort((a, b) => b.score.compareTo(a.score));
            }
          }
          _found = _candidates.length;
          setState(() {});
          // 够换源用了就别再拿死源浪费时间
          if (good >= 6) {
            _stopped = true;
            repo.cancel();
          }
        },
      );
      deadline.cancel();
      _ticker?.cancel();
      if (!mounted) return;
      setState(() {
        _searching = false;
        _fromCache = false;
        if (_candidates.isEmpty) {
          _error = _stopped
              ? '搜了 $_searched 个${wantComic ? '漫画' : ''}源没找到可换的来源，稍后点右上角 ⟳ 再试'
              : '没有找到可用的换源结果';
        }
      });
      if (_candidates.isNotEmpty) {
        await SourceCacheStore.instance.put(_cacheKey, [
          for (final c in _candidates)
            CachedCandidate(
              sourceUrl: c.source.bookSourceUrl,
              name: c.name,
              author: c.author,
              bookUrl: c.url,
              coverUrl: c.book.coverUrl ?? '',
              score: c.score,
            ),
        ]);
      }
    } catch (e) {
      _ticker?.cancel();
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '$e';
      });
    } finally {
      scoped?.dispose();
    }
  }

  @override
  void dispose() {
    _repo?.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _showMarkDialog(_Candidate c) async {
    final url = c.source.bookSourceUrl;
    final marked = SourceMarkStore.instance.isMarked(url);
    final ctrl = TextEditingController(
      text: marked ? SourceMarkStore.instance.noteOf(url) : '',
    );
    final action = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('书源标记 · '),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '标记后会一直提醒你，下次换源看到这个源就知道别点了。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: '备注（可不填）',
                hintText: '比如：目录缺章 / 收费 / 大段乱码',
                isDense: true,
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          if (marked)
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop('unmark'),
              child: const Text('取消标记'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop('cancel'),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dCtx).pop('mark'),
            child: Text(marked ? '更新备注' : '标记这个源不行'),
          ),
        ],
      ),
    );
    if (action == 'mark') {
      await SourceMarkStore.instance.mark(url, ctrl.text);
      if (mounted) setState(() {});
    } else if (action == 'unmark') {
      await SourceMarkStore.instance.unmark(url);
      if (mounted) setState(() {});
    }
  }

  Future<void> _pick(int index) async {
    if (_busyIndex != null) return;
    final marked = _candidates[index];
    if (SourceMarkStore.instance.isMarked(marked.source.bookSourceUrl)) {
      final note = SourceMarkStore.instance.noteOf(marked.source.bookSourceUrl);
      final go = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          title: const Text('这个源你标记过'),
          content: Text(
            note.isEmpty
                ? '你之前标记过「${marked.source.bookSourceName}」不好用，确定还要换过去吗？'
                : '你之前标记过「${marked.source.bookSourceName}」：$note\n\n确定还要换过去吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('算了'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('还是要用'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    final cand = _candidates[index];
    setState(() => _busyIndex = index);
    try {
      final info = await _service.fetchInfo(cand.source, cand.url);
      if (info.chapters.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('该来源目录为空，无法切换')));
        }
        return;
      }
      await widget.bookStore.switchOnlineSource(
        widget.book.id,
        path: cand.url,
        sourceUrl: cand.source.bookSourceUrl,
        chapters: info.chapters,
        title: info.name ?? cand.name,
        author: info.author ?? cand.author,
        intro: info.intro,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('换源失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busyIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentSource = widget.sourceStore
        .byUrl(widget.book.sourceUrl ?? '')
        ?.bookSourceName;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '换源 · ${widget.book.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (currentSource != null)
                    Text(
                      '当前：$currentSource',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: _fromCache ? '重新联网搜索' : '刷新',
                    onPressed: _searching ? null : () => _search(force: true),
                    icon: Icon(
                      Icons.refresh_rounded,
                      size: 18,
                      color: _fromCache ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 源类型：漫画书默认只搜漫画源，别把同名同人文搜出来
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
              child: Row(
                children: [
                  Text(
                    '搜哪类源：',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 6),
                  for (final (mode, label) in const [
                    (_KindFilter.auto, '跟随本书'),
                    (_KindFilter.comic, '漫画源'),
                    (_KindFilter.text, '小说源'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(label, style: const TextStyle(fontSize: 11)),
                        selected: _kind == mode,
                        visualDensity: VisualDensity.compact,
                        onSelected: _searching
                            ? null
                            : (_) {
                                setState(() => _kind = mode);
                                unawaited(_search(force: true));
                              },
                      ),
                    ),
                ],
              ),
            ),
            if (_fromCache && !_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Row(
                  children: [
                    Icon(Icons.history_rounded, size: 13, color: scheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '这是上次搜到的结果（不会自动重搜），点右上角 ⟳ 才重新联网',
                        style: TextStyle(fontSize: 11, color: scheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: _buildList(context, scheme)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, ColorScheme scheme) {
    if (_searching) {
      final elapsed = _startedAt == null
          ? 0
          : DateTime.now().difference(_startedAt!).inSeconds;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 8, 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已搜 $_searched/$_total 个源 · 找到 $_found 个候选 · ${elapsed}s'
                    '${_stopped ? '（提前收工）' : ''}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _stopped
                      ? null
                      : () {
                          setState(() => _stopped = true);
                          _repo?.cancel();
                        },
                  child: const Text('停止', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (_searched / _total).clamp(0.0, 1.0),
                  minHeight: 5,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(child: _candidateList(context, scheme)),
        ],
      );
    }
    final error = _error;
    if (error != null && _candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
      );
    }
    return _candidateList(context, scheme);
  }

  Widget _candidateList(BuildContext context, ColorScheme scheme) {
    if (_candidates.isEmpty) {
      return Center(
        child: Text(
          _searching ? '正在搜索可用书源…' : '没有找到可用的换源结果',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      itemCount: _candidates.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final c = _candidates[i];
        final isCurrent = c.url == widget.book.path;
        final busy = _busyIndex == i;
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: isCurrent || busy ? null : () => _pick(i),
            onLongPress: busy ? null : () => _showMarkDialog(c),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name.isEmpty ? '（未命名）' : c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (c.author.isNotEmpty) c.author,
                            c.source.bookSourceName,
                            if (c.source.isComic) '漫画源',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: c.source.isComic
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        if (SourceMarkStore.instance
                            .isMarked(c.source.bookSourceUrl)) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(Icons.block, size: 12, color: scheme.error),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  SourceMarkStore.instance
                                          .noteOf(c.source.bookSourceUrl)
                                          .isEmpty
                                      ? '你标记过：这个源不好用'
                                      : '你标记过：${SourceMarkStore.instance.noteOf(c.source.bookSourceUrl)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: scheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (isCurrent)
                    Text(
                      '当前',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    )
                  else
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
