// 「分享这本书」的文本：另一台手机照着做就能打开同一本。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/util/book_share.dart';

void main() {
  test('在线书：书名 + 作者 + 书源 + 书籍地址 + 一句怎么打开', () {
    final text = buildBookShareText(
      title: '航海王',
      author: '尾田栄一郎',
      sourceName: '🎨包子漫画',
      sourceUrl: 'https://cn.bzmanga.com',
      bookUrl: 'https://cn.bzmanga.com/comic/hanghaiwang-weitianrongyilang',
      isOnline: true,
    );
    expect(text, contains('《航海王》'));
    expect(text, contains('尾田栄一郎'));
    expect(text, contains('🎨包子漫画'));
    expect(text, contains('https://cn.bzmanga.com'));
    expect(text, contains('comic/hanghaiwang-weitianrongyilang'));
    expect(text, contains('再搜《航海王》'));
  });

  test('缺字段时不出现空括号 / 空行', () {
    final text = buildBookShareText(title: '本地书');
    expect(text, contains('《本地书》'));
    expect(text.contains('书源：'), isFalse);
    expect(text.contains('()'), isFalse);
    expect(text.contains('（）'), isFalse);
    expect(text, contains('本地书'));
  });

  test('本地书提示发文件而不是搜书名', () {
    final text = buildBookShareText(
      title: '三体',
      author: '刘慈欣',
      isOnline: false,
    );
    expect(text, contains('TXT / EPUB'));
    expect(text.contains('搜《三体》'), isFalse);
  });

  test('只有书源名没有地址时不出现空括号', () {
    final text = buildBookShareText(title: 'x', sourceName: '某源');
    expect(text, contains('书源：某源'));
    expect(text.contains('（）'), isFalse);
  });
}
