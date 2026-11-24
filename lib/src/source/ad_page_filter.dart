// 漫画「广告页」过滤。
//
// 有的图片站在正文里插一张推广页（包子漫画就是：一张白底大字的「安装包子漫画 APP」
// + 一堆二维码）。它和正文页混在同一个图片列表里，光看 URL 区分不出来，
// 但尺寸上有稳定特征：**比正文页窄，而且特别长**（站点单独生成的一张 800 宽长图）。
//
// 做法：用 Range 只取每张图的前 24 KB 读尺寸（不下载整张图），
// 再按「最窄 + 比中位宽窄 5% 以上 + 高宽比 ≥ 1.55」判定为广告页。
// 探测失败（超时 / 站点不支持 Range）就原样保留，绝不误删正文。
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 一张图片的像素尺寸。
class ImagePixels {
  const ImagePixels(this.width, this.height);

  final int width;
  final int height;

  /// 高 / 宽。正文页一般 1.4~1.5；推广页接近 1.6 甚至更高。
  double get ratio => width <= 0 ? 0 : height / width;

  @override
  String toString() => '${width}x$height';

  @override
  bool operator ==(Object other) =>
      other is ImagePixels && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// 从图片头部字节里读出尺寸；认不出来就返回 null。
ImagePixels? parseImagePixels(Uint8List b) {
  if (b.length < 16) return null;
  // PNG：8 字节签名 + IHDR 长度(4) + 'IHDR' + width(4) + height(4)
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return ImagePixels(_be32(b, 16), _be32(b, 20));
  }
  // JPEG：扫到 SOF 段（FFC0~FFCF，跳过 C4/C8/CC）
  if (b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xD8 ||
          marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2) return null;
      final isSof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return ImagePixels(w, h);
      }
      i += 2 + len;
    }
    return null;
  }
  // WebP：RIFF....WEBP + 块
  if (b.length >= 16 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8X' && b.length >= 30) {
      final w = b[24] | (b[25] << 8) | (b[26] << 16);
      final h = b[27] | (b[28] << 8) | (b[29] << 16);
      return ImagePixels(w + 1, h + 1);
    }
    if (chunk == 'VP8L' && b.length >= 25) {
      // 0x2F 之后 14 位宽、14 位高（都存的是 -1）
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      final w = (bits & 0x3FFF) + 1;
      final h = ((bits >> 14) & 0x3FFF) + 1;
      return ImagePixels(w, h);
    }
    if (chunk == 'VP8 ' && b.length >= 30) {
      // 帧头 3 字节 + 同步码 9D 01 2A，然后 14 位宽 / 14 位高（小端）
      final w = (b[26] | (b[27] << 8)) & 0x3FFF;
      final h = (b[28] | (b[29] << 8)) & 0x3FFF;
      return ImagePixels(w, h);
    }
    return null;
  }
  // GIF
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return ImagePixels(b[6] | (b[7] << 8), b[8] | (b[9] << 8));
  }
  return null;
}

int _be32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

/// 探测每张图尺寸（只取前面的字节）。同一 URL 会缓存，翻回来不再重复请求。
class ImageProbe {
  ImageProbe({http.Client? client, this.rangeBytes = 24 * 1024})
    : _client = client ?? http.Client();

  final http.Client _client;
  final int rangeBytes;
  static final Map<String, ImagePixels> _cache = {};
  static const int _cacheLimit = 600;

  Future<Map<String, ImagePixels>> probe(
    List<String> urls, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final out = <String, ImagePixels>{
      for (final u in urls)
        if (_cache[u] != null) u: _cache[u]!,
    };
    final todo = [
      for (final u in urls)
        if (!_cache.containsKey(u)) u,
    ];
    if (todo.isEmpty) return out;

    final deadline = DateTime.now().add(timeout);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (DateTime.now().isAfter(deadline)) return;
        final i = next++;
        if (i >= todo.length) return;
        final u = todo[i];
        final px = await _one(u, timeout);
        if (px != null) {
          out[u] = px;
          _remember(u, px);
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    return out;
  }

  Future<ImagePixels?> _one(String url, Duration timeout) async {
    try {
      final resp = await _client
          .get(Uri.parse(url), headers: {'Range': 'bytes=0-${rangeBytes - 1}'})
          .timeout(timeout);
      if (resp.statusCode != 200 && resp.statusCode != 206) return null;
      return parseImagePixels(resp.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  static void _remember(String url, ImagePixels px) {
    if (_cache.length > _cacheLimit) _cache.clear();
    _cache[url] = px;
  }

  void dispose() => _client.close();
}

/// 按尺寸挑出广告页并剔除；看不出来就原样返回。
///
/// 判定：宽是这一话里最窄的、比中位宽窄 5% 以上、且高宽比 ≥ 1.55。
/// 这样正常的长条页（宽度和别的页一样）不会被误删。
List<String> dropAdPages(List<String> urls, Map<String, ImagePixels> sizes) {
  if (urls.length < 4) return urls;
  final widths = [
    for (final u in urls)
      if (sizes[u] != null) sizes[u]!.width,
  ]..sort();
  if (widths.length < 3) return urls;
  final median = widths[widths.length ~/ 2];
  final minWidth = widths.first;
  if (minWidth >= median * 0.95) return urls;
  return [
    for (final u in urls)
      if (!_looksLikeAd(sizes[u], minWidth, median)) u,
  ];
}

bool _looksLikeAd(ImagePixels? px, int minWidth, int median) {
  if (px == null) return false;
  if (px.width != minWidth) return false;
  if (px.width >= median * 0.95) return false;
  return px.ratio >= 1.55;
}
