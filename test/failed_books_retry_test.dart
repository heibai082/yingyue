// 「全部重搜」后台控制器的回归测试：进度、成功/失败计数、停止、空清单，
// 以及「备份里的阅读位置」有没有原样传给重搜逻辑。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/failed_books_retry.dart';
import 'package:sakura_read/src/data/import_fail_store.dart';
import 'package:sakura_read/src/data/import_research.dart';

void _seed(List<ImportFailBook> books) {
  ImportFailStore.instance.items
    ..clear()
    ..addAll(books);
}

void main() {
  setUp(() => _seed(const []));
  tearDown(() => ImportFailStore.instance.items.clear());

  test('逐本推进：完成数 / 成功 / 失败都算对，进度文案跟着走', () async {
    _seed(const [
      ImportFailBook(title: '甲'),
      ImportFailBook(title: '乙'),
      ImportFailBook(title: '丙'),
    ]);
    final seen = <String>[];
    final progressAt = <String>[];
    final c = FailedBooksRetryController(
      research: (book) async {
        seen.add(book.title);
        return book.title == '乙'
            ? const ResearchResult(ok: false, message: '没搜到')
            : const ResearchResult(ok: true, message: '已入架');
      },
    );
    c.addListener(() {
      if (c.running) progressAt.add(c.progressText);
    });

    await c.startAll();

    expect(seen, ['甲', '乙', '丙'], reason: '按清单顺序逐本搜');
    expect(c.running, isFalse);
    expect(c.total, 3);
    expect(c.done, 3);
    expect(c.okCount, 2);
    expect(c.failCount, 1);
    expect(c.currentTitle, isNull, reason: '结束后不该还挂着书名');
    expect(progressAt, isNotEmpty);
    expect(c.progressText, contains('已处理 3/3'));
  });

  test('备份里的阅读位置会原样传给重搜逻辑', () async {
    _seed(const [
      ImportFailBook(
        title: '永噩长夜',
        author: 'zhttty',
        chapterIndex: 233,
        chapterTitle: '第二百三十三章',
        charOffset: 812,
        lastReadAt: 1763800000000,
      ),
    ]);
    ImportFailBook? received;
    final c = FailedBooksRetryController(
      research: (book) async {
        received = book;
        return const ResearchResult(ok: true);
      },
    );

    await c.startAll();

    expect(received, isNotNull);
    expect(received!.chapterIndex, 233);
    expect(received!.charOffset, 812);
    expect(received!.lastReadAt, 1763800000000);
    expect(received!.chapterTitle, '第二百三十三章');
  });

  test('中途停止：不再继续后面的书', () async {
    _seed(const [
      ImportFailBook(title: '一'),
      ImportFailBook(title: '二'),
      ImportFailBook(title: '三'),
      ImportFailBook(title: '四'),
    ]);
    final seen = <String>[];
    late FailedBooksRetryController c;
    c = FailedBooksRetryController(
      research: (book) async {
        seen.add(book.title);
        // 第一本搜完就叫停
        c.cancel();
        return const ResearchResult(ok: true, message: 'ok');
      },
    );

    await c.startAll();

    expect(seen, ['一'], reason: '停止后不应再领新书');
    expect(c.running, isFalse);
    expect(c.done, 1);
  });

  test('清单为空时什么都不做（不启动后台任务）', () async {
    _seed(const []);
    final c = FailedBooksRetryController(
      research: (book) async => const ResearchResult(ok: true),
    );
    await c.startAll();
    expect(c.running, isFalse);
    expect(c.total, 0);
    expect(c.done, 0);
  });

  test('搜索抛异常也只算这一本失败，不影响后面', () async {
    _seed(const [ImportFailBook(title: '坏'), ImportFailBook(title: '好')]);
    final c = FailedBooksRetryController(
      research: (book) async {
        if (book.title == '坏') throw StateError('boom');
        return const ResearchResult(ok: true);
      },
    );
    await c.startAll();
    expect(c.done, 2);
    expect(c.failCount, 1);
    expect(c.okCount, 1);
    expect(c.lastMessage, isNotNull);
  });
}
