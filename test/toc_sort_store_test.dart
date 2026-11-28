// 老书目录修复：启动时把所有在线书的目录顺序归一化，且不改变「正在读的那一章」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

void main() {
  test('卷/话混排的老书会被整理，进度跟着那一章走', () async {
    final tmp = await Directory.systemTemp.createTemp('toc_fix');
    final dirs = AppDirs(
      files: '${tmp.path}/files',
      cache: '${tmp.path}/cache',
    );
    final store = BookStore(dirsOverride: dirs);
    await store.load();

    final titles = ['第10卷', '第09卷', '第08卷', '第41话', '第40话', '第39话', '第07卷'];
    final book = Book(
      id: 'b1',
      title: '混排漫画',
      format: BookFormat.online,
      path: 'https://x/comic/1',
      chapters: [
        for (final t in titles) ChapterRef(title: t, href: 'https://x/$t'),
      ],
      chapterIndex: 3, // 正在读「第41话」
    );
    store.addOnline(book);

    final fixed = store.normalizeAllChapterOrders();
    expect(fixed, 1);

    final b = store.byId('b1')!;
    final ordered = [for (final c in b.chapters) c.title];
    expect(ordered.take(4), ['第07卷', '第08卷', '第09卷', '第10卷']);
    expect(ordered[4], '第39话');
    expect(ordered.last, '第41话');
    expect(b.chapters[b.chapterIndex].title, '第41话');

    store.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });
}
