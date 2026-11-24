// 「分享这本书」的文本：另一台手机照着做就能打开同一本。
//
// 为什么不发一条神秘 JSON：另一台手机没有「按 JSON 导入书籍」的入口，
// 所以分享的是「书名 + 作者 + 书源 + 书籍地址」这种照着就能做的信息，
// 书源本身用「分享这个源」单独发。
String buildBookShareText({
  required String title,
  String author = '',
  String? sourceName,
  String? sourceUrl,
  String? bookUrl,
  bool isOnline = false,
}) {
  final b = StringBuffer('《$title》');
  final a = author.trim();
  if (a.isNotEmpty) b.write(' $a');
  b.write('\n');

  final name = (sourceName ?? '').trim();
  final src = (sourceUrl ?? '').trim();
  if (name.isNotEmpty || src.isNotEmpty) {
    b.write('书源：');
    if (name.isNotEmpty) b.write(name);
    if (src.isNotEmpty) {
      if (name.isNotEmpty) b.write('（');
      b.write(src);
      if (name.isNotEmpty) b.write('）');
    }
    b.write('\n');
  }

  final url = (bookUrl ?? '').trim();
  if (url.isNotEmpty) b.write('书籍：$url\n');

  b.write(
    isOnline
        ? '—— 在另一台手机上：先导入这个书源，再搜《$title》就能打开。'
        : '—— 本地书：把这本书的文件（TXT / EPUB）发过去，用「导入文件」加进书架即可。',
  );
  return b.toString();
}
