// 0.60：漫画源 <js>+AES 解密（App 侧）测试
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:sakura_read/src/source/js_aes_content.dart';

Uint8List _encrypt(Uint8List key, Uint8List iv, Uint8List plain) {
  final cipher = CBCBlockCipher(AESEngine());
  cipher.init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  final pad = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + pad)
    ..setRange(0, plain.length, plain);
  for (var i = plain.length; i < padded.length; i++) {
    padded[i] = pad;
  }
  final out = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, out, offset);
  }
  return out;
}

void main() {
  test('能把 params + AES 的漫画页解成图片地址', () {
    const key = '5V&RoR%Jf@pJPydF';
    final iv = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final payload = {
      'chapter_images': ['/a.jpg', 'http://host.example/b.jpg'],
      'images_hosts': ['https://img.example'],
    };
    final ct = _encrypt(
      Uint8List.fromList(utf8.encode(key)),
      iv,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    final params = base64Encode([...iv, ...ct]);
    final html =
        "<html><script>var config={}, params = '$params';</script></html>";
    final rule =
        "<js>(function(){var key=new Packages.java.lang.String('$key').getBytes('UTF-8');"
        "var c=Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');"
        "var d=JSON.parse(c);return d.chapter_images;})()</js>";

    expect(looksLikeAesComicRule(rule), isTrue);
    final urls = decodeAesComicImages(
      rule,
      html,
      baseUrl: 'https://site.com/ch/1',
    );
    expect(urls, hasLength(2));
    expect(urls[0], startsWith('https://img.example/'));
    expect(base64Decode(urls[0].split('/').last), utf8.encode('/a.jpg'));
    expect(urls[1], 'http://host.example/b.jpg');
  });

  test('普通规则 / 没有 params 时不乱解', () {
    expect(looksLikeAesComicRule('id.content@text'), isFalse);
    expect(
      decodeAesComicImages(
        '<js>var x=1</js>',
        '<html></html>',
        baseUrl: 'https://x',
      ),
      isEmpty,
    );
  });
}
