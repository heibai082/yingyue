// 0.50 可靠性 / 数据功能测试：目录体检、崩溃日志、书签导出、备份保留、书架合并、补章匹配。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/auto_backup.dart';
import 'package:sakura_read/src/data/bookmark_export.dart';
import 'package:sakura_read/src/data/chapter_health.dart';
import 'package:sakura_read/src/data/chapter_patch.dart';
import 'package:sakura_read/src/data/crash_log.dart';
import 'package:sakura_read/src/data/library_merge.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/data/stats_store.dart';
import 'package:sakura_read/src/data/webdav_client.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

List<ChapterRef> _chapters(Iterable<int> numbers) => [
  for (final n in numbers)
    ChapterRef(title: '第 $n 章 标题$n', href: 'https://x/$n'),
];

void main() {
  group('目录体检', () {
    test('正常目录没问题', () {
      final h = analyzeChapters(_chapters([1, 2, 3, 4]));
      expect(h.ok, isTrue);
      expect(h.summary, contains('目录正常'));
    });

    test('缺章能报出来，且不误报连续序号', () {
      final h = analyzeChapters(_chapters([1, 2, 5, 6]));
      expect(h.ok, isFalse);
      expect(h.issues.any((i) => i.message.contains('第 3~4 章缺失')), isTrue);
    });

    test('重复序号能报出来', () {
      final h = analyzeChapters(_chapters([1, 2, 2, 3]));
      expect(h.issues.any((i) => i.message.contains('出现了不止一次')), isTrue);
    });

    test('认不出序号时只提示无法检查', () {
      final h = analyzeChapters([
        ChapterRef(title: '序章'),
        ChapterRef(title: '尾声'),
      ]);
      expect(h.ok, isFalse);
      expect(h.issues.single.message, contains('认不出序号'));
    });

    test('空目录', () {
      expect(analyzeChapters(const []).summary, contains('还没有目录'));
    });
  });

  group('崩溃日志', () {
    test('写入后可读出，包含异常信息与堆栈', () async {
      final tmp = await Directory.systemTemp.createTemp('sakura_crash');
      final log = CrashLog(file: File('${tmp.path}/logs/crash.log'));
      await log.append('FlutterError', StateError('测试崩溃'), StackTrace.current);
      final text = await log.tail();
      expect(text, contains('测试崩溃'));
      expect(text, contains('FlutterError'));
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('超过上限会截断，不会无限增长', () async {
      final tmp = await Directory.systemTemp.createTemp('sakura_crash2');
      final file = File('${tmp.path}/crash.log');
      final log = CrashLog(file: file, maxBytes: 2000);
      for (var i = 0; i < 200; i++) {
        await log.append('E', StateError('错误 $i'), StackTrace.empty);
      }
      expect(await file.length(), lessThan(4000));
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  group('书签导出 Markdown', () {
    test('按书分组、带摘录与位置', () {
      final items = [
        Bookmark(
          id: '1',
          bookId: 'b1',
          chapterIndex: 4,
          charOffset: 120,
          chapterTitle: '第 5 章 标题4',
          excerpt: '第一行\n第二行',
          createdAt: DateTime(2026, 11, 20, 10, 30).millisecondsSinceEpoch,
        ),
        Bookmark(
          id: '2',
          bookId: 'b1',
          chapterIndex: 1,
          charOffset: 0,
          chapterTitle: '第 2 章 标题1',
        ),
      ];
      final md = buildBookmarksMarkdown(items, bookNames: {'b1': '航海王'});
      expect(md, contains('## 航海王'));
      // 按章节顺序：第 2 章在前
      expect(md.indexOf('第 2 章'), lessThan(md.indexOf('第 5 章')));
      expect(md, contains('> 第一行'));
      expect(md, contains('> 第二行'));
      expect(md, contains('第 5 章，第 120 字'));
    });

    test('空书签也能导出（不崩）', () {
      expect(buildBookmarksMarkdown(const []), contains('还没有书签'));
    });
  });

  group('云端备份保留策略', () {
    WebdavEntry zip(String name, DateTime t) =>
        WebdavEntry(name: name, isDirectory: false, modified: t);

    test('超过 7 份时删最旧的', () {
      final entries = [
        for (var i = 0; i < 10; i++)
          zip('backup-$i.zip', DateTime(2026, 11, 1 + i)),
        const WebdavEntry(name: 'sakura-read/', isDirectory: true),
        const WebdavEntry(name: 'note.txt', isDirectory: false),
      ];
      final drop = pickBackupsToDelete(entries, keep: 7);
      expect(drop, hasLength(3));
      expect(drop.map((e) => e.name), containsAll(['backup-0.zip', 'backup-1.zip', 'backup-2.zip']));
    });

    test('不足 7 份不删', () {
      final entries = [for (var i = 0; i < 3; i++) zip('b$i.zip', DateTime(2026))];
      expect(pickBackupsToDelete(entries), isEmpty);
    });
  });

  group('书架增量合并', () {
    test('同一本书取 lastReadAt 新的，分组合并保留', () {
      final current = {
        'books': [
          {
            'id': 'a',
            'path': 'https://book/a',
            'title': '书A',
            'chapterIndex': 3,
            'lastReadAt': 100,
            'group': '在追',
          },
        ],
      };
      final incoming = {
        'books': [
          {
            'id': 'a2',
            'path': 'https://book/a',
            'title': '书A',
            'chapterIndex': 9,
            'lastReadAt': 200,
          },
        ],
      };
      final merged = mergeLibraryJson(current, incoming);
      final books = (merged['books'] as List).cast<Map>();
      expect(books, hasLength(1));
      expect(books.single['chapterIndex'], 9, reason: '新进度胜出');
      expect(books.single['group'], '在追', reason: '分组不该被冲掉');
    });

    test('只在一边有的书都保留', () {
      final merged = mergeLibraryJson(
        {
          'books': [
            {'id': 'a', 'path': 'p/a'},
          ],
        },
        {
          'books': [
            {'id': 'b', 'path': 'p/b'},
          ],
        },
      );
      expect((merged['books'] as List), hasLength(2));
    });
  });

  group('补章：在别的源里认出同一章', () {
    test('按序号匹配', () {
      final ch = pickChapterByNumber(_chapters([1, 2, 3]), 2);
      expect(ch?.title, contains('第 2 章'));
    });

    test('序号认不出时按位置（正序 / 降序都不越界）', () {
      final asc = [
        ChapterRef(title: '序章', href: 'a'),
        ChapterRef(title: '尾声', href: 'b'),
      ];
      expect(pickChapterByNumber(asc, 2)?.href, 'b');
      final desc = [
        ChapterRef(title: '最新', href: 'new'),
        ChapterRef(title: '上一话', href: 'old'),
      ];
      expect(pickChapterByNumber(desc, 1)?.href, 'new');
      expect(pickChapterByNumber(const [], 1), isNull);
    });
  });

  group('自动备份的触发条件', () {
    test('没开开关 / 没配 WebDAV 都不跑；配好且今天没备份过才跑', () async {
      final tmp = await Directory.systemTemp.createTemp('sakura_auto');
      final prefs = AppPrefs(dirsOverride: AppDirs(files: tmp.path, cache: tmp.path));
      await prefs.load();
      addTearDown(prefs.dispose);
      final svc = AutoBackupService(
        prefs: prefs,
        now: () => DateTime(2026, 11, 25, 9),
      );
      expect(svc.due, isFalse);

      prefs.setAutoBackupEnabled(true);
      expect(svc.due, isFalse, reason: '还没配地址');

      prefs.webdavUrl = 'https://dav.example.com';
      prefs.webdavUser = 'u';
      expect(svc.due, isTrue);

      prefs.setLastAutoBackupDay('2026-11-25');
      expect(svc.due, isFalse, reason: '今天已经备份过');
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });
}
