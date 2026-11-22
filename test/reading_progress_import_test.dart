// 阅读进度相关：备份解析要带上章节位置；待搜源清单要能把位置存住并补齐。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/import_fail_store.dart';
import 'package:sakura_read/src/data/legado_import.dart';

void main() {
  group('备份解析：阅读位置', () {
    test('durChapterIndex / durChapterPos / durChapterTime 都读出来', () {
      final text = jsonEncode({
        'books': [
          {
            'name': '永噩长夜',
            'author': 'zhttty',
            'durChapterIndex': 233,
            'durChapterTitle': '第二百三十三章',
            'durChapterPos': 812,
            'durChapterTime': 1763800000000,
          },
        ],
      });
      final book = LegadoImporter.parseBackup(text).single;
      expect(book.durChapterIndex, 233);
      expect(book.durChapterTitle, '第二百三十三章');
      expect(book.durChapterPos, 812);
      expect(book.durChapterTime, 1763800000000);
    });

    test('只有书名/作者的精简书单：进度就是 0（不是解析丢了）', () {
      final text = jsonEncode([
        {'name': '永噩长夜', 'author': 'zhttty', 'intro': '长夜无尽'},
      ]);
      final book = LegadoImporter.parseBackup(text).single;
      expect(book.durChapterIndex, 0);
      expect(book.durChapterPos, 0);
      expect(book.durChapterTime, 0);
    });

    test('lastReadAt 兜底：没有 durChapterTime 时也认', () {
      final text = jsonEncode({
        'books': [
          {'name': 'A', 'lastReadAt': 1700000000000},
        ],
      });
      expect(
        LegadoImporter.parseBackup(text).single.durChapterTime,
        1700000000000,
      );
    });
  });

  group('待搜源清单：阅读位置不能丢', () {
    setUp(() => ImportFailStore.instance.items.clear());
    tearDown(() => ImportFailStore.instance.items.clear());

    test('add 时存下位置，JSON 往返也不丢', () {
      const book = ImportFailBook(
        title: '永噩长夜',
        author: 'zhttty',
        chapterIndex: 233,
        chapterTitle: '第二百三十三章',
        charOffset: 812,
        lastReadAt: 1763800000000,
      );
      final back = ImportFailBook.fromJson(
        jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>,
      );
      expect(back.chapterIndex, 233);
      expect(back.chapterTitle, '第二百三十三章');
      expect(back.charOffset, 812);
      expect(back.lastReadAt, 1763800000000);
      expect(back.hasProgress, isTrue);
    });

    test('重复 add 同一本：位置只补不退（后来的更靠后才更新）', () async {
      final store = ImportFailStore.instance;
      await store.add('A', chapterIndex: 100, charOffset: 10);
      await store.add('A', chapterIndex: 50, charOffset: 999);
      final afterLower = store.items.single;
      expect(afterLower.chapterIndex, 100, reason: '更靠前的章节不能覆盖');
      expect(afterLower.charOffset, 10, reason: '章节没变时也不该被乱改');

      await store.add('A', chapterIndex: 120, charOffset: 0);
      final afterHigher = store.items.single;
      expect(afterHigher.chapterIndex, 120, reason: '更靠后要更新');
      expect(store.items, hasLength(1), reason: '同一本不重复记');
    });
  });
}
