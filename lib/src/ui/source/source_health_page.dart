// 书源体检：一次跑完所有启用书源的「还能不能用」，并把结果写回书源。
//
// 规则（用户要的）：
//   - 连续失败 2 次 → 自动删除（成功一次就清零，避免误杀偶尔抽风的源）；
//   - 检测在后台跑：切 App / 锁屏都继续，通知栏显示「已检 x/n · 正常 a · 失败 b」；
//   - 删掉之后可以「撤销」，恢复的书源失败计数归零。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/import_foreground.dart';
import '../../source/models.dart';
import '../../source/online_repo.dart';
import '../../source/source_health.dart';
import '../../source/source_store.dart';
import '../widgets/cute.dart';

class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({super.key, required this.store});
  final SourceStore store;

  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  static const _keywordPresets = ['西游记', '斗破苍穹', '诡秘之主'];

  late final OnlineRepo _repo = OnlineRepo(
    store: widget.store,
    concurrency: 6,
    perSourceTimeout: const Duration(seconds: 10),
  );
  late final SourceHealthController _controller;
  final _query = TextEditingController(text: _keywordPresets.first);
  int _concurrency = 6;
  bool _autoRemove = true;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _controller = SourceHealthController(
      store: widget.store,
      checker: _check,
      concurrency: _concurrency,
      autoRemove: _autoRemove,
      onProgress: _onProgress,
    );
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _repo.dispose();
    _query.dispose();
    // 页面被关掉时别把服务留在那儿
    if (_controller.running) {
      _controller.cancel();
      unawaited(ImportForeground.stop());
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 检测一个源：能搜到结果才算通过。
  Future<SourceCheckOutcome> _check(BookSource source, String keyword) async {
    final timeout = Duration(seconds: _timeoutSeconds);
    SourceSearchResult r;
    try {
      r = await _repo
          .searchOne(source, keyword)
          .timeout(
            timeout,
            onTimeout: () => SourceSearchResult(
              source: source,
              error: '超时（${timeout.inSeconds}s 无响应）',
            ),
          );
    } catch (e) {
      return SourceCheckOutcome(ok: false, error: '$e');
    }
    if (r.error != null) {
      return SourceCheckOutcome(ok: false, error: r.error, elapsedMs: r.elapsedMs);
    }
    if (r.books.isEmpty) {
      return SourceCheckOutcome(
        ok: false,
        error: '搜不到结果（规则可能失效）',
        elapsedMs: r.elapsedMs,
      );
    }
    return SourceCheckOutcome(ok: true, elapsedMs: r.elapsedMs);
  }

  int get _timeoutSeconds => _repo.perSourceTimeout.inSeconds;

  void _onProgress(SourceHealthController c) {
    final now = DateTime.now();
    final finished = !c.running;
    if (!finished && now.difference(_lastNotify).inMilliseconds < 1500) return;
    _lastNotify = now;
    if (finished) {
      unawaited(ImportForeground.stop());
      return;
    }
    unawaited(
      ImportForeground.updateTask(
        title: '嘤阅 · 正在检测书源',
        text: c.progressText,
      ),
    );
  }

  Future<void> _run() async {
    final keyword = _query.text.trim();
    if (keyword.isEmpty) {
      _snack('先填一个测试书名');
      return;
    }
    if (widget.store.enabledCount == 0) {
      _snack('没有启用的书源可检测');
      return;
    }
    _controller.autoRemove = _autoRemove;
    _controller.concurrency = _concurrency;
    // 后台保活：通知权限没给也能跑，只是看不到进度
    await ImportForeground.ensurePermission();
    final ok = await ImportForeground.startTask(
      title: '嘤阅 · 正在检测书源',
      text: '准备中… 共 ${widget.store.enabledCount} 个源',
    );
    if (!mounted) return;
    if (!ok) {
      _snack('通知栏服务没起来（${ImportForeground.lastError ?? '未知原因'}），仍会继续检测');
    } else {
      _snack('已开始，切到后台也会继续');
    }
    await _controller.run(keyword);
    if (!mounted) return;
    final removed = _controller.removedCount;
    if (removed > 0) {
      _snack('体检完成：自动删除 $removed 个连续失败的书源，可点「撤销删除」找回');
    } else {
      _snack('体检完成：${_controller.progressText}');
    }
  }

  void _undo() {
    final n = _controller.undoRemovals();
    if (n > 0) _snack('已恢复 $n 个书源，失败计数已清零');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = _controller;
    final total = c.running || c.total > 0 ? c.total : widget.store.enabledCount;
    final progress = total == 0 ? 0.0 : (c.checkedCount / total).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书源体检'),
        actions: [
          if (c.removedCount > 0)
            TextButton.icon(
              onPressed: _undo,
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: Text('撤销删除 ${c.removedCount}'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.health_and_safety_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    const Text(
                      '检测规则',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '用测试书名挨个搜一遍启用中的书源：搜到结果算通过，'
                  '超时 / 报错 / 空结果算失败。\n'
                  '同一个源连续失败 ${c.autoRemoveAfter} 次会自动删除（成功一次就清零）。'
                  '检测走通知栏后台，切走 App 也会继续跑。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.7,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  enabled: !c.running,
                  decoration: const InputDecoration(
                    labelText: '测试书名 / 作者',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final k in _keywordPresets)
                      ActionChip(
                        label: Text(k, style: const TextStyle(fontSize: 11.5)),
                        onPressed: c.running
                            ? null
                            : () => setState(() => _query.text = k),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '并发',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    for (final n in [2, 4, 6, 8])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('$n', style: const TextStyle(fontSize: 11.5)),
                          selected: _concurrency == n,
                          onSelected: c.running
                              ? null
                              : (_) => setState(() => _concurrency = n),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _autoRemove,
                  onChanged: c.running
                      ? null
                      : (v) => setState(() => _autoRemove = v),
                  title: const Text(
                    '连续失败自动删除',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: Text(
                    '关掉后只记失败次数，不删源',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: c.running ? null : _run,
                  icon: Icon(
                    c.running ? Icons.hourglass_top_rounded : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(c.running ? '检测中…' : '开始体检'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: c.running ? c.cancel : null,
                child: const Text('停止'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (c.checkedCount > 0 || c.running) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: progress, minHeight: 8),
            ),
            const SizedBox(height: 8),
            Text(
              c.progressText,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
          ],
          if (c.entries.isEmpty && !c.running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '还没有检测结果。\n建议先确认网络可用，再点「开始体检」。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.8,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final e in c.entries.reversed) _entryTile(e, scheme),
        ],
      ),
    );
  }

  Widget _entryTile(SourceHealthEntry e, ColorScheme scheme) {
    final (icon, color, tail) = switch (e.verdict) {
      SourceVerdict.ok => (Icons.check_circle, Colors.green, '正常'),
      SourceVerdict.failed => (
        Icons.error_outline,
        scheme.error,
        '失败 ${e.failCount}/${_controller.autoRemoveAfter}',
      ),
      SourceVerdict.removed => (
        Icons.delete_outline,
        scheme.error,
        '已自动删除',
      ),
    };
    final subtitle = [
      if (e.verdict == SourceVerdict.ok) '${e.elapsedMs} ms',
      if (e.error != null) e.error!,
      if (e.verdict == SourceVerdict.failed) '再失败一次就删',
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, size: 20, color: color),
      title: Text(
        e.source.bookSourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
      trailing: Text(
        tail,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
