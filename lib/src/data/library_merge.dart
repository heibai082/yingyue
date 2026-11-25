// 备份恢复时的「增量合并」（0.50）：不再整包覆盖，避免双设备互相回退进度。
//
// 规则：
//   - 同一本书（按 path 认，在线书就是书页地址）两边都有 → 谁的 lastReadAt 新用谁的，
//     但分组 / 封面 / 缓存范围这些「用户设置」优先保留非空值；
//   - 只在一边有的书 → 保留（本地新加的书不会被备份冲掉）；
//   - 其它顶层字段：备份里的优先（设置以备份为准）。
import 'dart:convert';

Map<String, dynamic> mergeLibraryJson(
  Map<String, dynamic> current,
  Map<String, dynamic> incoming,
) {
  final currentBooks = _booksOf(current);
  final incomingBooks = _booksOf(incoming);
  final byKey = <String, Map<String, dynamic>>{};

  String keyOf(Map<String, dynamic> b) {
    final path = (b['path'] as String? ?? '').trim();
    if (path.isNotEmpty) return 'p:$path';
    return 'i:${b['id'] ?? ''}';
  }

  for (final b in currentBooks) {
    byKey[keyOf(b)] = b;
  }
  for (final b in incomingBooks) {
    final key = keyOf(b);
    final old = byKey[key];
    if (old == null) {
      byKey[key] = b;
      continue;
    }
    byKey[key] = _mergeBook(old, b);
  }

  return {...incoming, 'books': byKey.values.toList()};
}

Map<String, dynamic> _mergeBook(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final aTs = (a['lastReadAt'] as num?)?.toInt() ?? 0;
  final bTs = (b['lastReadAt'] as num?)?.toInt() ?? 0;
  final newer = bTs >= aTs ? b : a;
  final older = identical(newer, a) ? b : a;
  final merged = Map<String, dynamic>.from(newer);
  // 用户设置：新记录为空时用旧的补上（分组、封面、简介、缓存范围）
  for (final field in const ['group', 'coverPath', 'intro', 'cachePlan']) {
    final nv = merged[field];
    final ov = older[field];
    final empty = nv == null || (nv is String && nv.trim().isEmpty);
    if (empty && ov != null) merged[field] = ov;
  }
  return merged;
}

List<Map<String, dynamic>> _booksOf(Map<String, dynamic> data) {
  final raw = data['books'];
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

/// 测试/诊断用：把合并结果转回 JSON 字符串。
String encodeMergedLibrary(
  Map<String, dynamic> current,
  Map<String, dynamic> incoming,
) => jsonEncode(mergeLibraryJson(current, incoming));
