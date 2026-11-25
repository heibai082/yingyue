// 导出目录解析（0.50）：优先外部存储 Download/嘤阅导出，失败退回 App 私有目录。
import 'dart:io';

import '../platform/native_bridge.dart';

/// 解析一个可写的导出目录。
Future<Directory> resolveExportDir({
  String? dirOverride,
  String? filesFallback,
}) async {
  final candidates = <String>[];
  if (dirOverride != null) candidates.add(dirOverride);
  try {
    final root = await NativeBridge.storageRoot();
    if (root.isNotEmpty) candidates.add('$root/Download/嘤阅导出');
  } catch (_) {}
  if (filesFallback != null) candidates.add(filesFallback);
  for (final path in candidates) {
    try {
      final dir = Directory(path);
      await dir.create(recursive: true);
      final probe = File('${dir.path}/.write_test');
      await probe.writeAsString('ok');
      await probe.delete();
      return dir;
    } catch (_) {}
  }
  throw StateError('找不到可写的导出目录');
}

/// 文件名安全化（去掉路径分隔符等）。
String safeFileName(String raw, {String fallback = 'export'}) {
  final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return cleaned.isEmpty ? fallback : cleaned;
}
