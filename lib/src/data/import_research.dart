import 'book_store.dart';
import 'import_fail_store.dart';
import 'legado_import.dart';
import '../source/source_store.dart';

/// 重搜一本书的结果。
class ResearchResult {
  const ResearchResult({required this.ok, this.message = ''});
  final bool ok;
  final String message;
}

/// 用当前所有书源，把「待搜源」里的一本书重新搜一遍；搜到就入架并从失败清单移除。
Future<ResearchResult> researchBook({
  required String title,
  required BookStore shelf,
  required SourceStore sources,
  String author = '',
}) async {
  if (title.trim().isEmpty) {
    return const ResearchResult(ok: false, message: '书名是空的');
  }
  try {
    final result = await LegadoImporter().importBooks(
      books: [LegadoBook(name: title, author: author)],
      shelf: shelf,
      sources: sources,
      // 单本重搜给足时间，别刚点就超时
      bookTimeout: const Duration(seconds: 40),
    );
    if (result.imported > 0) {
      await ImportFailStore.instance.remove(title);
      return ResearchResult(ok: true, message: '《$title》已入架');
    }
    if (result.skipped > 0) {
      await ImportFailStore.instance.remove(title);
      return ResearchResult(ok: true, message: '《$title》已经在书架上了');
    }
    final why = result.failures.isNotEmpty ? result.failures.first : '没搜到这本书';
    return ResearchResult(ok: false, message: why);
  } catch (e) {
    return ResearchResult(ok: false, message: '重搜失败：$e');
  }
}
