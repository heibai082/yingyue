// 缓存范围 → 具体要下哪几章（纯函数，无 IO，方便单测）。
//
// 用户反馈：「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从当前章节
// 缓存到最新（并且开启自动追剧模式缓存）」。
//
// 四种范围的区别只在「选中哪些章 + 先下哪几章」：
//   - 全部：整本都下（老的「缓存整本」）；
//   - 从当前章到最新：只下「往后」的部分，前面读过的不管；新章出来继续补；
//   - 一段区间：只要第 X~Y 章；
//   - 不缓存：本章集会空，调用方据此关掉预取。
//
// ⚠️ 「往后」要按**阅读顺序**算，不是按索引大小：
//   漫画目录是「最新话在前」（降序），索引 0 才是最新的一话。第 35 话在
//   索引 1152 上，「从第 35 话到最新」= 索引 [1152..1186] 这 35 话。
//   （0.41 第一版错写成 [0..1152] = 第 1~35 话，于是进度条一下就到 97%。）
//
// 下载顺序统一是「离要读的地方近的先下」：
//   全部 → 当前章之后（按阅读方向）优先，再回头补前面的；
//   从当前 → 最新章优先（追更最先看到的就是新章），再往回补到起点。
import '../source/chapter_order.dart';
import 'models.dart';

/// 一次缓存任务的下载计划。
class CacheDownloadPlan {
  const CacheDownloadPlan({
    required this.indices,
    required this.range,
    required this.plan,
  });

  /// 还没缓存、本次要下的章节序号（已按优先级排好）。
  final List<int> indices;

  /// 范围内的全部章节序号（升序，含已缓存的）。
  final List<int> range;

  /// 生成这份计划的缓存偏好。
  final BookCachePlan plan;

  bool get isEmpty => indices.isEmpty;

  /// 范围内已经缓存好的章数。
  int get cachedInRange => range.length - indices.length;

  /// 范围内总章数。
  int get total => range.length;

  /// 范围里最靠「最新」的那一章的序号（降序目录是 0）。
  int get newestIndex =>
      range.isEmpty ? 0 : (range.first < range.last ? range.first : range.last);

  /// 范围里最靠「最旧」的那一章的序号。
  int get oldestIndex =>
      range.isEmpty ? 0 : (range.first < range.last ? range.last : range.first);
}

/// 计算这本书按当前缓存偏好要下哪些章、按什么顺序下。
///
/// - [cached]：已缓存正文的章节序号（Book.chapterCache）；
/// - [anchor]：默认 0 = 用阅读进度（book.safeChapterIndex）；
/// - [newestFirst]：目录是不是「最新话在前」（漫画）；不传就按目录判断。
CacheDownloadPlan buildCachePlan(
  Book book, {
  Set<int>? cached,
  int? anchor,
  bool? newestFirst,
  BookCachePlan? plan,
}) {
  final total = book.chapterCount;
  final cfg = plan ?? book.cachePlan;
  if (total == 0 || cfg.isOff) {
    return CacheDownloadPlan(indices: const [], range: const [], plan: cfg);
  }

  final newest = newestFirst ?? looksNewestFirst(book.chapters);
  final have = cached ?? book.chapterCache;
  final current = (anchor ?? book.safeChapterIndex).clamp(0, total - 1);

  // 1) 范围内的章节区间 [lo, hi]（按目录索引升序；阅读方向留给排优先级）
  int lo;
  int hi;
  switch (cfg.mode) {
    case CacheMode.all:
      lo = 0;
      hi = total - 1;
    case CacheMode.off:
      lo = 1;
      hi = 0;
    case CacheMode.from:
      final from = (cfg.start ?? current).clamp(0, total - 1);
      if (newest) {
        // 降序目录（漫画）：第 N 话在索引 from。阅读时「往后」是第 N+1 话、
        // N+2 话……它们比第 N 话**新**，所以索引比 from 小；最新的一话在索引 0。
        // 于是「从第 N 话到最新」= [0..from]（第 35 话 → 索引 1152，共 1153 话），
        // 也就是自己这一话 + 比它新的全部。
        lo = 0;
        hi = from;
      } else {
        lo = from;
        hi = total - 1;
      }
    case CacheMode.range:
      final a = (cfg.start ?? 0).clamp(0, total - 1);
      final b = cfg.end == null ? total - 1 : cfg.end!.clamp(0, total - 1);
      lo = a < b ? a : b;
      hi = a < b ? b : a;
  }

  // 降序目录里「阅读往后」= 索引变小，所以起点之后（更新）的那一头是 lo；
  // 正序目录里「阅读往后」= 索引变大，是 hi。下面统一用阅读方向走。

  final range = [for (var i = lo; i <= hi; i++) i];
  final pending = {
    for (final i in range)
      if (!have.contains(i)) i,
  };
  if (pending.isEmpty) {
    return CacheDownloadPlan(indices: const [], range: range, plan: cfg);
  }

  // 2) 排优先级：一律按「阅读顺序」想问题
  //    newestFirst=false：索引越大越新；newestFirst=true：索引越小越新。
  final newerStep = newest ? -1 : 1;
  final olderStep = -newerStep;
  final newestFirstIndex = newest ? lo : hi;

  final order = <int>[];
  final seen = <int>{};
  void take(int i) {
    if (i >= lo && i <= hi && pending.contains(i) && seen.add(i)) order.add(i);
  }

  switch (cfg.mode) {
    case CacheMode.all:
      // 当前章 → 最新（顺着阅读方向），再回头补前面的
      for (var i = current; i >= lo && i <= hi; i += newerStep) {
        take(i);
      }
      for (var i = current + olderStep; i >= lo && i <= hi; i += olderStep) {
        take(i);
      }
    case CacheMode.from:
      // 追更最先要的是新章：从最靠「最新」的那头开始，往回补到起点为止
      final newestSide = newest ? hi : lo;
      for (var i = newestFirstIndex; i >= lo && i <= hi; i += olderStep) {
        take(i);
        if (i == newestSide) break;
      }
    case CacheMode.range:
      // 固定区间：按阅读顺序（最新那头先下）
      for (var i = newestFirstIndex; i >= lo && i <= hi; i += olderStep) {
        take(i);
      }
    case CacheMode.off:
      break;
  }
  // 兜底：区间里若有没被上面覆盖到的，按阅读顺序补上
  for (var i = newestFirstIndex; i >= lo && i <= hi; i += olderStep) {
    take(i);
  }

  return CacheDownloadPlan(indices: order, range: range, plan: cfg);
}

/// 追更：找出「站点新目录里有、现有目录里没有」的章节（保持站点顺序）。
///
/// 只认链接（href）——站点改一次章节地址就换一批，靠标题会误判重名。
/// 老数据可能没有 href，退一步按标题认。
List<ChapterRef> newChaptersOf(
  List<ChapterRef> current,
  List<ChapterRef> fresh,
) {
  final known = <String>{};
  for (final c in current) {
    final href = (c.href ?? '').trim();
    if (href.isNotEmpty) {
      known.add(href);
    } else if (c.title.trim().isNotEmpty) {
      known.add('t:${c.title.trim()}');
    }
  }
  final added = <ChapterRef>[];
  for (final c in fresh) {
    final href = (c.href ?? '').trim();
    final key = href.isNotEmpty ? href : 't:${c.title.trim()}';
    if (key.isEmpty || !known.add(key)) continue;
    added.add(c);
  }
  return added;
}

/// 把新章节并入目录（保持目录方向）。
///
/// 降序目录（漫画，最新话在前）→ 新章插到最前面；正序目录 → 追加到末尾。
List<ChapterRef> appendNewChapters(
  List<ChapterRef> current,
  List<ChapterRef> added, {
  required bool newestFirst,
}) => newestFirst ? [...added, ...current] : [...current, ...added];
