// 一键更新封面：把在线书的封面从书源抓回来存成文件。
//
// 规则（用户要的）：
//   - 已经有本地封面（coverPath 存在、且不是自动生成的占位图）→ 直接跳过，不重复下载；
//   - 抓不到封面 / 书源失效 → 只记失败，不动原来的封面；
//   - 全程走前台服务（通知栏进度），切 App 继续；看书时暂停让路。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../platform/import_foreground.dart';
import '../source/online_book_service.dart';
import '../source/source_store.dart';
import 'app_activity.dart';
import 'book_store.dart';
import 'models.dart';

/// 一次「更新封面」的结果。
class CoverRefreshResult {
  const CoverRefreshResult({
    this.total = 0,
    this.done = 0,
    this.updated = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  final int total;

  /// 实际处理完的本数（取消时小于 [total]）。
  final int done;
  final int updated;

  /// 已经有封面（或不是在线书）而跳过的数量。
  final int skipped;
  final int failed;
  final bool cancelled;

  String get summary {
    final parts = <String>[
      if (updated > 0) '更新 $updated 本',
      if (skipped > 0) '跳过 $skipped 本（已有封面）',
      if (failed > 0) '失败 $failed 本',
    ];
    if (parts.isEmpty) return '没有需要更新的封面';
    return '${cancelled ? '已停止：' : ''}${parts.join(' · ')}';
  }
}

/// 取某本书的封面地址（默认走 OnlineBookService）。
typedef CoverUrlResolver = Future<String?> Function(Book book);

/// 下载图片字节（默认走 http）。
typedef ImageDownloader = Future<List<int>?> Function(String url);

/// 封面刷新器（可监听，界面用来看进度）。
class CoverRefresher extends ChangeNotifier {
  CoverRefresher({
    required this.store,
    required this.sources,
    OnlineBookService? service,
    http.Client? client,
    CoverUrlResolver? resolveUrl,
    ImageDownloader? download,
    Directory? coverDirOverride,
  }) : _service = service ?? OnlineBookService(),
       _client = client ?? http.Client(),
       _resolveUrl = resolveUrl,
       _download = download,
       _coverDirOverride = coverDirOverride;

  final BookStore store;
  final SourceStore sources;
  final OnlineBookService _service;
  final http.Client _client;
  final CoverUrlResolver? _resolveUrl;
  final ImageDownloader? _download;
  final Directory? _coverDirOverride;

  bool running = false;
  bool paused = false;
  bool _cancelled = false;
  int done = 0;
  int total = 0;
  int updated = 0;
  int skipped = 0;
  int failed = 0;
  String? current;

  String get progressText =>
      '${paused ? '已暂停（正在看书） · ' : ''}'
      '已处理 $done/$total · 更新 $updated · 跳过 $skipped · 失败 $failed';

  void cancel() {
    if (!running) return;
    _cancelled = true;
    notifyListeners();
  }

  /// 开始跑；[onlyMissing] = true 时只处理「没有真封面」的书。
  Future<CoverRefreshResult> run({bool onlyMissing = true}) async {
    if (running) {
      return const CoverRefreshResult();
    }
    _cancelled = false;
    paused = false;
    done = 0;
    updated = 0;
    skipped = 0;
    failed = 0;
    current = null;

    final books = store.books.toList();
    total = books.length;
    running = true;
    notifyListeners();

    await ImportForeground.startTask(
      title: '嘤阅 · 正在更新封面',
      text: '准备中… 共 $total 本',
    );

    for (final book in books) {
      if (_cancelled) break;
      await _waitWhileReading();
      if (_cancelled) break;
      current = book.title;
      notifyListeners();
      _tell();

      try {
        if (book.format != BookFormat.online) {
          skipped++;
        } else if (onlyMissing && _hasRealCover(book)) {
          skipped++;
        } else {
          final ok = await _refreshOne(book);
          if (ok) {
            updated++;
          } else {
            failed++;
          }
        }
      } catch (_) {
        failed++;
      }
      done++;
      notifyListeners();
      _tell();
    }

    running = false;
    paused = false;
    current = null;
    notifyListeners();
    unawaited(ImportForeground.stop());
    return CoverRefreshResult(
      total: total,
      done: done,
      updated: updated,
      skipped: skipped,
      failed: failed,
      cancelled: _cancelled,
    );
  }

  /// 已经有真实封面（文件还在，且不是自动生成的占位图）。
  bool _hasRealCover(Book book) {
    final path = book.coverPath;
    if (path == null || path.isEmpty) return false;
    if (book.generatedCover) return false;
    return File(path).existsSync();
  }

  Future<bool> _refreshOne(Book book) async {
    final String? coverUrl;
    if (_resolveUrl != null) {
      coverUrl = await _resolveUrl(book);
    } else {
      final sourceUrl = book.sourceUrl;
      if (sourceUrl == null || sourceUrl.isEmpty) return false;
      final source = sources.byUrl(sourceUrl);
      if (source == null) return false;
      final info = await _service.fetchInfo(source, book.path);
      coverUrl = (info.coverUrl ?? '').trim().isEmpty
          ? null
          : info.coverUrl!.trim();
    }
    if (coverUrl == null || coverUrl.isEmpty) return false;

    final List<int>? bytes;
    String contentType = '';
    if (_download != null) {
      bytes = await _download(coverUrl);
    } else {
      final resp = await _client
          .get(
            Uri.parse(coverUrl),
            headers: const {'User-Agent': 'Mozilla/5.0'},
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return false;
      contentType = resp.headers['content-type'] ?? '';
      bytes = resp.bodyBytes;
    }
    if (bytes == null) return false;
    // 太小的多半是占位图 / 错误页；太大的不像是封面
    if (bytes.length < 1024 || bytes.length > 8 * 1024 * 1024) return false;

    final ext = _extOf(coverUrl, contentType);
    final dir = _coverDirOverride ?? store.coverDir;
    await dir.create(recursive: true);
    final file = File('${dir.path}/${book.id}.$ext');
    await file.writeAsBytes(bytes, flush: false);
    return store.setCover(book.id, file.path);
  }

  String _extOf(String url, String contentType) {
    final lower = url.toLowerCase();
    for (final ext in const ['jpg', 'jpeg', 'png', 'webp']) {
      if (lower.contains('.$ext')) return ext == 'jpeg' ? 'jpg' : ext;
    }
    if (contentType.contains('png')) return 'png';
    if (contentType.contains('webp')) return 'webp';
    return 'jpg';
  }

  void _tell() {
    unawaited(
      ImportForeground.updateTask(title: '嘤阅 · 正在更新封面', text: progressText),
    );
  }

  /// 阅读中就让路。
  Future<void> _waitWhileReading() async {
    if (!kReaderActive.value) {
      if (paused) {
        paused = false;
        notifyListeners();
      }
      return;
    }
    paused = true;
    notifyListeners();
    _tell();
    while (kReaderActive.value && !_cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    paused = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _service.dispose();
    _client.close();
    super.dispose();
  }
}
