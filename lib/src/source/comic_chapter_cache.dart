// 漫画章节图片列表的内存缓存。
//
// 目的：翻回上一话、或者后台预取过的下一话，**不用再等网络**（包子漫画那一页
// HTML 要 3 秒多，图片地址拿到之前读者只能看转圈）。
//
// 只放少量章节（默认 30），超了就丢最早进来的那条。
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
}
