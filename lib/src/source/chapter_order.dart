// 目录顺序归一化。
//
// 包子漫画这类站点会在目录最前面再列一遍「最新几话」（降序），后面才是完整列表
// （升序）。两条列表拼起来就会出现重复 + 顺序错乱：
//   [第1186话 … 第1163话] + [第1话 … 第1162话]
// 于是索引全部错位（用户点「第1152话」，阅读器却显示 1177/1187）。
//
// 这里按「章节序号」去重并统一排序；认不出序号的目录原样返回，绝不乱动。
import '../data/models.dart';

/// 取章节序号：优先链接里的 `chapter_slot=123` / 末尾数字，其次标题里的「第123话」。
int? chapterNumber(ChapterRef chapter) {
  final href = chapter.href ?? '';
  final slot = RegExp(
    r'chapter_slot=(\d+)',
    caseSensitive: false,
  ).firstMatch(href);
  if (slot != null) return int.tryParse(slot.group(1)!);
  final title = chapter.title;
  final cn = RegExp(r'第\s*(\d+)\s*[话話章集回卷篇]').firstMatch(title);
  if (cn != null) return int.tryParse(cn.group(1)!);
  final tail = RegExp(r'(\d+)(?!.*\d)').firstMatch(href);
  if (tail != null) return int.tryParse(tail.group(1)!);
  return null;
}

/// 归一化目录顺序。
///
/// - [newestFirst] 为 true（漫画）：按序号**降序**，同一序号只保留第一条；
/// - [newestFirst] 为 false（小说）：保持站点原顺序，只做相邻去重；
/// - 认不出序号的比例过高（<80%）：原样返回，避免把正常目录弄乱。
List<ChapterRef> normalizeChapterOrder(
  List<ChapterRef> chapters, {
  required bool newestFirst,
}) {
  if (chapters.length < 2) return chapters;

  final numbers = [for (final c in chapters) chapterNumber(c)];
  final known = numbers.where((n) => n != null).length;
  if (known < chapters.length * 0.8) return chapters;

  final out = <ChapterRef>[];
  final seenNumbers = <int>{};
  final seenHrefs = <String>{};
  for (var i = 0; i < chapters.length; i++) {
    final c = chapters[i];
    final href = c.href ?? '';
    final n = numbers[i];
    if (n != null) {
      if (!seenNumbers.add(n)) continue;
    } else if (href.isNotEmpty) {
      if (!seenHrefs.add(href)) continue;
    }
    out.add(c);
  }
  if (!newestFirst) return out;

  // 稳定的降序：序号相同（或都没序号）时保持原相对顺序
  final indexed = [
    for (var i = 0; i < out.length; i++)
      (i, out[i], chapterNumber(out[i]) ?? -(i + 1)),
  ];
  indexed.sort((a, b) {
    final byNum = b.$3.compareTo(a.$3);
    return byNum != 0 ? byNum : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// 这本书的目录看起来是不是「最新话在前」。用来决定要不要重排已存在的老数据。
bool looksNewestFirst(List<ChapterRef> chapters) {
  if (chapters.length < 2) return false;
  final first = chapterNumber(chapters.first);
  final last = chapterNumber(chapters.last);
  if (first == null || last == null) return false;
  return first > last;
}

/// 目录是「最新话在前」（漫画）时，往**更早**的话翻是索引 +1；
/// 小说那种「第1章在前」的正序则是 -1。
int olderStep(List<ChapterRef> chapters) => looksNewestFirst(chapters) ? 1 : -1;

/// 更早一话的索引（越界返回 null）。
int? olderIndex(List<ChapterRef> chapters, int index) {
  final i = index + olderStep(chapters);
  return (i >= 0 && i < chapters.length) ? i : null;
}

/// 更新一话的索引（越界返回 null）。
int? newerIndex(List<ChapterRef> chapters, int index) {
  final i = index - olderStep(chapters);
  return (i >= 0 && i < chapters.length) ? i : null;
}
