// 「今天删过的书源不要再被同步加回来」的回归测试。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/models.dart';
import 'package:sakura_read/src/source/source_store.dart';

BookSource _src(String host) => BookSource(
  bookSourceUrl: 'https://$host/',
  bookSourceName: host,
);

void main() {
  test('当天删掉的源，同步（addAll）不会再加回来', () {
    var now = DateTime(2026, 11, 22, 10);
    final store = SourceStore(clock: () => now);
    store.addAll([_src('a.com'), _src('b.com')]);
    expect(store.sources, hasLength(2));

    store.remove('https://a.com/');
    expect(store.sources, hasLength(1));
    expect(store.isDeletedToday('https://a.com/'), isTrue);
    expect(store.deletedTodayCount, 1);

    // 同步源仓库：合集里又有 a.com，当天不该加回来
    final r = store.addAllDetailed([_src('a.com'), _src('c.com')]);
    expect(r.added, 1, reason: '只加没删过的 c.com');
    expect(r.blocked, 1, reason: 'a.com 被拦下');
    expect(store.byUrl('https://a.com/'), isNull);
    expect(store.byUrl('https://c.com/'), isNotNull);
  });

  test('第二天就能正常加回来', () {
    var now = DateTime(2026, 11, 22, 23, 50);
    final store = SourceStore(clock: () => now);
    store.addAll([_src('a.com')]);
    store.remove('https://a.com/');

    now = DateTime(2026, 11, 23, 0, 10);
    expect(store.isDeletedToday('https://a.com/'), isFalse);
    final r = store.addAllDetailed([_src('a.com')]);
    expect(r.added, 1);
    expect(r.blocked, 0);
  });

  test('撤销删除会清掉「今天删过」的标记', () {
    var now = DateTime(2026, 11, 22, 12);
    final store = SourceStore(clock: () => now);
    final a = _src('a.com');
    store.addAll([a]);
    store.remove(a.bookSourceUrl);

    final n = store.restoreSources([a]);
    expect(n, 1);
    expect(store.byUrl(a.bookSourceUrl), isNotNull);
    expect(store.isDeletedToday(a.bookSourceUrl), isFalse);
    expect(store.deletedTodayCount, 0);
  });

  test('批量删除也记标记', () {
    var now = DateTime(2026, 11, 22, 12);
    final store = SourceStore(clock: () => now);
    store.addAll([_src('a.com'), _src('b.com')]);
    final removed = store.removeMany(['https://a.com/', 'https://b.com/']);
    expect(removed, 2);
    expect(store.deletedTodayCount, 2);
    expect(store.addAllDetailed([_src('a.com')]).blocked, 1);
  });

  test('没删过的源不受影响', () {
    var now = DateTime(2026, 11, 22, 12);
    final store = SourceStore(clock: () => now);
    expect(store.deletedTodayCount, 0);
    expect(store.addAllDetailed([_src('x.com')]).added, 1);
  });
}
