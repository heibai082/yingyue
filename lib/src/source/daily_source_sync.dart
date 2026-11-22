// 每天第一次打开 App：从「源仓库」拉 24 小时内的新合集 → 并入书源 → 全量体检。
//
// 规则（用户要的）：
//   - 每天只自动跑一次（同一天再开 App 不重复）；
//   - 只看 24 小时内新发布/更新的合集，已经处理过的合集 id 记下来，不重复下载；
//   - 新书源并入后立刻跑一次全量体检，连续失败 2 次的自动删除；
//   - 整个过程走前台服务，通知栏能看到进度，切 App 也不停。
import 'dart:async';
import 'dart:convert';

import '../data/prefs.dart';
import '../data/app_activity.dart';
import '../platform/import_foreground.dart';
import 'models.dart';
import 'online_repo.dart';
import 'source_health.dart';
import 'source_hub.dart';
import 'source_store.dart';
import 'source_sync_log.dart';

/// 一次每日同步的结果（给界面提示用）。
class DailySourceSyncReport {
  const DailySourceSyncReport({
    required this.ran,
    this.newCollections = 0,
    this.addedSources = 0,
    this.updatedSources = 0,
    this.checked = 0,
    this.healthy = 0,
    this.failed = 0,
    this.removed = 0,
    this.error,
    this.log,
  });

  /// 本次是否真的执行了（false = 今天已经跑过 / 用户关了开关）。
  final bool ran;

  final int newCollections;
  final int addedSources;
  final int updatedSources;
  final int checked;
  final int healthy;
  final int failed;
  final int removed;
  final String? error;

  /// 本次新增明细（点了「查看新增」用）。
  final SourceSyncLog? log;

  String get summary {
    if (!ran) return '今天已经同步过了';
    if (error != null) return '书源同步失败：$error';
    final parts = <String>[
      if (newCollections > 0) '新增合集 $newCollections 个',
      if (addedSources > 0) '并入书源 $addedSources 个',
      if (updatedSources > 0) '更新 $updatedSources 个',
      if (checked > 0) '体检 $checked 个（正常 $healthy / 失败 $failed）',
      if (removed > 0) '自动删除 $removed 个',
    ];
    return parts.isEmpty ? '书源没有变化，体检也没发现问题' : parts.join(' · ');
  }
}

class DailySourceSync {
  DailySourceSync({
    required this.store,
    required this.prefs,
    SourceHubClient? client,
    this.checker,
    this.window = const Duration(hours: 24),
    this.firstRunWindow = const Duration(days: 7),
    this.maxSourcesPerRun = 400,
    this.keyword = '西游记',
    this.healthConcurrency = 3,
    this.maxChecksPerRun = 300,
  }) : _client = client ?? SourceHubClient();

  final SourceStore store;
  final AppPrefs prefs;
  final SourceHubClient _client;

  /// 体检用的检测函数；为空时按线上书源（OnlineRepo）实时搜索。
  final SourceChecker? checker;

  /// 只认这个时间窗内发布的合集（日常）。
  final Duration window;

  /// 第一次跑（从没同步过）时放宽到这个窗口，先把有价值的源捞进来。
  final Duration firstRunWindow;

  /// 单次最多并入多少个书源（防止一口气塞进几千个死源）。
  final int maxSourcesPerRun;

  /// 体检用的测试书名。
  final String keyword;

  final int healthConcurrency;

  /// 单轮体检最多检多少个（按最久没检过的顺序轮转，限制对手机的影响）。
  final int maxChecksPerRun;

  bool _running = false;
  bool get running => _running;

  static String dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 今天是否已经跑过 / 是否被关掉了。
  bool isDue({DateTime? now}) {
    if (!prefs.autoSyncSources) return false;
    return prefs.lastSourceSyncDay != dayKey(now ?? DateTime.now());
  }

  /// 按需执行（[force] = 用户手动点「立即同步」，忽略"今天跑过"）。
  ///
  /// [fetchNew] / [healthCheck] 可以分开跑：界面上「同步源仓库」和「书源体检」
  /// 是两个独立按钮，日常自动任务才两件事都做。
  Future<DailySourceSyncReport> runIfDue({
    bool force = false,
    bool fetchNew = true,
    bool healthCheck = true,
    void Function(String text)? onProgress,
  }) async {
    if (_running) return const DailySourceSyncReport(ran: false);
    final today = dayKey(DateTime.now());
    if (!force && !isDue()) {
      return const DailySourceSyncReport(ran: false);
    }
    // 注意：必须在「占坑」之前判断，否则 lastSourceSyncDay 已经被写成今天
    final firstRun = prefs.lastSourceSyncDay.isEmpty;
    _running = true;

    void tell(String text) {
      onProgress?.call(text);
      unawaited(
        ImportForeground.updateTask(title: '嘤阅 · 正在同步书源', text: text),
      );
    }

    try {
      // 先占坑：中途被系统杀掉也不会同一小时内反复重跑
      prefs.setSourceSyncDay(today);
      await ImportForeground.startTask(
        title: '嘤阅 · 正在同步书源',
        text: fetchNew ? '检查源仓库有没有新合集…' : '准备体检…',
      );

      final seen = _parseSeen(prefs.syncedHubIds);
      var collections = 0;
      var added = 0;
      var updated = 0;
      final addedItems = <SourceSyncLogItem>[];
      String? hubError;
      if (fetchNew) {
        try {
          final items = await _client.latest();
          // 第一次跑（没有同步过）放宽到 7 天，先把有价值的源捞进来；
          // 之后只看 24 小时内「新增」或「更新过」的合集。
          final cutoff = DateTime.now().subtract(
            firstRun ? firstRunWindow : window,
          );
          final fresh = items.where((i) {
            final prev = seen[i.id];
            if (prev == null) return i.isNewerThan(cutoff);
            // 处理过的合集：时间变新了说明作者更新了内容
            return i.time != null &&
                i.time!.millisecondsSinceEpoch > prev + 60000;
          }).toList();
          for (final item in fresh) {
            if (added + updated >= maxSourcesPerRun) break;
            tell('正在下载《${item.title}》…');
            try {
              final list = await _client.collection(item.id);
              final stamp = item.time?.millisecondsSinceEpoch ??
                  DateTime.now().millisecondsSinceEpoch;
              if (list.isEmpty) {
                seen[item.id] = stamp;
                continue;
              }
              final rep = store.addAllDetailed(BookSource.listFromJson(list));
              added += rep.added;
              updated += rep.updated;
              collections++;
              seen[item.id] = stamp;
              for (final s in rep.addedSources) {
                addedItems.add(
                  SourceSyncLogItem(
                    name: s.bookSourceName,
                    url: s.bookSourceUrl,
                    collection: item.title,
                  ),
                );
              }
              tell('已并入 $added 个新书源（$collections 个合集）');
            } catch (_) {
              // 单个合集失败不影响后面的
            }
          }
        } catch (e) {
          hubError = e.toString();
        }
      }

      // 记录「这次新增了哪些」——重启后还能翻
      SourceSyncLog? log;
      if (fetchNew) {
        log = SourceSyncLog(
          at: DateTime.now(),
          items: addedItems,
          updated: updated,
          collections: collections,
          error: hubError,
        );
        await log.save();
      }

      // 拉完就体检：连续失败 2 次的会自动删除
      var checked = 0;
      var healthy = 0;
      var failed = 0;
      var removed = 0;
      if (healthCheck && store.enabledCount > 0) {
        OnlineRepo? repo;
        final healthChecker =
            checker ??
            (BookSource source, String key) {
              repo ??= OnlineRepo(
                store: store,
                concurrency: healthConcurrency,
                perSourceTimeout: const Duration(seconds: 8),
              );
              return _check(repo!, source, key);
            };
        final controller = SourceHealthController(
          store: store,
          concurrency: healthConcurrency,
          maxChecksPerRun: maxChecksPerRun,
          // 在看书就让路：不占网、不占 CPU，退出阅读页自动继续
          shouldPause: () => kReaderActive.value,
          checker: healthChecker,
          onProgress: (c) => tell(c.running ? '体检中：${c.progressText}' : c.progressText),
        );
        tell('开始体检 ${store.enabledCount} 个书源…');
        await controller.run(keyword);
        checked = controller.checkedCount;
        healthy = controller.okCount;
        failed = controller.failedCount + controller.removedCount;
        removed = controller.removedCount;
        repo?.dispose();
        controller.dispose();
      }

      prefs.setSyncedHubIds(_joinSeen(seen));
      await store.flush();
      await prefs.flush();
      return DailySourceSyncReport(
        ran: true,
        newCollections: collections,
        addedSources: added,
        updatedSources: updated,
        checked: checked,
        healthy: healthy,
        failed: failed,
        removed: removed,
        error: hubError,
        log: log,
      );
    } catch (e) {
      return DailySourceSyncReport(ran: true, error: e.toString());
    } finally {
      _running = false;
      unawaited(ImportForeground.stop());
    }
  }

  /// 体检一个源：搜到结果才算通过。
  Future<SourceCheckOutcome> _check(
    OnlineRepo repo,
    BookSource source,
    String key,
  ) async {
    try {
      final r = await repo.searchOne(source, key).timeout(
        const Duration(seconds: 10),
        onTimeout: () => SourceSearchResult(source: source, error: '超时'),
      );
      if (r.error != null) {
        return SourceCheckOutcome(ok: false, error: r.error, elapsedMs: r.elapsedMs);
      }
      if (r.books.isEmpty) {
        return SourceCheckOutcome(
          ok: false,
          error: '搜不到结果',
          elapsedMs: r.elapsedMs,
        );
      }
      return SourceCheckOutcome(ok: true, elapsedMs: r.elapsedMs);
    } catch (e) {
      return SourceCheckOutcome(ok: false, error: e.toString());
    }
  }

  /// 记录格式：`id:时间戳`，逗号分隔（兼容旧格式纯 id）。
  static Map<int, int> _parseSeen(String raw) {
    final out = <int, int>{};
    for (final part in raw.split(',')) {
      final item = part.trim();
      if (item.isEmpty) continue;
      final bits = item.split(':');
      final id = int.tryParse(bits.first);
      if (id == null) continue;
      out[id] = bits.length > 1 ? (int.tryParse(bits[1]) ?? 0) : 0;
    }
    return out;
  }

  static String _joinSeen(Map<int, int> seen) {
    final entries = seen.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    // 只留最近 500 条，够用了，避免 prefs 无限膨胀
    final keep = entries.length > 500
        ? entries.sublist(entries.length - 500)
        : entries;
    return keep.map((e) => '${e.key}:${e.value}').join(',');
  }
}
