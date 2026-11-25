// 书签 / 笔记导出 Markdown（0.50）。
import 'dart:convert';
import 'dart:io';

import 'export_dirs.dart';
import 'stats_store.dart';

/// 生成 Markdown（按书分组、按章节顺序；没有书名的用 bookId 兜底）。
String buildBookmarksMarkdown(
  List<Bookmark> items, {
  Map<String, String> bookNames = const {},
}) {
  if (items.isEmpty) return '# 书签与笔记\n\n（还没有书签）\n';
  final byBook = <String, List<Bookmark>>{};
  for (final b in items) {
    byBook.putIfAbsent(b.bookId, () => []).add(b);
  }
  final buffer = StringBuffer()
    ..writeln('# 书签与笔记')
    ..writeln();
  buffer.writeln(
    '> 导出自嘤阅 · ${items.length} 条 · '
    '${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ')}',
  );
  buffer.writeln();
  for (final entry in byBook.entries) {
    final name = bookNames[entry.key] ?? entry.key;
    buffer
      ..writeln('## $name')
      ..writeln();
    final list = entry.value
      ..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    for (final b in list) {
      final title = b.chapterTitle.trim().isEmpty
          ? '第 ${b.chapterIndex + 1} 章'
          : b.chapterTitle.trim();
      final time = DateTime.fromMillisecondsSinceEpoch(b.createdAt);
      buffer
        ..writeln('### $title')
        ..writeln()
        ..writeln('- 位置：第 ${b.chapterIndex + 1} 章，第 ${b.charOffset} 字')
        ..writeln(
          '- 收藏于：${time.year}-'
          '${time.month.toString().padLeft(2, '0')}-'
          '${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}',
        );
      final excerpt = b.excerpt.trim();
      if (excerpt.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln('> ${excerpt.replaceAll('\n', '\n> ')}');
      }
      buffer.writeln();
    }
  }
  return buffer.toString();
}

/// 导出到文件，返回路径。
Future<String> exportBookmarksMarkdown(
  List<Bookmark> items, {
  Map<String, String> bookNames = const {},
  String? dirOverride,
  String? filesFallback,
}) async {
  final dir = await resolveExportDir(
    dirOverride: dirOverride,
    filesFallback: filesFallback,
  );
  final name = '书签-${DateTime.now().toIso8601String().substring(0, 10)}.md';
  final file = File('${dir.path}/$name');
  await file.writeAsString(
    buildBookmarksMarkdown(items, bookNames: bookNames),
    encoding: utf8,
  );
  return file.path;
}
