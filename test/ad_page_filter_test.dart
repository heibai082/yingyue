// 漫画广告页过滤：尺寸解析 + 「又窄又长就是推广页」的判定。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/ad_page_filter.dart';

Uint8List _png(int w, int h) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add([0, 0, 0, 13]);
  b.add('IHDR'.codeUnits);
  b.add([(w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF]);
  b.add([(h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF]);
  b.add([8, 6, 0, 0, 0]);
  return b.toBytes();
}

Uint8List _jpeg(int w, int h) {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, // APP0（占位）
    0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0 + 长度 + 精度
    (h >> 8) & 0xFF, h & 0xFF,
    (w >> 8) & 0xFF, w & 0xFF,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ]);
}

Uint8List _webpLossless(int w, int h) {
  final bits = ((w - 1) & 0x3FFF) | (((h - 1) & 0x3FFF) << 14);
  final b = <int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x00, 0x00, 0x00, 0x00, // size
    0x57, 0x45, 0x42, 0x50, // WEBP
    0x56, 0x50, 0x38, 0x4C, // VP8L
    0x00, 0x00, 0x00, 0x00, // chunk size
    0x2F, // signature
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
  ];
  return Uint8List.fromList(b);
}

void main() {
  group('尺寸解析', () {
    test('PNG', () {
      expect(parseImagePixels(_png(970, 1416)), const ImagePixels(970, 1416));
    });

    test('JPEG（SOF0）', () {
      expect(parseImagePixels(_jpeg(800, 1293)), const ImagePixels(800, 1293));
    });

    test('WebP（VP8L 无损）', () {
      expect(
        parseImagePixels(_webpLossless(850, 1441)),
        const ImagePixels(850, 1441),
      );
    });

    test('认不出来就返回 null（不抛异常）', () {
      expect(parseImagePixels(Uint8List.fromList([1, 2, 3])), isNull);
      expect(parseImagePixels(Uint8List(40)), isNull);
    });
  });

  group('广告页判定', () {
    List<String> urls(int n) => [for (var i = 1; i <= n; i++) 'u$i'];

    test('包子漫画 1180 话：正文 970 宽，第 2 张 800×1293 → 只删第 2 张', () {
      final us = urls(18);
      final sizes = <String, ImagePixels>{
        for (var i = 0; i < 18; i++) us[i]: const ImagePixels(970, 1416),
      };
      sizes[us[1]] = const ImagePixels(800, 1293);
      sizes[us[4]] = const ImagePixels(1280, 1869); // 彩页：更宽，不算广告
      final kept = dropAdPages(us, sizes);
      expect(kept, hasLength(17));
      expect(kept.contains(us[1]), isFalse);
      expect(kept.contains(us[4]), isTrue, reason: '更宽的彩页要留着');
    });

    test('包子漫画 1100 话：正文 850 宽 + 850×1441 的长页，只删 800×1356', () {
      final us = urls(18);
      final sizes = <String, ImagePixels>{
        for (var i = 0; i < 18; i++) us[i]: const ImagePixels(850, 1241),
      };
      sizes[us[1]] = const ImagePixels(800, 1356);
      sizes[us[14]] = const ImagePixels(850, 1441); // 又长又不窄：正文
      final kept = dropAdPages(us, sizes);
      expect(kept, hasLength(17));
      expect(kept.contains(us[1]), isFalse);
      expect(kept.contains(us[14]), isTrue, reason: '宽的和别人一样的长页是正文');
    });

    test('尺寸都一样时不删任何东西', () {
      final us = urls(10);
      final sizes = <String, ImagePixels>{
        for (final u in us) u: const ImagePixels(970, 1416),
      };
      expect(dropAdPages(us, sizes), hasLength(10));
    });

    test('探测失败（尺寸缺失）就原样保留', () {
      final us = urls(10);
      expect(dropAdPages(us, const {}), hasLength(10));
    });

    test('页数太少（<4）不折腾', () {
      final us = urls(3);
      final sizes = <String, ImagePixels>{
        us[0]: const ImagePixels(970, 1416),
        us[1]: const ImagePixels(800, 1400),
        us[2]: const ImagePixels(970, 1416),
      };
      expect(dropAdPages(us, sizes), hasLength(3));
    });
  });
}
