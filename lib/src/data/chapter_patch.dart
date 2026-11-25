// 「这一章抓不到」时用别的书源补进来（0.50）。
//
// 不换书、不动目录：只把同一章号的正文从别的源抓回来，写进当前这本书的缓存，
// 所以阅读进度、书签、缓存范围全都不受影响。
import '../source/online_book_service.dart';
import '../source/chapter_order.dart';
import '../source/online_repo.dart';
import '../source/source_store.dart';
import 'book_store.dart';
import 'models.dart';

/// 另一个源里找到的同一章。
ChapterRef? pickChapterByNumber(List<ChapterRef> chapters, int number) {
  if (chapters.isEmpty) return null;
  for (final c in chapters) {
    if (chapterNumber(c) == number) return c;
  }
  // 序号认不出：退回「按位置」——正序取第 number-1 个，降序取倒数
  final idx = number - 1;
  if (indexedOk(chapters, idx)) {
    final newestFirst = looksNewestFirst(chapters);
    final i = newestFirst ? chapters.length - 1 - idx : idx;
    if (i >= 0 && i < chapters.length) return chapters[i];
  }
  return null;
}

bool indexedOk(List<ChapterRef> chapters, int idx) =>
    idx >= 0 && idx < chapters.length;

/// 补章结果。
class ChapterPatchResult {
  const ChapterPatchResult({required this.ok, this.sourceName, this.message});

  final bool ok;
  final String? sourceName;
  final String? message;
}

/// 用其它书源补一章正文。
class ChapterPatcher {
  ChapterPatcher({
    required this.store,
    required this.sources,
    OnlineRepo? repo,
    OnlineBookService? service,
  }) : _repo = repo ?? OnlineRepo(store: sources),
       _service = service ?? OnlineBookService();

  final BookStore store;
  final SourceStore sources;
  final OnlineRepo _repo;
  final OnlineBookService _service;

  /// 最多试几个候选，避免一次点下去跑十分钟。
  static const int maxCandidates = 4;

  Future<ChapterPatchResult> patchChapter(Book book, int index) async {
    if (index < 0 || index >= book.chapters.length) {
      return const ChapterPatchResult(ok: false, message: '章节序号不对');
    }
    final target = chapterNumber(book.chapters[index]) ?? (index + 1);
    List<SourceSearchResult> results;
    try {
      results = await _repo.searchAll(book.title);
    } catch (e) {
      return ChapterPatchResult(ok: false, message: '搜索失败：$e');
    }
    var tried = 0;
    for (final r in results) {
      if (r.error != null || r.books.isEmpty) continue;
      for (final cand in r.books.take(3)) {
        if (tried >= maxCandidates) break;
        final bookUrl = cand.bookUrl;
        if (bookUrl == null || bookUrl.trim().isEmpty) continue;
        tried++;
        try {
          final info = await _service.fetchInfo(r.source, bookUrl);
          final ch = pickChapterByNumber(info.chapters, target);
          if (ch == null) continue;
          final href = (ch.href ?? '').trim();
          if (href.isEmpty) continue;
          final text = await _service.fetchChapterText(r.source, href);
          if (text.trim().isEmpty) continue;
          await store.writeCachedChapter(book, index, text, flush: true);
          await store.refreshChapterCache(book.id);
          return ChapterPatchResult(
            ok: true,
            sourceName: r.source.bookSourceName,
          );
        } catch (_) {
          // 这个候选不行就换下一个
        }
      }
      if (tried >= maxCandidates) break;
    }
    return ChapterPatchResult(
      ok: false,
      message: tried == 0 ? '没有找到其它可用的源' : '试了 $tried 个候选，都没补到这一章',
    );
  }
}
