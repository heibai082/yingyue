import 'book_store.dart';
import 'import_fail_store.dart';
import 'legado_import.dart';
import '../source/models.dart';
import '../source/source_store.dart';

/// 重搜一本书的结果。
class ResearchResult {
  const ResearchResult({required this.ok, this.message = ''});
  final bool ok;
  final String message;
}

/// 单本重搜最多试几个源。
///
/// 之前是「所有启用书源全搜一遍」：373 个源、8 并发、单源 15s 超时 →
/// 一本书要十几分钟，界面还只在「整本搜完」时才更新，看起来就是「点了没反应」。
/// 现在只挑少量健康源先试，命中就收工。
const int kResearchMaxSources = 12;

/// 挑「最可能搜到」的源：优先体检没失败过、配了搜索地址的。
List<BookSource> pickResearchSources(SourceStore sources, {int limit = kResearchMaxSources}) {
  final list = sources.enabled
      .where((s) => (s.searchUrl ?? '').trim().isNotEmpty)
      .where((s) => s.healthFailCount == 0)
      .toList()
    ..sort((a, b) {
      // 最近体检过的排前面（说明刚验证过能用）
      final byCheck = b.healthCheckedAt.compareTo(a.healthCheckedAt);
      return byCheck != 0 ? byCheck : a.bookSourceName.compareTo(b.bookSourceName);
    });
  if (list.length > limit) return list.sublist(0, limit);
  return list;
}

/// 把「待搜源」里的一本书重新搜一遍；搜到就入架并从失败清单移除。
///
/// [maxSources] 控制这一轮最多试几个源（默认 [kResearchMaxSources]），
/// 避免拿几百个死源去撞超时。
///
/// [chapterIndex] / [charOffset] / [lastReadAt] 来自备份里的阅读位置：
/// 搜到后直接落在这几项上，进度条不会又从 0% 开始。
Future<ResearchResult> researchBook({
  required String title,
  required BookStore shelf,
  required SourceStore sources,
  String author = '',
  int chapterIndex = 0,
  int charOffset = 0,
  int lastReadAt = 0,
  int maxSources = kResearchMaxSources,
  Duration bookTimeout = const Duration(seconds: 25),
}) async {
  if (title.trim().isEmpty) {
    return const ResearchResult(ok: false, message: '书名是空的');
  }
  final picked = pickResearchSources(sources, limit: maxSources);
  if (picked.isEmpty) {
    return const ResearchResult(
      ok: false,
      message: '没有可用的书源：先做一次「书源体检」，把失效的清掉',
    );
  }
  // 只带这几个源去搜：importBooks 内部会并发搜它们，命中就停
  final scoped = SourceStore(initial: picked);
  try {
    final result = await LegadoImporter().importBooks(
      books: [
        LegadoBook(
          name: title,
          author: author,
          durChapterIndex: chapterIndex,
          durChapterPos: charOffset,
          durChapterTime: lastReadAt,
        ),
      ],
      shelf: shelf,
      sources: scoped,
      bookTimeout: bookTimeout,
      concurrency: 4,
    );
    if (result.imported > 0) {
      await ImportFailStore.instance.remove(title);
      return ResearchResult(ok: true, message: '《$title》已入架');
    }
    if (result.skipped > 0) {
      await ImportFailStore.instance.remove(title);
      return ResearchResult(ok: true, message: '《$title》已经在书架上了');
    }
    final why = result.failures.isNotEmpty ? result.failures.first : '这 $maxSources 个源都没搜到';
    return ResearchResult(ok: false, message: why);
  } catch (e) {
    return ResearchResult(ok: false, message: '重搜失败：$e');
  } finally {
    scoped.dispose();
  }
}
