// 每天第一次打开 App：从「源仓库」拉 24 小时内的新合集 → 并入书源 → 全量体检。
//
// 规则（用户要的）：
//   - 每天只自动跑一次（同一天再开 App 不重复）；
//   - 只看 24 小时内新发布/更新的合集，已经处理过的合集 id 记下来，不重复下载；
//   - 新书源并入后立刻跑一次全量体检，连续失败 2 次的自动删除；
//   - 整个过程走前台服务，通知栏能看到进度，切 App 也不停。
import 'dart:async';

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
    this.skippedDeleted = 0,
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

  /// 今天被删过、这次没有再并入的数量。
  final int skippedDeleted;
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
      if (skippedDeleted > 0) '跳过 $skippedDeleted 个今天删过的',
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
    List<SourceHubClient>? clients,
    this.checker,
    this.window = const Duration(hours: 24),
    this.bootstrapWindow = const Duration(days: 2),
    this.bootstrapFallbackCount = 3,
    this.maxSourcesPerRun = 400,
    this.keyword = '西游记',
    this.healthConcurrency = 3,
    this.maxChecksPerRun = 300,
  }) : _clients =
           clients ??
           (client != null
               ? [client]
               : SourceHubClient.fromTargets(prefs.sourceHubUrls));

  final SourceStore store;
  final AppPrefs prefs;
  final List<SourceHubClient> _clients;

  /// 体检用的检测函数；为空时按线上书源（OnlineRepo）实时搜索。
  final SourceChecker? checker;

  /// 只认这个时间窗内发布的条目（固定 24 小时：超过一天的都不要）。
  final Duration window;

  /// 书架里一个源都没有时（新机 / 刚清空）的引导窗口：放宽到 2 天。
  final Duration bootstrapWindow;

  /// 引导时连 2 天内都没有新条目，就无条件拿最新的这几条，保证能用。
  final int bootstrapFallbackCount;

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
    _running = true;

    void tell(String text) {
      onProgress?.call(text);
      unawaited(ImportForeground.updateTask(title: '嘤阅 · 正在同步书源', text: text));
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
      var blocked = 0;
      final addedItems = <SourceSyncLogItem>[];
      var hubError = '';
      if (fetchNew) {
        // 一个源都没有（新机 / 刚清空）：先按「2 天」宽窗口补一份基础书源，
        // 否则严格 24 小时会让新设备一本书都搜不到。
        final bootstrap = store.sources.isEmpty;
        if (bootstrap) tell('书架还没有书源，先补一批基础源…');
        // 多个源仓库：一个个来，单个站点挂了不影响其它站点
        var hubIndex = 0;
        for (final hub in _clients) {
          if (added + updated >= maxSourcesPerRun) break;
          hubIndex++;
          final prefix = _clients.length > 1
              ? '[$hubIndex/${_clients.length} ${hub.label}] '
              : '';
          try {
            tell('$prefix检查有没有新条目…');
            final items = await hub.latest();
            // 日常：固定 24 小时窗口；引导：放宽到 2 天
            final cutoff = DateTime.now().subtract(
              bootstrap ? bootstrapWindow : window,
            );
            var fresh = items.where((i) {
              final key = _seenKey(hub, i.id);
              final prev = seen[key];
              if (prev == null) return i.isNewerThan(cutoff);
              // 处理过的条目：时间变新了说明作者更新了内容
              return i.time != null &&
                  i.time!.millisecondsSinceEpoch > prev + 60000;
            }).toList();
            // 2 天内也没有新条目：无条件拿最新的几条，保证新机能用
            if (bootstrap && fresh.isEmpty && items.isNotEmpty) {
              fresh = items.take(bootstrapFallbackCount).toList();
              tell('$prefix最近没有新条目，先拿最新的 ${fresh.length} 条');
            }
            for (final item in fresh) {
              if (added + updated >= maxSourcesPerRun) break;
              tell('$prefix正在下载《${item.title}》…');
              final key = _seenKey(hub, item.id);
              try {
                final list = await hub.collection(item.id);
                final stamp =
                    item.time?.millisecondsSinceEpoch ??
                    DateTime.now().millisecondsSinceEpoch;
                if (list.isEmpty) {
                  seen[key] = stamp;
                  continue;
                }
                final rep = store.addAllDetailed(BookSource.listFromJson(list));
                added += rep.added;
                updated += rep.updated;
                blocked += rep.blocked;
                collections++;
                seen[key] = stamp;
                for (final s in rep.addedSources) {
                  addedItems.add(
                    SourceSyncLogItem(
                      name: s.bookSourceName,
                      url: s.bookSourceUrl,
                      collection: item.title,
                    ),
                  );
                }
                tell(
                  '$prefix已并入 $added 个新书源（$collections 个合集）'
                  '${blocked > 0 ? ' · 跳过 $blocked 个今天删过的' : ''}',
                );
              } catch (_) {
                // 单条失败不影响后面的
              }
            }
          } catch (e) {
            hubError = hubError.isEmpty ? e.toString() : '$hubError；$e';
          }
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
          error: hubError.isEmpty ? null : hubError,
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
          onProgress: (c) =>
              tell(c.running ? '体检中：${c.progressText}' : c.progressText),
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
        skippedDeleted: blocked,
        addedSources: added,
        updatedSources: updated,
        checked: checked,
        healthy: healthy,
        failed: failed,
        removed: removed,
        error: hubError.isEmpty ? null : hubError,
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
      final r = await repo
          .searchOne(source, key)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => SourceSearchResult(source: source, error: '超时'),
          );
      if (r.error != null) {
        return SourceCheckOutcome(
          ok: false,
          error: r.error,
          elapsedMs: r.elapsedMs,
        );
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

  /// 去重键：`站点#id`（不同源仓库的 id 会撞，必须带上站点）。
  static String _seenKey(SourceHubClient hub, int id) => '${hub.hostKey}#$id';

  /// 记录格式：`站点#id:时间戳`，逗号分隔。
  ///
  /// 兼容老格式：`id:时间戳`（那时候只有一个默认源仓库）→ 归到 yckceo 名下。
  static Map<String, int> _parseSeen(String raw) {
    final out = <String, int>{};
    for (final part in raw.split(',')) {
      final item = part.trim();
      if (item.isEmpty) continue;
      final bits = item.split(':');
      if (bits.isEmpty) continue;
      final head = bits.first.trim();
      final stamp = bits.length > 1 ? (int.tryParse(bits[1]) ?? 0) : 0;
      if (head.contains('#')) {
        out[head] = stamp;
        continue;
      }
      final legacyId = int.tryParse(head);
      if (legacyId != null) {
        out['www.yckceo.com#$legacyId'] = stamp;
      }
    }
    return out;
  }

  static String _joinSeen(Map<String, int> seen) {
    final entries = seen.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    // 只留最近 500 条，够用了，避免 prefs 无限膨胀
    final keep = entries.length > 500
        ? entries.sublist(entries.length - 500)
        : entries;
    return keep.map((e) => '${e.key}:${e.value}').join(',');
  }
}
