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
  final ext = _imageExt(url);
  final name = comicImageKey(url);
  return File('${comicChapterImageDir(store, bookId, href).path}/$name$ext');
}

/// 从 URL 猜图片后缀（站点常在路径上带 .jpg / .webp）。
String _imageExt(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  for (final ext in const ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif']) {
    if (path.endsWith(ext)) return ext == '.jpeg' ? '.jpg' : ext;
  }
  return '.jpg';
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
}) async {
  if (urls.isEmpty) return 0;
  final dir = comicChapterImageDir(store, bookId, href);
  try {
    await dir.create(recursive: true);
  } catch (_) {
    return 0;
  }
  var ok = 0;
  for (var i = 0; i < urls.length; i++) {
    if (looksLikeAdUrl(urls[i])) continue; // 广告横幅不下载、不占空间
    if (comicImageCached(store, bookId, href, i, urls[i])) {
      ok++;
      onProgress?.call(i + 1, urls.length);
      continue;
    }
    final bytes = await _download(urls[i], href);
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final target = comicImageCacheFile(store, bookId, href, i, urls[i]);
        final tmp = File('${target.path}.part');
        await tmp.writeAsBytes(bytes, flush: false);
        await tmp.rename(target.path);
        ok++;
      } catch (_) {}
    }
    onProgress?.call(i + 1, urls.length);
  }
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
class ComicImage extends StatelessWidget {
  const ComicImage({
    super.key,
    required this.store,
    required this.bookId,
    required this.href,
    required this.index,
    required this.url,
    this.fit = BoxFit.fitWidth,
    this.placeholderRatio = 3 / 4,
    this.errorBuilder,
  });

  final BookStore store;
  final String bookId;
  final String href;
  final int index;
  final String url;
  final BoxFit fit;
  final double placeholderRatio;
  final Widget Function(BuildContext, Object)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final file = comicImageCacheFile(store, bookId, href, index, url);
    final cached = _cachedIfPresent(file);
    final image = cached != null
        // 本地文件：首帧就有，不需要 loadingBuilder
        ? Image.file(
            File(cached),
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: errorBuilder == null
                ? null
                : (ctx, e, st) => errorBuilder!(ctx, e),
          )
        : _networkWithCache(context);
    return image;
  }

  /// 磁盘上真有这张图才返回路径（空文件 / 读失败都不算）。
  static String? _cachedIfPresent(File file) {
    try {
      if (file.existsSync() && file.lengthSync() > 0) return file.path;
    } catch (_) {}
    return null;
  }

  Widget _networkWithCache(BuildContext context) {
    return Image.network(
      url,
      fit: fit,
      gaplessPlayback: true,
      headers: _refererHeaders(href),
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        final total = progress.expectedTotalBytes;
        return AspectRatio(
          aspectRatio: placeholderRatio,
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
      errorBuilder: errorBuilder == null
          ? null
          : (ctx, e, st) => errorBuilder!(ctx, e),
    );
  }

  static Map<String, String>? _refererHeaders(String href) {
    final u = Uri.tryParse(href);
    if (u == null || !u.hasScheme) return null;
    return {'Referer': href};
  }
}

/// 给阅读页 / 追更用的「这一话有多少张图已经在本地」统计。
Future<int> comicCachedCount(
  BookStore store,
  String bookId,
  String href,
  List<String> urls,
) async {
  var n = 0;
  for (var i = 0; i < urls.length; i++) {
    if (comicImageCached(store, bookId, href, i, urls[i])) n++;
  }
  return n;
}
