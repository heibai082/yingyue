// AI 返回格式的兼容性测试：不同网关 / 推理模型回来的 JSON 长得不一样，
// 出现「模型没有返回内容」时，多半是这里没兜住。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sakura_read/src/data/ai_service.dart';
import 'package:sakura_read/src/data/prefs.dart';

AppPrefs _prefs() {
  final p = AppPrefs();
  p.aiBaseUrl = 'https://ca.130824.xyz:3824/v1';
  p.aiModel = 'deepseek-v4.1-flash';
  p.aiApiKey = 'k';
  return p;
}

AiService _svc(Map<String, dynamic> body) => AiService(
  client: MockClient(
    (req) async => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  ),
);

Future<String> _chat(AiService svc) =>
    svc.chat(prefs: _prefs(), history: const [AiTurn.user('hi')]);

void main() {
  test('标准形状：choices[0].message.content', () async {
    final svc = _svc({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': '你好呀'},
        },
      ],
    });
    expect(await _chat(svc), '你好呀');
  });

  test('推理模型：content 为空、只有 reasoning_content', () async {
    final svc = _svc({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': '', 'reasoning_content': '先想想……说句你好吧'},
          'finish_reason': 'stop',
        },
      ],
    });
    expect(await _chat(svc), '先想想……说句你好吧');
  });

  test('content 是多段数组（多模态风格）', () async {
    final svc = _svc({
      'choices': [
        {
          'message': {
            'content': [
              {'type': 'text', 'text': '你好'},
              {'type': 'text', 'text': '，很高兴见到你'},
            ],
          },
        },
      ],
    });
    expect(await _chat(svc), '你好，很高兴见到你');
  });

  test('老补全接口：choices[0].text', () async {
    final svc = _svc({
      'choices': [
        {'text': '老接口的回复'},
      ],
    });
    expect(await _chat(svc), '老接口的回复');
  });

  test('空内容 + finish_reason=length：明确提示被 max_tokens 截断', () async {
    final svc = _svc({
      'choices': [
        {'message': {'content': ''}, 'finish_reason': 'length'},
      ],
    });
    await expectLater(
      _chat(svc),
      throwsA(
        predicate((e) => e is AiException && e.message.contains('max_tokens')),
      ),
    );
  });

  test('真没内容：报错里带上返回片段，便于排查', () async {
    final svc = _svc({
      'choices': [],
      'usage': {'prompt_tokens': 3},
    });
    await expectLater(
      _chat(svc),
      throwsA(
        predicate(
          (e) => e is AiException &&
              e.message.contains('返回片段') &&
              e.message.contains('usage'),
        ),
      ),
    );
  });
test('网关拒绝 temperature（400）时自动去掉重试一次', () async {
    var calls = 0;
    final svc = AiService(
      client: MockClient((req) async {
        calls++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body.containsKey('temperature')) {
          return http.Response(
            '{"error":{"message":"temperature is not supported for this model"}}',
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '去掉了温度参数'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    expect(await _chat(svc), '去掉了温度参数');
    expect(calls, 2);
  });
}