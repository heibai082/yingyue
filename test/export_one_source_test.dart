// 「分享这个源」用的单源导出：数组格式，另一台手机「粘贴导入」直接能用。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sakura_read/src/source/models.dart';
import 'package:sakura_read/src/source/source_store.dart';

void main() {
  test('exportOneJson 只导出这一条，能原样粘到另一台手机', () {
    final store = SourceStore();
    store.addAll([
      BookSource(
        bookSourceUrl: 'https://cn.bzmanga.com',
        bookSourceName: '🎨包子漫画',
        bookSourceType: 2,
      ),
      BookSource(
        bookSourceUrl: 'https://other.example.com',
        bookSourceName: '别的源',
      ),
    ]);

    final json = store.exportOneJson('https://cn.bzmanga.com');
    final decoded = jsonDecode(json) as List;
    expect(decoded, hasLength(1), reason: '只要这一条，别把别的源也带上');
    final one = Map<String, dynamic>.from(decoded.single as Map);
    expect(one['bookSourceUrl'], 'https://cn.bzmanga.com');
    expect(one['bookSourceName'], '🎨包子漫画');

    // 模拟另一台手机「粘贴导入」
    final other = SourceStore();
    other.addAll([BookSource.fromJson(one)]);
    expect(other.sources, hasLength(1));
    expect(other.sources.single.bookSourceName, '🎨包子漫画');
    expect(other.sources.single.bookSourceType, 2);
  });

  test('地址不存在时给空数组（上层不会崩）', () {
    final store = SourceStore();
    expect(store.exportOneJson('https://nope.example.com'), '[]');
  });
}
