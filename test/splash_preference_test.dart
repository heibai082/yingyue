import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakura_read/src/data/prefs.dart';
import 'package:sakura_read/src/platform/native_bridge.dart';
import 'package:sakura_read/src/ui/splash_gate.dart';

void main() {
  test('启动动画默认开启，关闭后重新加载仍关闭', () async {
    final dir = await Directory.systemTemp.createTemp('sakura_splash_pref');
    try {
      final dirs = AppDirs(files: dir.path, cache: dir.path);
      final prefs = AppPrefs(dirsOverride: dirs);
      await prefs.load();
      expect(prefs.showSplashAnimation, isTrue);
      prefs.setShowSplashAnimation(false);
      await prefs.flush();
      final restored = AppPrefs(dirsOverride: dirs);
      await restored.load();
      expect(restored.showSplashAnimation, isFalse);
      prefs.dispose();
      restored.dispose();
      // dispose() 里有一次 fire-and-forget 的落盘，等它写完再删目录，
      // 否则删到一半文件又被创建出来 → "目录不是空的"（Windows 偶发）。
      await Future<void>.delayed(const Duration(milliseconds: 80));
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 测试临时目录，删不掉也不影响结论
      }
    }
  });

  testWidgets('关闭启动动画后直接显示应用', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SplashGate(enabled: false, child: Text('书架'))),
    );
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('嘤 阅'), findsNothing);
  });
}
