// 桌宠 AI 台词的回归测试：清洗、截断、未配置/报错时的兜底。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sakura_read/src/data/ai_service.dart';
import 'package:sakura_read/src/data/pet_ai.dart';
import 'package:sakura_read/src/data/prefs.dart';

AppPrefs _prefs({String base = 'https://ca.130824.xyz:3824/v1', String model = 'deepseek-v4.1-flash'}) {
  final p = AppPrefs();
  p.aiBaseUrl = base;
  p.aiModel = model;
  p.aiApiKey = 'test-key';
  return p;
}

PetAi _ai(Future<http.Response> Function(http.Request) handler) =>
    PetAi(service: AiService(client: MockClient(handler)));

http.Response _reply(String content) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        },
      ],
    }),
  ),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('配置完整时：返回清洗后的单行台词', () async {
    late http.Request seen;
    final ai = _ai((req) async {
      seen = req;
      return _reply('「读到 63% 啦，我等你翻页～」\n');
    });

    final line = await ai.line(prefs: _prefs(), situation: '被戳了一下');

    expect(line, '读到 63% 啦，我等你翻页～');
    expect(seen.url.toString(), 'https://ca.130824.xyz:3824/v1/chat/completions');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['model'], 'deepseek-v4.1-flash');
    expect(body['messages'], isA<List>());
  });

  test('太长就截断成一行，末尾加省略号', () async {
    final long = '这是一句非常非常长的台词' * 8;
    final ai = _ai((req) async => _reply(long));
    final line = await ai.line(prefs: _prefs(), situation: '被摸头了');
    expect(line, isNotNull);
    expect(line!.length, lessThanOrEqualTo(40));
    expect(line.endsWith('…'), isTrue);
    expect(line.contains('\n'), isFalse);
  });

  test('模型回复带「小樱：」前缀会被去掉', () {
    expect(PetAi.tidy('小樱：今天也要读完一章哦'), '今天也要读完一章哦');
    expect(PetAi.tidy('  “好呀”  '), '好呀');
  });

  test('没配置接口 / 模型：直接返回 null（调用方回落本地台词）', () async {
    var called = false;
    final ai = _ai((req) async {
      called = true;
      return _reply('不该被调用');
    });
    final line = await ai.line(
      prefs: _prefs(base: '', model: ''),
      situation: '被戳了一下',
    );
    expect(line, isNull);
    expect(called, isFalse, reason: '没配置就不该发请求');
  });

  test('接口报错：返回 null，不抛异常', () async {
    final ai = _ai((req) async => http.Response('boom', 500));
    final line = await ai.line(prefs: _prefs(), situation: '被戳了一下');
    expect(line, isNull);
  });

  test('返回空内容：也算没有台词', () async {
    final ai = _ai((req) async => _reply('   '));
    expect(await ai.line(prefs: _prefs(), situation: '被戳了一下'), isNull);
  });
}
