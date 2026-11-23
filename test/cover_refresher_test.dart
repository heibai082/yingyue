// 一键更新封面的回归测试：只补缺失、已有封面跳过、失败不影响其它书。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/cover_refresher.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/source/source_store.dart';

Book _onlineBook(
  String id,
  String title, {
  String? coverPath,
  bool generated = true,
}) {
  final chapters = [
    for (var i = 0; i < 3; i++)
      ChapterRef(title: '第$i章', href: 'u$i', charCount: 100),
  ];
  return Book(
    id: id,
    title: title,
    author: '作者',
    format: BookFormat.online,
    path: 'https://book.example.com/$id',
    sourceUrl: 'https://src.example.com/',
    chapters: chapters,
    coverPath: coverPath,
    generatedCover: generated,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cover_refresher_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('没有封面的书会被补上；已有封面跳过', () async {
    final cover = File('${tmp.path}/existing.jpg')
      ..writeAsBytesSync(List.filled(2048, 1));
    final store = BookStore()
      ..addOnline(_onlineBook('a', '没封面的书'))
      ..addOnline(
        _onlineBook('b', '有封面的书', coverPath: cover.path, generated: false),
      );

    var resolved = 0;
    final refresher = CoverRefresher(
      store: store,
      sources: SourceStore(),
      coverDirOverride: tmp,
      resolveUrl: (book) async {
        resolved++;
        return 'https://img.example.com/${book.id}.jpg';
      },
      download: (url) async => List.filled(4096, 7),
    );

    final r = await refresher.run();

    expect(r.total, 2);
    expect(r.done, 2);
    expect(r.updated, 1, reason: '只有 a 需要更新');
    expect(r.skipped, 1, reason: '已有封面的跳过');
    expect(r.failed, 0);
    expect(resolved, 1, reason: '跳过的不该去请求书源');
    final updated = store.byId('a')!;
    expect(updated.generatedCover, isFalse);
    expect(updated.coverPath, isNotNull);
    expect(File(updated.coverPath!).existsSync(), isTrue);
  });

  test('占位图（generatedCover）会重新抓', () async {
    final placeholder = File('${tmp.path}/placeholder.png')
      ..writeAsBytesSync(List.filled(1024, 2));
    final store = BookStore()
      ..addOnline(
        _onlineBook('a', '占位图', coverPath: placeholder.path, generated: true),
      );
    final refresher = CoverRefresher(
      store: store,
      sources: SourceStore(),
      coverDirOverride: tmp,
      resolveUrl: (book) async => 'https://img.example.com/a.jpg',
      download: (url) async => List.filled(4096, 9),
    );
    final r = await refresher.run();
    expect(r.updated, 1);
    expect(store.byId('a')!.coverPath, isNot(placeholder.path));
  });

  test('图片太小（像占位图）：算失败，不改原封面', () async {
    final store = BookStore()..addOnline(_onlineBook('a', '无封面'));
    final refresher = CoverRefresher(
      store: store,
      sources: SourceStore(),
      coverDirOverride: tmp,
      resolveUrl: (book) async => 'https://img.example.com/a.jpg',
      download: (url) async => List.filled(10, 1),
    );
    final r = await refresher.run();
    expect(r.updated, 0);
    expect(r.failed, 1);
    expect(store.byId('a')!.coverPath, isNull);
  });

  test('书源返回空封面地址：只记失败', () async {
    final store = BookStore()..addOnline(_onlineBook('a', '无封面'));
    final refresher = CoverRefresher(
      store: store,
      sources: SourceStore(),
      coverDirOverride: tmp,
      resolveUrl: (book) async => null,
      download: (url) async => List.filled(4096, 3),
    );
    final r = await refresher.run();
    expect(r.failed, 1);
    expect(r.updated, 0);
  });

  test('取消：不再继续处理后面的书', () async {
    final store = BookStore()
      ..addOnline(_onlineBook('a', '1'))
      ..addOnline(_onlineBook('b', '2'))
      ..addOnline(_onlineBook('c', '3'));

    late CoverRefresher refresher;
    var calls = 0;
    refresher = CoverRefresher(
      store: store,
      sources: SourceStore(),
      coverDirOverride: tmp,
      resolveUrl: (book) async {
        calls++;
        if (calls == 1) refresher.cancel();
        return 'https://img.example.com/${book.id}.jpg';
      },
      download: (url) async => List.filled(4096, 5),
    );

    final r = await refresher.run();
    expect(r.cancelled, isTrue);
    expect(calls, 1);
    expect(r.done, lessThan(3));
  });
}
