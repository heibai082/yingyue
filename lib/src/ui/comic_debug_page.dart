// 漫画取图调试页（自用排查工具）：直接给一个章节地址，看 WebView 能不能取到图。
//
// 为什么留这个页面：图片站的章节页是 JS 渲染的（`data-src="{{value.url}}"`），
// 书源规则一改、站点一改版，只看 App 里「没图」根本判断不出卡在哪一步。
import 'package:flutter/material.dart';

import '../source/online_book_service.dart';
import '../source/webview_engine.dart';

class ComicDebugPage extends StatefulWidget {
  const ComicDebugPage({super.key});

  @override
  State<ComicDebugPage> createState() => _ComicDebugPageState();
}

class _ComicDebugPageState extends State<ComicDebugPage> {
  final _url = TextEditingController(
    text: 'https://m.ac.qq.com/chapter/index/id/512062/cid/2',
  );
  bool _running = false;
  String? _error;
  List<String> _images = const [];
  String _log = '';

  Future<void> _run() async {
    final url = _url.text.trim();
    if (url.isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _images = const [];
      _log = '正在用隐藏 WebView 打开…';
    });
    final watch = Stopwatch()..start();
    try {
      final imgs = await WebViewEngine.instance.fetchRenderedImages(
        url: url,
      );
      if (!mounted) return;
      setState(() {
        _images = imgs;
        _log = 'WebView 取到 ${imgs.length} 张，用时 ${watch.elapsed.inSeconds}s';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _log = '失败，用时 ${watch.elapsed.inSeconds}s';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runStatic() async {
    final url = _url.text.trim();
    setState(() {
      _log = '静态解析…';
      _images = const [];
      _error = null;
    });
    try {
      final html = await WebViewEngine.instance.fetchRenderedText(
        url: url,
        totalWait: const Duration(seconds: 8),
        minChars: 20,
      );
      final imgs = OnlineBookService.extractImageUrls(html, baseUrl: url);
      if (!mounted) return;
      setState(() {
        _images = imgs;
        _log = '静态取到 ${imgs.length} 张（文本 ${html.length} 字）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('漫画取图调试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '输入一个漫画章节页地址，直接看隐藏 WebView 能拿到几张图。'
            '用于排查「书源规则是 @js / 图片由脚本插入」的情况。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: '章节地址',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(_running ? '运行中…' : 'WebView 取图'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _running ? null : _runStatic,
                child: const Text('静态解析'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(_log, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          const SizedBox(height: 10),
          for (final (i, u) in _images.indexed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
              title: Text(u, maxLines: 2, style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }
}
