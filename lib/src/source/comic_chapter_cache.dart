// 漫画章节图片列表的内存缓存。
//
// 目的：翻回上一话、或者后台预取过的下一话，**不用再等网络**（包子漫画那一页
// HTML 要 3 秒多，图片地址拿到之前读者只能看转圈）。
//
// 只放少量章节（默认 30），超了就丢最早进来的那条；可以整份落到磁盘，
// 下次打开 App 也算「预取过」。
import 'dart:convert';
import 'dart:io';

class ComicChapterCache {
  ComicChapterCache({this.limit = 30}) : assert(limit > 0);

  final int limit;
  final Map<String, List<String>> _map = {};

  int get length => _map.length;

  bool contains(String url) => _map.containsKey(url);

  /// 取缓存；没缓存过返回 null。
  List<String>? operator [](String url) => _map[url];

  /// 存缓存。空列表不存（免得把「这一话没图」的失败结果缓存住，翻回来还错）。
  void put(String url, List<String> urls) {
    if (urls.isEmpty) return;
    if (!_map.containsKey(url) && _map.length >= limit) {
      _map.remove(_map.keys.first);
    }
    _map[url] = urls;
  }

  void clear() => _map.clear();

  /// 导出成 JSON（给磁盘缓存用）。
  String encode() => jsonEncode(_map);

  /// 从 JSON 恢复；坏数据就当成空的，不抛异常。
  void loadEncoded(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return;
      _map.clear();
      decoded.forEach((k, v) {
        if (k is String && v is List) {
          final urls = [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ];
          if (urls.isNotEmpty) _map[k] = urls;
        }
      });
    } catch (_) {
      // 忽略坏文件
    }
  }

  Future<void> loadFrom(File file) async {
    try {
      if (await file.exists()) {
        loadEncoded(await file.readAsString());
      }
    } catch (_) {}
  }

  Future<void> saveTo(File file) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(encode(), flush: false);
    } catch (_) {}
  }
}
