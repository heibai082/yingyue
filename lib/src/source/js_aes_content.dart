// 漫画源里的「<js> + params + AES」解密（漫画团这类站点）。
//
// 这类源的正文规则不是 CSS，而是一段 JS：从页面里取 `params='...'`（base64），
// 前 16 字节是 IV、后面是密文，用规则里写死的 key 做 AES/CBC/PKCS5 解密，
// 得到 JSON：{ chapter_images: [...], images_hosts: [...] }。
//
// App 侧没有 `Packages.java.*`（那是 QuickJS/Rhino 的东西），所以这里用 Dart
// 直接实现同一套逻辑，规则里是否带这种模式由 `looksLikeAesComicRule` 判断。
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 规则是不是「params + AES 漫画解密」这一类。
bool looksLikeAesComicRule(String rule) {
  final lower = rule.toLowerCase();
  return lower.contains('<js>') &&
      lower.contains('chapter_images') &&
      (lower.contains('aes') || lower.contains('cipher'));
}

String? _extractKey(String rule) {
  final m = RegExp(
    r'''(?:java\.lang\.String|SecretKeySpec)\(\s*['"]([^'"]+)['"]''',
  ).firstMatch(rule);
  return m?.group(1);
}

Uint8List _decryptAesCbc(Uint8List key, Uint8List iv, Uint8List cipherText) {
  final cipher = CBCBlockCipher(AESEngine());
  cipher.init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  final out = Uint8List(cipherText.length);
  for (var offset = 0; offset < cipherText.length; offset += 16) {
    cipher.processBlock(cipherText, offset, out, offset);
  }
  // PKCS7 去填充
  final pad = out.isEmpty ? 0 : out.last;
  if (pad <= 0 || pad > 16) return out;
  return Uint8List.sublistView(out, 0, out.length - pad);
}

/// JS 字符串里的转义（`\/`、`\u002b`、`\n`）。
String _unescapeJsString(String s) {
  var out = s.replaceAll(r'\/', '/');
  out = out.replaceAllMapped(
    RegExp(r'\\u([0-9a-fA-F]{4})'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  out = out.replaceAll(r'\n', '').replaceAll(r'\r', '');
  return out;
}

/// 解出这一话的图片地址；失败返回空列表（交给上层兜底）。
List<String> decodeAesComicImages(
  String rule,
  String html, {
  required String baseUrl,
}) {
  final key = _extractKey(rule);
  if (key == null) return const [];
  final m = RegExp(r"""params\s*=\s*['"]([^'"]+)['"]""").firstMatch(html);
  if (m == null) return const [];
  final b64 = _unescapeJsString(m.group(1)!);
  final Uint8List raw;
  try {
    raw = base64Decode(base64.normalize(b64));
  } catch (_) {
    return const [];
  }
  if (raw.length <= 32) return const [];
  final iv = Uint8List.sublistView(raw, 0, 16);
  final body = Uint8List.sublistView(raw, 16);
  Map<String, dynamic> data;
  try {
    final plain = _decryptAesCbc(
      Uint8List.fromList(utf8.encode(key)),
      iv,
      body,
    );
    final decoded = jsonDecode(utf8.decode(plain, allowMalformed: true));
    if (decoded is! Map) return const [];
    data = Map<String, dynamic>.from(decoded);
  } catch (_) {
    return const [];
  }
  final images = (data['chapter_images'] as List?) ?? const [];
  final hosts = (data['images_hosts'] as List?) ?? const [];
  final host = hosts.isEmpty
      ? ''
      : hosts.first.toString().replaceAll(RegExp(r'/+$'), '');
  final out = <String>[];
  for (final item in images) {
    var u = item.toString();
    if (!u.startsWith('http')) {
      if (host.isNotEmpty) {
        u = '$host/${base64Encode(utf8.encode(u))}';
      } else {
        u = Uri.parse(baseUrl).resolve(u).toString();
      }
    }
    out.add(u);
  }
  return out;
}
