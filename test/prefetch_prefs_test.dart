// 「自动缓存后两章」开关 + 漫画章节列表缓存落盘的回归测试。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';
import 'package:sakura_read/src/source/comic_chapter_cache.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 450));

AppDirs _tempDirs(List<Directory> trash) {
  final dir = Directory.systemTemp.createTempSync('sakura_prefetch_');
  trash.add(dir);
  return AppDirs(files: dir.path, cache: '${dir.path}/cache');
}

void main() {
  final trash = <Directory>[];
  tearDown(() {
    for (final d in trash) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
    trash.clear();
  });

  group('自动缓存后两章（设置项）', () {
    test('默认开启', () {
      final prefs = AppPrefs(dirsOverride: _tempDirs(trash));
      expect(prefs.autoPrefetchChapters, isTrue);
    });

    test('关掉后写进 settings.json，重新加载能读回', () async {
      final dirs = _tempDirs(trash);
      final prefs = AppPrefs(dirsOverride: dirs);
      await prefs.load();
      prefs.setAutoPrefetchChapters(false);
      await _settle();

      final raw = jsonDecode(
        File('${dirs.files}/settings.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(raw['autoPrefetchChapters'], isFalse);

      final again = AppPrefs(dirsOverride: dirs);
      await again.load();
      expect(again.autoPrefetchChapters, isFalse);
    });

    test('老设置文件里没这个键 → 按默认 true', () async {
      final dirs = _tempDirs(trash);
      File('${dirs.files}/settings.json')
          .writeAsStringSync(jsonEncode({'v': 2, 'fontSize': 20}));
      final prefs = AppPrefs(dirsOverride: dirs);
      await prefs.load();
      expect(prefs.autoPrefetchChapters, isTrue);
    });
  });

  group('漫画章节列表缓存落盘', () {
    test('写盘再读回，图片顺序不变', () async {
      final dir = Directory.systemTemp.createTempSync('comic_cache_');
      trash.add(dir);
      final file = File('${dir.path}/comic_list_cache.json');

      final a = ComicChapterCache();
      a.put('https://cn.bzmanga.com/ch/1', ['a1.jpg', 'a2.jpg']);
      a.put('https://cn.bzmanga.com/ch/2', ['b1.jpg']);
      await a.saveTo(file);

      final b = ComicChapterCache();
      await b.loadFrom(file);
      expect(b.length, 2);
      expect(b['https://cn.bzmanga.com/ch/1'], ['a1.jpg', 'a2.jpg']);
      expect(b['https://cn.bzmanga.com/ch/2'], ['b1.jpg']);
    });

    test('坏文件不影响使用（当成空缓存）', () async {
      final dir = Directory.systemTemp.createTempSync('comic_cache_bad_');
      trash.add(dir);
      final file = File('${dir.path}/comic_list_cache.json')
        ..writeAsStringSync('{not json');

      final c = ComicChapterCache();
      await c.loadFrom(file);
      expect(c.length, 0);
      c.put('u', ['1.jpg']);
      expect(c['u'], ['1.jpg']);
    });

    test('空列表不写进缓存（失败的章节下次要重新取）', () {
      final c = ComicChapterCache();
      c.put('u', const []);
      expect(c.contains('u'), isFalse);
    });
  });
}
