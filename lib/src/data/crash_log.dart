// 崩溃 / 异常日志：出错时写本地文件，用户可以在设置里一键导出（0.50）。
//
// 只记最近 200KB，环形截断；不收集任何阅读内容，只有堆栈和时间。
import 'dart:io';

import 'package:flutter/foundation.dart';

class CrashLog {
  CrashLog({required this.file, this.maxBytes = 200 * 1024});

  static CrashLog? instance;

  final File file;
  final int maxBytes;

  /// 装上全局错误钩子（重复调用无副作用）。
  static void install(File file) {
    final log = instance = CrashLog(file: file);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.append('FlutterError', details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.append('PlatformError', error, stack);
      return false; // 让系统也崩（如果是 release 也会记录一条）
    };
    debugPrint('[crash] 日志已启用：${file.path}');
  }

  Future<void> append(String tag, Object error, StackTrace? stack) async {
    final now = DateTime.now().toIso8601String();
    final entry =
        '[$now] $tag: $error\n'
        '${stack?.toString() ?? '(no stack)'}\n'
        '----------------------------------------\n';
    try {
      await file.parent.create(recursive: true);
      // 超过上限就先砍掉前面一半，避免无限增长
      if (await file.exists() && await file.length() > maxBytes) {
        final text = await file.readAsString();
        final half = text.substring(text.length ~/ 2);
        await file.writeAsString(half);
      }
      await file.writeAsString(entry, mode: FileMode.append, flush: false);
    } catch (_) {
      // 记日志失败不能影响 App
    }
  }

  /// 读最后 [maxLines] 行（导出用）。
  Future<String> tail({int maxLines = 400}) async {
    try {
      if (!await file.exists()) return '';
      final lines = (await file.readAsString()).split('\n');
      if (lines.length <= maxLines) return lines.join('\n');
      return lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return '';
    }
  }
}
