// 目录顺序归一化。
//
// 站点常见两种乱法：
//   1. 包子漫画：最新几话在目录最前面再列一遍（降序 + 完整升序）→ 重复 + 错位；
//   2. 漫画团这类：卷 / 话混排，站点顺序是「第10卷、第09卷、第08卷、第41话…」
//      还夹着「第07卷」，不排序看着就是乱的。
//
// 处理：
//   - 按「类型 + 序号」去重（第1卷 和 第1话 是两条，不能互相吃掉）；
//   - 漫画（newestFirst）：先按类型分组（卷 → 话/回/章 → 其它数字 → 没数字），
//     组内按序号降序；小说保持站点原顺序，只去重；
//   - 认不出序号的比例过高（<80%）原样返回，避免把正常目录弄乱。
import '../data/models.dart';

// chapterNumber / looksNewestFirst 现在住在 models.dart（Book.progress 也要用），
// 这里原样转出去，老的 import 不用改。
export '../data/models.dart' show chapterNumber, looksNewestFirst;

final _volumeRe = RegExp('卷');
final _chapterRe = RegExp('[话話回章節节集部篇]');

/// 0 = 卷，1 = 话/回/章…，2 = 其它（有数字）
int chapterKind(ChapterRef c) {
  final t = c.title;
  if (_volumeRe.hasMatch(t)) return 0;
  if (_chapterRe.hasMatch(t)) return 1;
  return 2;
}

/// 归一化目录顺序。
List<ChapterRef> normalizeChapterOrder(
  List<ChapterRef> chapters, {
  required bool newestFirst,
}) {
  if (chapters.length < 2) return chapters;

  final numbers = [for (final c in chapters) chapterNumber(c)];
  final known = numbers.where((n) => n != null).length;
  if (known < chapters.length * 0.8) return chapters;

  // 去重：有序号按「类型:序号」，没序号按链接
  final kept = <({ChapterRef chapter, int number})>[];
  final seenKeys = <String>{};
  final seenHrefs = <String>{};
  for (var i = 0; i < chapters.length; i++) {
    final c = chapters[i];
    final n = numbers[i];
    if (n != null) {
      if (!seenKeys.add('${chapterKind(c)}:$n')) continue;
      kept.add((chapter: c, number: n));
    } else {
      final href = c.href ?? '';
      if (href.isNotEmpty && !seenHrefs.add(href)) continue;
      kept.add((chapter: c, number: -1));
    }
  }
  if (!newestFirst) return [for (final e in kept) e.chapter];

  // 漫画：类型分组 + 组内降序（同序号的保持原相对顺序）
  final indexed = [
    for (var i = 0; i < kept.length; i++) (i, kept[i].chapter, kept[i].number),
  ];
  indexed.sort((a, b) {
    final kindA = chapterKind(a.$2);
    final kindB = chapterKind(b.$2);
    if (kindA != kindB) return kindA.compareTo(kindB);
    final byNum = b.$3.compareTo(a.$3);
    return byNum != 0 ? byNum : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
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
