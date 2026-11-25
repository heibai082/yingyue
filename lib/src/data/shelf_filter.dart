// 书架内搜索 + 状态筛选（纯函数，方便单测）。
import 'models.dart';

/// 书架筛选状态。
enum ShelfStatusFilter { all, reading, finished, unread }

extension ShelfStatusFilterX on ShelfStatusFilter {
  String get label => switch (this) {
    ShelfStatusFilter.all => '全部',
    ShelfStatusFilter.reading => '在读',
    ShelfStatusFilter.finished => '读完',
    ShelfStatusFilter.unread => '未读',
  };

  bool matches(Book book) => switch (this) {
    ShelfStatusFilter.all => true,
    ShelfStatusFilter.reading => book.lastReadAt > 0 && !book.finished,
    ShelfStatusFilter.finished => book.finished,
    ShelfStatusFilter.unread => book.lastReadAt == 0,
  };
}

/// 按关键词（书名 / 作者）过滤；空关键词 = 不过滤。
List<Book> filterBooksByQuery(List<Book> books, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return books;
  return [
    for (final b in books)
      if (b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q))
        b,
  ];
}

/// 组合筛选：关键词 + 状态。
List<Book> filterShelf(
  List<Book> books, {
  String query = '',
  ShelfStatusFilter status = ShelfStatusFilter.all,
}) {
  final byQuery = filterBooksByQuery(books, query);
  if (status == ShelfStatusFilter.all) return byQuery;
  return [
    for (final b in byQuery)
      if (status.matches(b)) b,
  ];
}
