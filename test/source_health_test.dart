// 书源体检的回归测试：连续失败自动删除 / 成功清零 / 撤销 / 只测启用源。
//
// 这里不碰网络：检测函数由测试注入，跑得快也稳定。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/models.dart';
import 'package:sakura_read/src/source/source_health.dart';
import 'package:sakura_read/src/source/source_store.dart';

BookSource _src(String name, {bool enabled = true, int failCount = 0}) =>
    BookSource(
      bookSourceUrl: 'https://$name.example.com',
      bookSourceName: name,
      enabled: enabled,
      searchUrl: 'https://$name.example.com/search?key={{key}}',
      healthFailCount: failCount,
    );

/// 按 URL 给结果的假检测器：每个源一个结果队列，用完之后一直返回最后一个。
SourceChecker _checker(Map<String, List<SourceCheckOutcome>> plan) {
  final used = <String, int>{};
  return (source, keyword) async {
    final list = plan[source.bookSourceUrl] ?? const [];
    if (list.isEmpty) return const SourceCheckOutcome(ok: false, error: '没计划');
    final i = used[source.bookSourceUrl] ?? 0;
    used[source.bookSourceUrl] = i + 1;
    return list[i.clamp(0, list.length - 1)];
  };
}

SourceCheckOutcome get _fail => const SourceCheckOutcome(ok: false, error: '超时');
SourceCheckOutcome get _ok => const SourceCheckOutcome(ok: true, elapsedMs: 120);

void main() {
  test('连续失败两次自动删除，成功一次就清零', () async {
    final a = _src('a');
    final b = _src('b');
    final store = SourceStore(initial: [a, b]);
    final controller = SourceHealthController(
      store: store,
      checker: _checker({
        a.bookSourceUrl: [_fail, _fail],
        b.bookSourceUrl: [_fail, _ok],
      }),
      concurrency: 2,
    );

    await controller.run('西游记');
    expect(store.byUrl(a.bookSourceUrl)!.healthFailCount, 1, reason: '第一次失败只记账');
    expect(store.byUrl(a.bookSourceUrl), isNotNull, reason: '还没到 2 次，不该删');
    expect(store.byUrl(b.bookSourceUrl)!.healthFailCount, 1);

    // 第二次体检：a 再失败 → 删；b 成功 → 清零
    await controller.run('西游记');
    expect(store.byUrl(a.bookSourceUrl), isNull, reason: '连续两次失败应自动删除');
    expect(controller.removedCount, 1);
    expect(store.byUrl(b.bookSourceUrl)!.healthFailCount, 0, reason: '成功应清零');
    expect(store.byUrl(b.bookSourceUrl)!.healthError, isNull);

    final removedEntry = controller.entries.firstWhere(
      (e) => e.source.bookSourceUrl == a.bookSourceUrl && e.verdict == SourceVerdict.removed,
    );
    expect(removedEntry.failCount, 2);
  });

  test('关掉自动删除后只记账不删源', () async {
    final a = _src('a');
    final store = SourceStore(initial: [a]);
    final controller = SourceHealthController(
      store: store,
      checker: _checker({
        a.bookSourceUrl: [_fail],
      }),
      autoRemove: false,
    );
    await controller.run('西游记');
    await controller.run('西游记');
    expect(store.byUrl(a.bookSourceUrl), isNotNull);
    expect(store.byUrl(a.bookSourceUrl)!.healthFailCount, 2);
    expect(controller.removedCount, 0);
  });

  test('撤销删除能找回书源，并把失败计数清零', () async {
    final a = _src('a', failCount: 1);
    final store = SourceStore(initial: [a]);
    final controller = SourceHealthController(
      store: store,
      checker: _checker({
        a.bookSourceUrl: [_fail],
      }),
    );

    await controller.run('西游记');
    expect(store.byUrl(a.bookSourceUrl), isNull);
    expect(controller.removedCount, 1);

    final restored = controller.undoRemovals();
    expect(restored, 1);
    final back = store.byUrl(a.bookSourceUrl);
    expect(back, isNotNull);
    expect(back!.healthFailCount, 0, reason: '恢复后不该立刻又被删');
    expect(controller.removedCount, 0);
    expect(
      controller.entries.every((e) => e.verdict != SourceVerdict.removed),
      isTrue,
    );
  });

  test('检测函数抛异常也只算一次失败，不会中断整轮', () async {
    final a = _src('a');
    final b = _src('b');
    final store = SourceStore(initial: [a, b]);
    final controller = SourceHealthController(
      store: store,
      checker: (source, keyword) async {
        if (source.bookSourceUrl == a.bookSourceUrl) {
          throw StateError('boom');
        }
        return _ok;
      },
      concurrency: 2,
    );

    await controller.run('西游记');
    expect(controller.checkedCount, 2, reason: '两个源都要有结果');
    expect(store.byUrl(a.bookSourceUrl)!.healthFailCount, 1);
    expect(store.byUrl(a.bookSourceUrl)!.healthError, contains('boom'));
    expect(store.byUrl(b.bookSourceUrl)!.healthFailCount, 0);
  });

  test('停用的书源不参与体检', () async {
    final a = _src('a', enabled: false);
    final b = _src('b');
    final store = SourceStore(initial: [a, b]);
    final controller = SourceHealthController(
      store: store,
      checker: _checker({
        a.bookSourceUrl: [_fail],
        b.bookSourceUrl: [_ok],
      }),
    );

    await controller.run('西游记');
    expect(controller.total, 1);
    expect(controller.checkedCount, 1);
    expect(store.byUrl(a.bookSourceUrl)!.healthFailCount, 0);
    expect(store.byUrl(a.bookSourceUrl), isNotNull);
  });

  test('健康字段能存进 JSON 再读回来（跨启动累计才有效）', () {
    final a = _src('a', failCount: 1).copyWith(
      healthCheckedAt: 1234567890,
      healthError: '超时',
    );
    final json = a.toJson();
    final back = BookSource.fromJson(json);
    expect(back.healthFailCount, 1);
    expect(back.healthCheckedAt, 1234567890);
    expect(back.healthError, '超时');

    // 清零后不该把脏字段写回去
    final clean = back.copyWith(healthFailCount: 0, clearHealthError: true);
    expect(clean.toJson().containsKey('healthError'), isFalse);
  });
}
