import 'dart:io';

import 'package:flutter/services.dart';

/// 把一段文本交给系统分享面板（微信 / QQ / 蓝牙 / 备忘录都能收）。
///
/// 走项目自有的 `sakuramanga/native` 通道，不引第三方插件。
/// 返回 true = 已唤起分享面板；false = 当前平台不支持或没有可接收的应用
/// （调用方可以退回「复制到剪贴板」）。
Future<bool> shareText(String text, {String? title}) async {
  if (!Platform.isAndroid || text.trim().isEmpty) return false;
  try {
    final ok = await const MethodChannel(
      'sakuramanga/native',
    ).invokeMethod<bool>('shareText', {'text': text, 'title': title ?? '分享'});
    return ok ?? false;
  } catch (_) {
    return false;
  }
}
