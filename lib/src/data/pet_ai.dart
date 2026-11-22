// 桌宠的 AI 台词：配置了「小樱」的接口就让模型现编一句，否则/失败都回落本地台词。
//
// 为什么要单独一层：
//   - 桌宠台词出现频率高，必须有超时和兜底，绝不能让气泡卡住或抛异常；
//   - 气泡只放得下一行，模型输出要清洗、截断；
//   - 测试里可以注入 AiService（MockClient），不联网也能验证。
import 'dart:async';

import 'ai_service.dart';
import 'prefs.dart';

class PetAi {
  PetAi({AiService? service}) : _service = service ?? AiService();

  final AiService _service;

  /// 只保留一行、去掉引号与多余空白，太长就截断。
  static String tidy(String raw) {
    var s = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    s = s.replaceAll(RegExp(r'^["“”「『]+|["“”」』]+$'), '').trim();
    // 模型偶尔会带「小樱：」前缀
    s = s.replaceFirst(RegExp(r'^(小樱|我)\s*[:：]\s*'), '');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
    if (s.length > 40) s = '${s.substring(0, 39)}…';
    return s;
  }

  /// AI 是否配置完整（接口地址 + 模型名都有）。
  static bool configured(AppPrefs prefs) =>
      prefs.aiBaseUrl.trim().isNotEmpty && prefs.aiModel.trim().isNotEmpty;

  /// 现编一句台词；不可用 / 超时 / 出错都返回 null，让调用方用本地台词。
  Future<String?> line({
    required AppPrefs prefs,
    required String situation,
    ReadingSnapshot? snapshot,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!configured(prefs)) return null;
    try {
      final reply = await _service
          .chat(
            prefs: prefs,
            history: [
              AiTurn.user(
                '（桌宠互动：$situation）就这个瞬间只回一句话，'
                '20 字以内，口语化，不要列表、不要解释、不要引号。',
              ),
            ],
            snapshot: snapshot,
            maxTokens: 60,
          )
          .timeout(timeout);
      final text = tidy(reply);
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  void dispose() => _service.dispose();
}
