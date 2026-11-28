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

/// 把章节标题改成统一格式，方便排序/阅读：
///   `13回` → `第13回`；`第03卷番外` → `第03卷 番外`；`12` → `第12话`。
/// 认不出的（「序章」「番外1」）原样返回。
String canonicalChapterTitle(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  final withPrefix = RegExp(r'^第\s*(\d+(?:\.\d+)?)\s*([卷话話回章節节集部篇])\s*(.*)$')
      .firstMatch(t);
  if (withPrefix != null) {
    final num = withPrefix.group(1)!;
    final kind = withPrefix.group(2)!;
    final rest = (withPrefix.group(3) ?? '').trim();
    return '第$num$kind${rest.isEmpty ? '' : ' $rest'}';
  }
  final bare = RegExp(r'^(\d+(?:\.\d+)?)\s*([卷话話回章節节集部篇])?\s*(.*)$')
      .firstMatch(t);
  if (bare != null) {
    final num = bare.group(1)!;
    final kind = (bare.group(2) ?? '').isEmpty ? '话' : bare.group(2)!;
    final rest = (bare.group(3) ?? '').trim();
    return '第$num$kind${rest.isEmpty ? '' : ' $rest'}';
  }
  return raw;
}

/// 批量把目录标题规范化（原地改 title）。
void applyCanonicalTitles(List<ChapterRef> chapters) {
  for (final c in chapters) {
    final fixed = canonicalChapterTitle(c.title);
    if (fixed != c.title) c.title = fixed;
  }
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
  // 「卷 + 话」混在一起：无视类型，直接按 1、2、3… 升序
  final kinds = {for (final e in kept) chapterKind(e.chapter)};
  final mixedKinds = kinds.contains(0) && kinds.contains(1);
  if (mixedKinds) {
    final indexed = [
      for (var i = 0; i < kept.length; i++)
        (i, kept[i].chapter, kept[i].number),
    ];
    indexed.sort((a, b) {
      final byNum = a.$3.compareTo(b.$3);
      return byNum != 0 ? byNum : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  if (!newestFirst) return [for (final e in kept) e.chapter];

  // 单一类型（纯话 / 纯章）：漫画仍按最新话在前
  final indexed = [
    for (var i = 0; i < kept.length; i++) (i, kept[i].chapter, kept[i].number),
  ];
  indexed.sort((a, b) {
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
