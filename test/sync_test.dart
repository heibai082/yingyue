// 同步服务（0.52）：payload、按时间合并、HTTP 客户端、开关保护。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sakura_read/src/data/book_store.dart';
import 'package:sakura_read/src/data/models.dart';
import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/data/stats_store.dart';
import 'package:sakura_read/src/data/sync_client.dart';
import 'package:sakura_read/src/data/sync_service.dart';
import 'package:sakura_read/src/source/source_store.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';

Book _book(String path, {int chapter = 0, int lastReadAt = 0}) => Book(
  id: path,
  title: '书$path',
  format: BookFormat.online,
  path: path,
  chapters: [
    for (var i = 0; i < 10; i++) ChapterRef(title: '第 ${i + 1} 章', href: 'h$i'),
  ],
  chapterIndex: chapter,
  lastReadAt: lastReadAt,
);

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late BookStore store;
  late AppPrefs prefs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sakura_sync');
    dirs = AppDirs(files: '${tmp.path}/files', cache: '${tmp.path}/cache');
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

  group('payload', () {
    test('带设备、书架进度、统计，不传正文', () {
      store.addOnline(_book('p/a', chapter: 3, lastReadAt: 100));
      final payload = buildSyncPayload(
        store: store,
        deviceName: '小米11',
        platform: 'android',
      );
      expect(payload['devices']['小米11']['platform'], 'android');
      final books = payload['books'] as List;
      expect(books, hasLength(1));
      expect(books.first['chapterIndex'], 3);
      expect(books.first['total'], 10);
      expect(books.first.containsKey('content'), isFalse);
      expect(payload['stats'], isA<Map>());
    });
  });

  group('合并远端状态', () {
    test('远端更新才覆盖；更旧的忽略', () {
      store.addOnline(_book('p/a', chapter: 1, lastReadAt: 100));
      final applied = applyRemoteState({
        'books': [
          {'path': 'p/a', 'chapterIndex': 5, 'lastReadAt': 200},
        ],
      }, store: store);
      expect(applied[0], 1);
      expect(store.byId('p/a')!.chapterIndex, 5);

      final again = applyRemoteState({
        'books': [
          {'path': 'p/a', 'chapterIndex': 2, 'lastReadAt': 150},
        ],
      }, store: store);
      expect(again[0], 0);
      expect(store.byId('p/a')!.chapterIndex, 5, reason: '旧进度不能回退');
    });

    test('统计取大，不取小', () async {
      final stats = StatsStore(dirsOverride: dirs);
      await stats.load();
      addTearDown(stats.dispose);
      applyRemoteState(
        {
          'stats': {
            'totalSeconds': 1000,
            'finishedBooks': 2,
            'days': {'2026-11-25': 600},
          },
        },
        store: store,
        stats: stats,
      );
      expect(stats.totalSeconds, 1000);
      expect(stats.finishedBooks, 2);
      expect(stats.days['2026-11-25'], 600);

      // 远端更小 → 不回退
      applyRemoteState(
        {
          'stats': {'totalSeconds': 10, 'finishedBooks': 0, 'days': {}},
        },
        store: store,
        stats: stats,
      );
      expect(stats.totalSeconds, 1000);
      expect(stats.finishedBooks, 2);
    });
  });

  group('HTTP 客户端', () {
    test('推送带 Bearer 令牌和 JSON', () async {
      String? auth;
      Map<String, dynamic>? body;
      final client = SyncClient(
        baseUrl: 'http://srv:8090',
        token: 't0',
        client: MockClient((req) async {
          auth = req.headers['Authorization'];
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('{"ok":true}', 200);
        }),
      );
      await client.pushState({'books': []});
      expect(auth, 'Bearer t0');
      expect(body?['books'], isEmpty);
    });

    test('健康检查：200=true，其他=false，异常=false', () async {
      var code = 200;
      final client = SyncClient(
        baseUrl: 'http://srv:8090',
        token: 't',
        client: MockClient((req) async {
          if (code == -1) throw const SocketException('boom');
          return http.Response('{}', code);
        }),
      );
      expect(await client.ping(), isTrue);
      code = 500;
      expect(await client.ping(), isFalse);
      code = -1;
      expect(await client.ping(), isFalse);
    });

    test('拉取解析 JSON；非 200 抛错', () async {
      var code = 200;
      final client = SyncClient(
        baseUrl: 'http://srv:8090',
        token: 't',
        client: MockClient((req) async {
          return http.Response(
            jsonEncode({
              'books': [
                {'path': 'p/a', 'lastReadAt': 1},
              ],
            }),
            code,
          );
        }),
      );
      final state = await client.fetchState();
      expect((state['books'] as List), hasLength(1));
      code = 401;
      await expectLater(client.fetchState(), throwsStateError);
    });

    test('上传备份返回文件名', () async {
      final client = SyncClient(
        baseUrl: 'http://srv:8090',
        token: 't',
        client: MockClient((req) async {
          expect(req.headers['Content-Type'], 'application/zip');
          return http.Response('{"ok":true,"name":"b.zip"}', 200);
        }),
      );
      expect(await client.uploadBackup([1, 2, 3]), 'b.zip');
    });
  });

  group('SyncService', () {
    test('未启用时直接返回「未启用」', () async {
      final sync = SyncService(prefs: prefs, store: store);
      addTearDown(sync.dispose);
      final r = await sync.push();
      expect(r.ok, isFalse);
      expect(r.error, contains('未启用'));
    });

    test('启用后 syncNow 推送成功并记录时间', () async {
      prefs.setSyncConfig(
        baseUrl: 'http://srv:8090',
        token: 't',
        enabled: true,
      );
      final sync = SyncService(
        prefs: prefs,
        store: store,
        client: SyncClient(
          baseUrl: 'http://srv:8090',
          token: 't',
          client: MockClient((req) async {
            if (req.method == 'POST') return http.Response('{"ok":true}', 200);
            return http.Response('{"books":[]}', 200);
          }),
        ),
      );
      addTearDown(sync.dispose);
      final r = await sync.syncNow();
      expect(r.ok, isTrue);
      expect(r.pushed, isTrue);
      expect(prefs.lastSyncAt, greaterThan(0));
    });
  });
  test('上传章节：JSON 里带 path/index/images', () async {
    Map<String, dynamic>? body;
    final client = SyncClient(
      baseUrl: 'http://srv:8090',
      token: 't',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"ok":true}', 200);
      }),
    );
    await client.uploadChapter({
      'path': 'p/a',
      'index': 3,
      'title': '第4章',
      'images': ['http://i/1.jpg'],
    });
    expect(body?['path'], 'p/a');
    expect(body?['index'], 3);
    expect((body?['images'] as List), hasLength(1));
  });
  group('书源同步', () {
    test('上传书源：POST /api/sources，带 items', () async {
      Map<String, dynamic>? body;
      final client = SyncClient(
        baseUrl: 'http://srv:8090',
        token: 't',
        client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('{"ok":true,"count":2}', 200);
        }),
      );
      final n = await client.uploadSources([
        {'bookSourceName': 'A', 'bookSourceUrl': 'https://a'},
        {'bookSourceName': 'B', 'bookSourceUrl': 'https://b'},
      ]);
      expect(n, 2);
      expect((body?['items'] as List), hasLength(2));
    });

    test('拉书源：本机为空时才会拉，且能解析', () async {
      final sources = SourceStore(dirsOverride: dirs);
      await sources.load();
      addTearDown(sources.dispose);
      prefs.setSyncConfig(
        baseUrl: 'http://srv:8090',
        token: 't',
        enabled: true,
      );
      final sync = SyncService(
        prefs: prefs,
        store: store,
        sources: sources,
        client: SyncClient(
          baseUrl: 'http://srv:8090',
          token: 't',
          client: MockClient((req) async {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'items': [
                    {'bookSourceName': '源A', 'bookSourceUrl': 'https://a'},
                  ],
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
      );
      addTearDown(sync.dispose);
      final before = sources.sources.length;
      final added = await sync.pullSources();
      expect(added, greaterThanOrEqualTo(1));
      expect(sources.sources.length, greaterThanOrEqualTo(before + 1));
      expect(
        sources.sources.any((s) => s.bookSourceUrl == 'https://a'),
        isTrue,
      );
    });
  });
  group('缓存自动上传', () {
    test('只传没传过的，传完记下来', () async {
      store.addOnline(_book('p/c', chapter: 0, lastReadAt: 1));
      final book = store.byId('p/c')!;
      await store.writeCachedChapter(book, 0, '第一章正文');
      await store.refreshChapterCache(book.id);
      expect(book.chapterCache, contains(0));

      var posts = 0;
      prefs.setSyncConfig(
        baseUrl: 'http://srv:8090',
        token: 't',
        enabled: true,
        cache: true,
        autoUpload: true,
        wifiOnly: false,
      );
      final sync = SyncService(
        prefs: prefs,
        store: store,
        client: SyncClient(
          baseUrl: 'http://srv:8090',
          token: 't',
          client: MockClient((req) async {
            if (req.method == 'POST' && req.url.path == '/api/chapters') {
              posts++;
            }
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
      addTearDown(sync.dispose);
      expect(await sync.autoPushPending(), 1);
      expect(posts, 1);
      // 再跑一次，不应该重复传
      expect(await sync.autoPushPending(), 0);
      expect(posts, 1);
    });
  });
  group('静默上传（只传服务器没有的）', () {
    test('服务器已有第 0 章时只传第 1 章，再跑不重复', () async {
      store.addOnline(_book('p/s', chapter: 0, lastReadAt: 1));
      final book = store.byId('p/s')!;
      await store.writeCachedChapter(book, 0, '第0章正文');
      await store.writeCachedChapter(book, 1, '第1章正文');
      await store.refreshChapterCache(book.id);
      expect(book.chapterCache, containsAll([0, 1]));

      var uploads = 0;
      prefs.setSyncConfig(
        baseUrl: 'http://srv:8090',
        token: 't',
        enabled: true,
        cache: true,
        autoUpload: true,
        wifiOnly: false,
      );
      final sync = SyncService(
        prefs: prefs,
        store: store,
        client: SyncClient(
          baseUrl: 'http://srv:8090',
          token: 't',
          client: MockClient((req) async {
            if (req.url.path == '/api/chapters/index') {
              return http.Response.bytes(
                utf8.encode('{"items":{"p/s":[0]}}'),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (req.url.path == '/api/chapters' && req.method == 'POST') {
              uploads++;
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              expect(body['index'], 1);
            }
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
      addTearDown(sync.dispose);
      expect(await sync.pendingCacheCount(), 1);
      expect(await sync.silentSync(force: true), 1);
      expect(uploads, 1);
      expect(await sync.silentSync(force: true), 0);
      expect(uploads, 1);
    });
  });
}
