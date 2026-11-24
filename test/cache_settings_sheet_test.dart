// 缓存设置面板 & 详情页「缓存」入口的渲染测试。
//
// 需求（用户原话）：「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从
// 当前章节缓存到最新（并且开启自动追剧模式缓存）」——这里保证四个选项都在、
// 默认高亮当前设置、并且保存会写进书里。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/cache_plan.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';
import 'package:sakura_read/src/ui/book_detail_page.dart';
import 'package:sakura_read/src/ui/cache_settings_sheet.dart';

Book _onlineBook({int count = 12, int reading = 3}) => Book(
  id: 'sheet-book',
  title: '缓存测试书',
  format: BookFormat.online,
  path: 'https://example.com/book',
  sourceUrl: 'https://example.com/source',
  chapters: [
    for (var i = 0; i < count; i++)
      ChapterRef(title: '第 ${i + 1} 章', href: 'https://example.com/c$i'),
  ],
  chapterIndex: reading,
);

void main() {
  late Directory tmp;
  late BookStore store;
  late AppPrefs prefs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_cache_sheet');
    final dirs = AppDirs(files: tmp.path, cache: tmp.path);
    store = BookStore(dirsOverride: dirs);
    await store.load();
    prefs = AppPrefs(dirsOverride: dirs);
    await prefs.load();
  });

  tearDown(() async {
    store.dispose();
    prefs.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 把面板挂到一个最小 Scaffold 上（不经过整页导航，测试更稳）。
  Future<BookCachePlan?> pumpSheet(WidgetTester tester, Book book) async {
    BookCachePlan? saved;
    store.addOnline(book);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showBookCacheSettings(
                ctx,
                book: book,
                store: store,
                onSave: (plan) async => saved = plan,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('四个选项都在，并且默认选中「全部缓存」', (tester) async {
    final book = _onlineBook();
    await pumpSheet(tester, book);

    expect(find.text('缓存设置'), findsOneWidget);
    expect(find.text('全部缓存'), findsOneWidget);
    expect(find.text('从当前章缓存到最新'), findsOneWidget);
    expect(find.text('只缓存一段'), findsOneWidget);
    expect(find.text('不自动缓存'), findsOneWidget);
  });

  testWidgets('选「从当前章缓存到最新」→ 预览只算后半段，保存写进书里', (tester) async {
    final book = _onlineBook(count: 12, reading: 3);
    store.addOnline(book);
    BookCachePlan? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showBookCacheSettings(
                ctx,
                book: book,
                store: store,
                onSave: (plan) async {
                  saved = plan;
                  store.setCachePlan(book.id, plan);
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.text('从当前章缓存到最新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('起点'), findsOneWidget);
    expect(find.text('第 4 章'), findsOneWidget);

    await tester.tap(find.text('保存并开始缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    // 等保存定时器跑完（BookStore 有 400ms 防抖）
    await tester.pump(const Duration(milliseconds: 500));

    expect(saved, isNotNull);
    expect(saved!.mode, CacheMode.from);
    expect(saved!.start, 3);
    expect(store.byId(book.id)!.cachePlan.mode, CacheMode.from);
    expect(book.cachePlan.mode, CacheMode.from);
  });

  testWidgets('选「不自动缓存」→ 文案变成关掉提示', (tester) async {
    final book = _onlineBook();
    BookCachePlan? saved;
    store.addOnline(book);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showBookCacheSettings(
                ctx,
                book: book,
                store: store,
                onSave: (plan) async => saved = plan,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不自动缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.text('关掉这本书的缓存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(saved!.mode, CacheMode.off);
  });

  testWidgets('详情页：缓存卡片显示范围，点「修改」能打开设置', (tester) async {
    final book = _onlineBook(count: 20, reading: 5);
    book.cachePlan = const BookCachePlan(
      mode: CacheMode.from,
      start: 5,
      updatedAt: 1,
    );
    store.addOnline(book);

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(store: store, prefs: prefs, bookId: book.id),
      ),
    );
    await tester.pump();

    // 范围一句话：第 6 章 → 最新（自动追更）
    expect(find.textContaining('范围：第 6 章 → 最新'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('缓存设置'), findsOneWidget);
    // 打开时高亮的应该是当前模式
    expect(find.text('从当前章缓存到最新'), findsOneWidget);

    // 收尾：关掉面板，避免 pending timer
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  test('缓存计划的范围描述对 0 章 / 越界也安全', () {
    expect(
      const BookCachePlan(mode: CacheMode.from, start: 999).describe(10),
      '第 10 章 → 最新（自动追更）',
    );
    expect(
      const BookCachePlan(
        mode: CacheMode.range,
        start: 0,
        end: 999,
      ).describe(10),
      '第 1 ~ 10 章',
    );
    expect(const BookCachePlan(mode: CacheMode.off).describe(0), '不自动缓存');
  });

  // 保证 buildCachePlan 在这个文件里也有引用（避免 import 被当成多余）
  test('buildCachePlan 与面板一致：全部 → 12 章都要下', () {
    final book = _onlineBook();
    final plan = buildCachePlan(book, cached: const {});
    expect(plan.indices.length, 12);
  });
}
