// 源仓库抓取 + 每日自动同步的回归测试（不联网，全部用 MockClient / 假检测器）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/source/daily_source_sync.dart';
import 'package:sakura_read/src/source/source_health.dart';
import 'package:sakura_read/src/source/source_hub.dart';
import 'package:sakura_read/src/source/source_store.dart';

/// 首页片段（结构照抄线上：h2 > a + p.m-right）。
String _indexHtml({String time = '3小时前', int id = 1341}) => '''
<div class="layui-card-body">
  <div class="ylist">
    <h2><a href="/yuedu/shuyuans/content/id/$id.html">自用整理·精品书源</a>
      <p class="m-right" style="top: 3px;">$time</p>
    </h2>
    <span class="layui-badge-rim">源数量:2</span>
  </div>
</div>
''';

List<Map<String, dynamic>> _twoSources() => [
  {
    'bookSourceUrl': 'https://a.example.com',
    'bookSourceName': 'A 站',
    'searchUrl': 'https://a.example.com/s?key={{key}}',
  },
  {
    'bookSourceUrl': 'https://b.example.com',
    'bookSourceName': 'B 站',
    'searchUrl': 'https://b.example.com/s?key={{key}}',
  },
];

void main() {
  group('时间解析', () {
    final now = DateTime(2026, 11, 22, 14, 0);

    test('相对时间', () {
      expect(parseHubTime('刚刚', now: now), now);
      expect(parseHubTime('2小时前', now: now), now.subtract(const Duration(hours: 2)));
      expect(parseHubTime('3天前', now: now), now.subtract(const Duration(days: 3)));
      expect(parseHubTime('昨天', now: now), now.subtract(const Duration(days: 1)));
    });

    test('绝对时间：月/日 与 年-月-日', () {
      expect(parseHubTime('11/12 11:41', now: now), DateTime(2026, 11, 12, 11, 41));
      expect(parseHubTime('2025-06-01 08:00', now: now), DateTime(2025, 6, 1, 8));
    });

    test('看不懂的返回 null', () {
      expect(parseHubTime('', now: now), isNull);
      expect(parseHubTime('很久以前', now: now), isNull);
    });
  });

  group('首页解析', () {
    test('抓到 id / 标题 / json 地址 / 时间 / 源数量', () {
      final items = parseHubIndex(_indexHtml(), now: DateTime(2026, 11, 22, 14));
      expect(items, hasLength(1));
      final it = items.first;
      expect(it.id, 1341);
      expect(it.title, '自用整理·精品书源');
      expect(it.jsonUrl, 'https://www.yckceo.com/yuedu/shuyuans/json/id/1341.json');
      expect(it.sourceCount, 2);
      expect(it.time, isNotNull);
    });

    test('没有时间段的条目不会崩（time 为 null）', () {
      final html = '<h2><a href="/yuedu/shuyuans/content/id/9.html">x</a></h2>';
      final items = parseHubIndex(html);
      expect(items, hasLength(1));
      expect(items.first.time, isNull);
    });
  });

  group('每日同步', () {
    late SourceStore store;
    late AppPrefs prefs;

    setUp(() {
      store = SourceStore(initial: []);
      prefs = AppPrefs();
    });

    SourceHubClient clientFor({
      required String time,
      required List<Map<String, dynamic>> sources,
      List<String>? requests,
    }) {
      return SourceHubClient(
        client: MockClient((req) async {
          requests?.add(req.url.toString());
          if (req.url.path.contains('/yuedu/shuyuans/index.html')) {
            return http.Response.bytes(utf8.encode(_indexHtml(time: time)), 200,
                headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (req.url.path.endsWith('.json')) {
            return http.Response.bytes(utf8.encode(jsonEncode(sources)), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return http.Response('nope', 404);
        }),
      );
    }

    test('24 小时内的新合集会被并入，并接着体检', () async {
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(time: '3小时前', sources: _twoSources()),
        checker: (s, k) async => const SourceCheckOutcome(ok: true, elapsedMs: 50),
      );

      final report = await sync.runIfDue();
      expect(report.ran, isTrue);
      expect(report.newCollections, 1);
      expect(report.addedSources, 2);
      expect(store.sources, hasLength(2));
      expect(report.checked, 2);
      expect(report.healthy, 2);
      expect(report.removed, 0);
      // 同步过就记下日期与合集 id
      expect(prefs.lastSourceSyncDay, DailySourceSync.dayKey(DateTime.now()));
      expect(prefs.syncedHubIds, contains('1341'));
    });

    test('非首次运行：超过 24 小时的合集不导入', () async {
      // 模拟昨天同步过 → 走日常 24h 窗口
      prefs.setSourceSyncDay('2026-11-21');
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(time: '5天前', sources: _twoSources()),
        checker: (s, k) async => const SourceCheckOutcome(ok: true),
      );
      final report = await sync.runIfDue();
      expect(report.ran, isTrue);
      expect(report.newCollections, 0);
      expect(store.sources, isEmpty);
    });

    test('同一天第二次打开不再自动跑；force 也不重复下载已处理合集', () async {
      final requests = <String>[];
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(
          time: '3小时前',
          sources: _twoSources(),
          requests: requests,
        ),
        checker: (s, k) async => const SourceCheckOutcome(ok: true),
      );
      await sync.runIfDue();
      final second = await sync.runIfDue();
      expect(second.ran, isFalse, reason: '同一天不重复');

      final forced = await sync.runIfDue(force: true);
      expect(forced.ran, isTrue);
      expect(forced.newCollections, 0, reason: '合集 id 已记录，不该再下');
    });

    test('体检连续失败 2 次会删源（跨两次运行累计）', () async {
      var pass = 0;
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(time: '1小时前', sources: _twoSources()),
        checker: (s, k) async {
          pass++;
          return const SourceCheckOutcome(ok: false, error: '超时');
        },
      );
      final first = await sync.runIfDue();
      expect(first.removed, 0, reason: '第一次只是记一次失败');
      expect(store.sources, hasLength(2));

      prefs.setSourceSyncDay('');
      final second = await sync.runIfDue();
      expect(second.checked, 2);
      expect(second.removed, 2, reason: '第二次仍失败 → 自动删除');
      expect(store.sources, isEmpty);
    });

    test('第一次运行会放宽到 7 天，把三天前的合集也捞进来', () async {
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(time: '3天前', sources: _twoSources()),
        checker: (s, k) async => const SourceCheckOutcome(ok: true),
      );
      final report = await sync.runIfDue();
      expect(report.newCollections, 1);
      expect(store.sources, hasLength(2));
    });

    test('关掉开关后 isDue 为 false', () {
      prefs.setAutoSyncSources(false);
      final sync = DailySourceSync(
        store: store,
        prefs: prefs,
        client: clientFor(time: '1小时前', sources: _twoSources()),
      );
      expect(sync.isDue(), isFalse);
    });
  });
}
