// 目录体检：缺章 / 重复 / 序号断层（0.50）。
//
// 只做「体检报告」，不自动改目录 —— 站点目录本来就常有 番外/卷 之类的跳号，
// 自动修反而危险；把问题摆出来，用户自己决定换源还是手动补。
import 'models.dart';

/// 一条体检发现。
class ChapterIssue {
  const ChapterIssue(this.kind, this.message);

  /// duplicate / gap / unknown / disorder
  final String kind;
  final String message;

  @override
  String toString() => message;
}

/// 目录体检结果。
class ChapterHealth {
  const ChapterHealth({
    required this.total,
    required this.issues,
    required this.knownNumbers,
  });

  final int total;
  final List<ChapterIssue> issues;

  /// 能认出序号的章数（占比太低时不报缺章，避免误报）。
  final int knownNumbers;

  bool get ok => issues.isEmpty;

  /// 给用户看的一句话。
  String get summary {
    if (total == 0) return '还没有目录';
    if (ok) return '目录正常（共 $total 章）';
    final parts = <String>[];
    final dup = issues.where((i) => i.kind == 'duplicate').length;
    final gap = issues.where((i) => i.kind == 'gap').length;
    if (dup > 0) parts.add('$dup 处重复');
    if (gap > 0) parts.add('$gap 处缺章');
    return '目录可疑：${parts.join('、')}（共 $total 章）';
  }
}

/// 体检一本书的目录。
ChapterHealth analyzeChapters(List<ChapterRef> chapters) {
  final total = chapters.length;
  if (total == 0) {
    return const ChapterHealth(total: 0, issues: [], knownNumbers: 0);
  }
  final numbers = <int?>[for (final c in chapters) chapterNumber(c)];
  final known = numbers.where((n) => n != null).length;
  final issues = <ChapterIssue>[];

  // 序号认得出来的比例太低 → 不判缺章，只提示「认不出序号」
  if (known * 10 < total * 8) {
    return ChapterHealth(
      total: total,
      knownNumbers: known,
      issues: [const ChapterIssue('unknown', '大部分章节认不出序号，无法检查缺章')],
    );
  }

  // 重复序号
  final seen = <int>{};
  final dup = <int>{};
  for (final n in numbers) {
    if (n == null) continue;
    if (!seen.add(n)) dup.add(n);
  }
  for (final n in dup.take(10)) {
    issues.add(ChapterIssue('duplicate', '第 $n 章出现了不止一次'));
  }

  // 断层：把序号排序后看相邻差
  final sorted = [
    for (final n in numbers)
      if (n != null) n,
  ]..sort();
  var gaps = 0;
  for (var i = 1; i < sorted.length; i++) {
    final diff = sorted[i] - sorted[i - 1];
    if (diff > 1) {
      gaps++;
      if (gaps <= 10) {
        issues.add(
          ChapterIssue(
            'gap',
            '第 ${sorted[i - 1] + 1}~${sorted[i] - 1} 章缺失'
                '（${diff - 1} 章）',
          ),
        );
      }
    }
  }
  return ChapterHealth(total: total, issues: issues, knownNumbers: known);
}
