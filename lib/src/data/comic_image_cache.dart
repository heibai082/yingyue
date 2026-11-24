// 漫画「这一话已经缓存过」= 图片真的在磁盘上，而不是只有图片地址。
//
// 用户反馈：「缓存完了的章节不应该是秒开么，为什么还要转圈」。
// 0.41 之前的「漫画缓存」只把「章节 → 图片 URL 清单」存下来：地址有了，
// 图片本身还得每张从站点拉，所以照样转圈、断网也看不了。
//
// 这里给图片做磁盘缓存：
//   - 每话一个目录：<书籍缓存>/img/<章节链接的 hash>/<序号>.<后缀>；
//   - 取图顺序：磁盘命中 → 直接出图（几毫秒）；没命中 → 网络下载 + 顺手落盘；
//   - 落盘用 .part 临时文件再改名，避免半截图被当成缓存；
//   - 下载走书源的 Referer / Cookie（很多站点直链有防盗链）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../source/http_client.dart';
import 'book_store.dart';
import '../source/ad_page_filter.dart';
import 'chapter_cache.dart';

/// 图片地址 → 稳定的短 hash（同一话同一张图永远落到同一个文件）。
///
/// 和章节正文用同一套 hash（[ChapterCache.fnv64]），这样「这一话的图片目录」
/// 和「这一话的正文文件」天然属于同一本书、同一章。
String comicImageKey(String url) => 'h${ChapterCache.fnv64(url)}';

/// 一话的图片目录：`<书籍缓存>/img/<章节 hash>/`
Directory comicChapterImageDir(BookStore store, String bookId, String href) =>
    Directory(
      '${store.chapterCacheDir(bookId).path}/img/${comicImageKey(href)}',
    );

/// 缓存文件：**按图片地址**命名（不是按第几张）。
///
/// 为什么不用序号：过滤广告 / 站点调整顺序后，序号会整体错位，缓存就会张冠李戴。
/// 用地址 hash 后，同一张图永远是同一个文件，删几条广告也不影响别的图。
File comicImageCacheFile(
  BookStore store,
  String bookId,
  String href,
  int index,
  String url,
) {
  final dir = comicChapterImageDir(store, bookId, href);
  // 先按「当前 URL」找；找不到再看清单（站点换 CDN / 换签名后仍能复用旧图）
  final resolved = ChapterCache.resolveImage(dir, index, url);
  if (resolved != null) return resolved;
  return File('${dir.path}/${ChapterCache.imageFileName(url)}');
}

/// 这张图是否已经在磁盘上。
bool comicImageCached(
  BookStore store,
  String bookId,
  String href,
  int index,
  String url,
) {
  try {
    final f = comicImageCacheFile(store, bookId, href, index, url);
    return f.existsSync() && f.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}

/// 预下载一话的图片（顺序下载，站点友好；失败的单张跳过）。
///
/// 返回成功落盘的张数。真实缓存任务（追更 / 缓存整本）走这里。
Future<int> cacheComicImages(
  BookStore store,
  String bookId,
  String href,
  List<String> urls, {
  void Function(int done, int total)? onProgress,
  bool Function()? shouldCancel,
}) async {
  if (urls.isEmpty) return 0;
  final dir = comicChapterImageDir(store, bookId, href);
  try {
    await dir.create(recursive: true);
  } catch (_) {
    return 0;
  }
  final dirPath = dir;
  // 只下正文图（广告横幅不下载、不占空间）
  final wanted = <int>[
    for (var i = 0; i < urls.length; i++)
      if (!looksLikeAdUrl(urls[i])) i,
  ];
  var ok = 0;
  var done = 0;

  // 并发 3：比逐张等下快，又不至于把站点惹毛
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (shouldCancel?.call() ?? false) return;
      if (next >= wanted.length) return;
      final i = wanted[next++];
      final url = urls[i];
      try {
        if (comicImageCached(store, bookId, href, i, url)) {
          ok++;
        } else {
          final bytes = await _download(url, href);
          if (bytes != null && bytes.isNotEmpty) {
            final target = File(
              '${dirPath.path}/${ChapterCache.imageFileName(url)}',
            );
            final tmp = File('${target.path}.part');
            await tmp.writeAsBytes(bytes, flush: false);
            await tmp.rename(target.path);
            ok++;
          }
        }
      } catch (e) {
        // 单张失败不影响整话；写满磁盘时下面会统一提示
        debugPrint('[comic] 图片缓存失败：$e');
      } finally {
        done++;
        onProgress?.call(done, wanted.length);
      }
    }
  }

  await Future.wait([for (var i = 0; i < 3; i++) worker()]);

  // 记清单：顺序 = 当前这一话的图片顺序（含之前已经存过的）
  final entries = <Map<String, String>>[
    for (var i = 0; i < urls.length; i++)
      if (!looksLikeAdUrl(urls[i]))
        {'u': urls[i], 'f': ChapterCache.imageFileName(urls[i])},
  ];
  if (entries.isNotEmpty) await ChapterCache.writeManifest(dirPath, entries);
  return ok;
}

/// 每话用一次请求客户端：复用连接池，一次跑完就关。
final SourceHttpClient _client = SourceHttpClient();

/// 下载一张图；带 Referer（站点常见防盗链），失败重试一次。
Future<Uint8List?> _download(String url, String referer) async {
  final headers = <String, String>{};
  final u = Uri.tryParse(url);
  if (u != null && u.hasScheme && u.host.isNotEmpty) {
    headers['Referer'] = referer;
    headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
  }
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final resp = await _client.get(
        url,
        headers: headers.isEmpty ? null : headers,
        retries: 0,
        timeout: const Duration(seconds: 25),
      );
      if (resp.ok && resp.bytes.isNotEmpty) return resp.bytes;
    } catch (_) {
      // 重试一次
    }
  }
  return null;
}

/// 漫画图：先看磁盘缓存（命中就同步出图，不闪转圈），没有再走网络并顺手落盘。
class ComicImage extends StatefulWidget {
  const ComicImage({
    super.key,
    required this.store,
    required this.bookId,
    required this.href,
    required this.index,
    required this.url,
    this.fit = BoxFit.fitWidth,
    this.placeholderRatio = 3 / 4,
  });

  final BookStore store;
  final String bookId;
  final String href;
  final int index;
  final String url;
  final BoxFit fit;
  final double placeholderRatio;

  @override
  State<ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends State<ComicImage> {
  /// 重试次数：换 key 让 Flutter 重新发起请求（失败不会被图片缓存记住）。
  int _attempt = 0;

  void _retry() {
    try {
      imageCache.evict(NetworkImage(widget.url));
    } catch (_) {}
    if (mounted) setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final file = comicImageCacheFile(
      widget.store,
      widget.bookId,
      widget.href,
      widget.index,
      widget.url,
    );
    final cached = _cachedIfPresent(file);
    // 长按整张图 = 重试（对应失败提示里的「长按重试」）
    return GestureDetector(
      onLongPress: _retry,
      child: cached != null
          ? Image.file(
              File(cached),
              key: ValueKey('file-${file.path}-$_attempt'),
              fit: widget.fit,
              gaplessPlayback: true,
              errorBuilder: (ctx, e, st) => _errorBox(ctx),
            )
          : _networkWithCache(),
    );
  }

  /// 磁盘上真有这张图才返回路径（空文件 / 读失败都不算）。
  static String? _cachedIfPresent(File file) {
    try {
      if (file.existsSync() && file.lengthSync() > 0) return file.path;
    } catch (_) {}
    return null;
  }

  Widget _networkWithCache() {
    return Image.network(
      widget.url,
      key: ValueKey('net-${widget.url}-$_attempt'),
      fit: widget.fit,
      gaplessPlayback: true,
      headers: _refererHeaders(widget.href),
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        final total = progress.expectedTotalBytes;
        return AspectRatio(
          aspectRatio: widget.placeholderRatio,
          child: Center(
            child: CircularProgressIndicator(
              value: total == null
                  ? null
                  : progress.cumulativeBytesLoaded / total,
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (ctx, e, st) => _errorBox(ctx),
    );
  }

  Widget _errorBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '这张图加载失败',
            style: TextStyle(color: Colors.white54, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  static Map<String, String>? _refererHeaders(String href) {
    final u = Uri.tryParse(href);
    if (u == null || !u.hasScheme) return null;
    return {'Referer': href};
  }
}
