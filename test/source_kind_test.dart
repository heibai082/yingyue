// 书源自动分类：漫画源 / 音频源 / 文本源。
import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/models.dart';

BookSource _src({
  required String name,
  int type = 0,
  String? group,
}) => BookSource(
  bookSourceUrl: 'https://$name.example.com',
  bookSourceName: name,
  bookSourceGroup: group,
  bookSourceType: type,
);

void main() {
  test('类型明确时按 bookSourceType 走', () {
    expect(_src(name: '包子漫画', type: 2).isComic, isTrue);
    expect(_src(name: '某文本站', type: 0).isComic, isFalse);
    expect(_src(name: '某音频站', type: 1).isAudio, isTrue);
    expect(_src(name: '某音频站', type: 1).isText, isFalse);
  });

  test('类型没填（0）时按分组 / 名字猜：漫画', () {
    expect(_src(name: '海贼王', group: '漫画🎨').isComic, isTrue);
    expect(_src(name: '海贼王漫画').isComic, isTrue);
    expect(_src(name: 'BzManga').isComic, isTrue);
    expect(_src(name: '某 Comic 站').isComic, isTrue);
  });

  test('类型没填时按名字猜：音频 / 文本', () {
    expect(_src(name: '听书网').isAudio, isTrue);
    expect(_src(name: '某站有声').isAudio, isTrue);
    final plain = BookSource(
      bookSourceUrl: 'https://a.example.com',
      bookSourceName: '笔趣阁',
    );
    expect(plain.isComic, isFalse);
    expect(plain.isAudio, isFalse);
    expect(plain.isText, isTrue);
  });

  test('漫画源不会被当成文本源（换源时只搜漫画源）', () {
    final comic = _src(name: 'x', type: 2);
    expect(comic.isText, isFalse);
  });
}
