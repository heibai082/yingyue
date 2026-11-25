// 0.49 阅读体验相关纯逻辑：书架筛选、漫画分页/双页、亮度与色温、阅读目标。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/comic_view.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/data/shelf_filter.dart';
import 'package:sakura_read/src/data/stats_store.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

Book _book(
  String title, {
  String author = '',
  int lastReadAt = 0,
  bool finished = false,
}) => Book(
  id: title,
  title: title,
  author: author,
  format: BookFormat.online,
  path: 'u/$title',
  lastReadAt: lastReadAt,
  finished: finished,
);

void main() {
  group('书架搜索 / 状态筛选', () {
    final books = [
      _book('航海王', author: '尾田荣一郎', lastReadAt: 1),
      _book('鬼灭之刃', author: '吾峠呼世晴', lastReadAt: 1, finished: true),
      _book('新书', author: '某人'),
    ];

    test('关键词匹配书名或作者，大小写不敏感', () {
      expect(filterBooksByQuery(books, '航海').map((b) => b.title), ['航海王']);
      expect(filterBooksByQuery(books, '尾田').map((b) => b.title), ['航海王']);
      expect(filterBooksByQuery(books, ''), books);
      expect(filterBooksByQuery(books, '   '), books);
      expect(filterBooksByQuery(books, '不存在'), isEmpty);
    });

    test('状态：在读 / 读完 / 未读', () {
      expect(
        filterShelf(
          books,
          status: ShelfStatusFilter.reading,
        ).map((b) => b.title),
        ['航海王'],
      );
      expect(
        filterShelf(
          books,
          status: ShelfStatusFilter.finished,
        ).map((b) => b.title),
        ['鬼灭之刃'],
      );
      expect(
        filterShelf(
          books,
          status: ShelfStatusFilter.unread,
        ).map((b) => b.title),
        ['新书'],
      );
    });

    test('关键词 + 状态可以叠加', () {
      expect(
        filterShelf(books, query: '鬼', status: ShelfStatusFilter.finished),
        hasLength(1),
      );
      expect(
        filterShelf(books, query: '航海', status: ShelfStatusFilter.finished),
        isEmpty,
      );
    });
  });

  group('漫画分页 / 双页 / 亮度色温', () {
    test('单页：每张一页', () {
      final pages = paginateImages(['a', 'b', 'c'], doublePage: false);
      expect(pages, [
        ['a'],
        ['b'],
        ['c'],
      ]);
    });

    test('双页：两两一组，奇数最后一张单独一页（不吞图）', () {
      final pages = paginateImages(['a', 'b', 'c'], doublePage: true);
      expect(pages, [
        ['a', 'b'],
        ['c'],
      ]);
      expect(pages.expand((p) => p).length, 3, reason: '一张都不能丢');
    });

    test('空列表返回空', () {
      expect(paginateImages([], doublePage: true), isEmpty);
    });

    test('竖屏手机单页，横屏/平板双页', () {
      expect(shouldUseDoublePage(landscape: false, width: 393), isFalse);
      expect(shouldUseDoublePage(landscape: true, width: 393), isTrue);
      expect(shouldUseDoublePage(landscape: false, width: 800), isTrue);
    });

    test('亮度最低 30%、遮罩最多 70%，不会全黑', () {
      expect(clampBrightness(0), 0.3);
      expect(clampBrightness(2), 1.0);
      expect(dimAlphaFor(0.3), closeTo(0.7, 0.001));
      expect(dimAlphaFor(1), 0);
    });

    test('色温最多 ±18% 透明，不会把画面染成一片', () {
      expect(clampWarmth(-5), -1.0);
      expect(clampWarmth(5), 1.0);
      expect(warmthAlphaFor(1), closeTo(0.18, 0.001));
      expect(warmthAlphaFor(0), 0);
    });

    test('从右往左读 = PageView 反向', () {
      expect(reversePages(rightToLeft: true), isTrue);
      expect(reversePages(rightToLeft: false), isFalse);
    });
  });

  group('阅读目标', () {
    test('今日秒数只统计今天；目标设置会被夹到合理范围', () async {
      final tmp = await Directory.systemTemp.createTemp('sakura_goal');
      final dirs = AppDirs(files: tmp.path, cache: tmp.path);
      final stats = StatsStore(dirsOverride: dirs);
      await stats.load();
      addTearDown(stats.dispose);
      final before = stats.todaySeconds;
      // 单次累计上限 90 秒（防挂机刷时长），所以分两次加
      stats.addReadingSeconds(60);
      stats.addReadingSeconds(60);
      expect(stats.todaySeconds, before + 120);

      final prefs = AppPrefs(dirsOverride: dirs);
      await prefs.load();
      addTearDown(prefs.dispose);
      expect(prefs.dailyGoalMinutes, 0);
      prefs.setDailyGoalMinutes(30);
      expect(prefs.dailyGoalMinutes, 30);
      prefs.setDailyGoalMinutes(1000);
      expect(prefs.dailyGoalMinutes, 600);
      prefs.setDailyGoalMinutes(0);
      expect(prefs.dailyGoalMinutes, 0);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });
}
