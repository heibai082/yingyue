// 源仓库（yckceo 阅读源仓库）抓取：首页「书源合集」列表 + 合集 JSON。
//
// 页面结构（2026-11 实测）：
//   <h2><a href="/yuedu/shuyuans/content/id/1341.html">标题</a>
//       <p class="m-right">3天前</p></h2>
//   ... 源数量:15 ...
// 合集 JSON 走 /yuedu/shuyuans/json/id/<id>.json，302 到 jsDelivr 的静态文件，
// 内容是「阅读 3.0」书源数组，可直接交给 SourceStore.importFromText。
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 首页里的一个书源合集。
class SourceHubItem {
  const SourceHubItem({
    required this.id,
    required this.title,
    required this.jsonUrl,
    this.time,
    this.rawTime = '',
    this.sourceCount = 0,
  });

  final int id;
  final String title;
  final String jsonUrl;

  /// 解析出来的发布时间（解析不出来就是 null）。
  final DateTime? time;

  /// 页面上的原始时间文案（「3天前」「11/12 11:41」）。
  final String rawTime;

  final int sourceCount;

  bool isNewerThan(DateTime cutoff) => time != null && time!.isAfter(cutoff);
}

/// 把页面上的中文相对时间解析成 [DateTime]。
///
/// 支持：刚刚 / N分钟前 / N小时前 / N天前 / 昨天 / 今天 /
/// `11/12 11:41` / `2026-11-12 11:41` / `11/12`。
DateTime? parseHubTime(String raw, {DateTime? now}) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final base = now ?? DateTime.now();

  if (text == '刚刚' || text == '刚才') return base;

  final rel = RegExp(r'^(\d+)\s*(分钟|小时|天|周|月)前$').firstMatch(text);
  if (rel != null) {
    final n = int.parse(rel.group(1)!);
    return switch (rel.group(2)!) {
      '分钟' => base.subtract(Duration(minutes: n)),
      '小时' => base.subtract(Duration(hours: n)),
      '天' => base.subtract(Duration(days: n)),
      '周' => base.subtract(Duration(days: n * 7)),
      _ => base.subtract(Duration(days: n * 30)),
    };
  }
  if (text == '昨天') return base.subtract(const Duration(days: 1));
  if (text == '今天') return base;
  if (text == '前天') return base.subtract(const Duration(days: 2));

  // 2026-11-12 11:41 / 2026-11-12
  final full = RegExp(
    r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$',
  ).firstMatch(text);
  if (full != null) {
    return DateTime(
      int.parse(full.group(1)!),
      int.parse(full.group(2)!),
      int.parse(full.group(3)!),
      int.tryParse(full.group(4) ?? '') ?? 0,
      int.tryParse(full.group(5) ?? '') ?? 0,
    );
  }

  // 11/12 11:41 / 11/12（当年；若比现在还晚，视为去年）
  final md = RegExp(
    r'^(\d{1,2})/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?$',
  ).firstMatch(text);
  if (md != null) {
    final parsed = DateTime(
      base.year,
      int.parse(md.group(1)!),
      int.parse(md.group(2)!),
      int.tryParse(md.group(3) ?? '') ?? 0,
      int.tryParse(md.group(4) ?? '') ?? 0,
    );
    return parsed.isAfter(base.add(const Duration(days: 1)))
        ? DateTime(parsed.year - 1, parsed.month, parsed.day)
        : parsed;
  }
  return null;
}

/// 源仓库的两种列表。
enum HubKind {
  /// 书源合集（一个合集里很多源）。
  collections,

  /// 单个书源（一条一个源）。
  sources,
}

/// 用户填的「源仓库网址」解析结果。
class HubTarget {
  const HubTarget({required this.baseUrl, required this.kind});

  /// 站点根（形如 https://www.yckceo.com，不带 /yuedu/…）。
  final String baseUrl;
  final HubKind kind;

  /// `/yuedu/` 后面那段路径。
  String get segment =>
      kind == HubKind.collections ? 'shuyuans' : 'shuyuan';

  String get label =>
      kind == HubKind.collections ? '书源合集' : '单个书源';

  String get indexUrl => '$baseUrl/yuedu/$segment/index.html';

  static const HubTarget defaultTarget = HubTarget(
    baseUrl: 'https://www.yckceo.com',
    kind: HubKind.collections,
  );

  /// 按行解析多个地址（去重、丢掉看不懂的）；[input] 为空时给默认地址。
  static List<HubTarget> parseAll(String input, {bool fallbackToDefault = true}) {
    final out = <HubTarget>[];
    final seen = <String>{};
    for (final line in input.split('\n')) {
      final target = parse(line);
      if (target == null) continue;
      if (seen.add(target.indexUrl)) out.add(target);
    }
    if (out.isEmpty && fallbackToDefault) return const [defaultTarget];
    return out;
  }

  /// 把用户输入（根域名 / 书源页 / 合集页）解析成目标；解析不了返回 null。
  ///
  /// 支持的写法：
  /// - `https://www.yckceo.com`
  /// - `https://www.yckceo.com/yuedu/shuyuan/index.html`（单个书源）
  /// - `https://www.yckceo.com/yuedu/shuyuans/index.html`（合集）
  /// - 省略协议时自动补 https://
  static HubTarget? parse(String input) {
    var raw = input.trim();
    if (raw.isEmpty) return null;
    if (!raw.contains('://')) raw = 'https://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    final path = uri.path;
    // 书源合集用 shuyuans，单个书源用 shuyuan —— 先判长的，别被短的前缀骗了
    final kind = path.contains('/yuedu/shuyuans')
        ? HubKind.collections
        : path.contains('/yuedu/shuyuan')
        ? HubKind.sources
        : HubKind.collections;
    return HubTarget(
      baseUrl: '${uri.scheme}://${uri.authority}',
      kind: kind,
    );
  }
}

/// 解析首页 HTML，拿到条目列表（按页面顺序 = 新的在前）。
///
/// [segment]：`shuyuans`（合集页）或 `shuyuan`（单个书源页），两页的 HTML 结构一致。
List<SourceHubItem> parseHubIndex(
  String html, {
  String baseUrl = 'https://www.yckceo.com',
  String segment = 'shuyuans',
  DateTime? now,
}) {
  final items = <SourceHubItem>[];
  final block = RegExp(
    '<h2[^>]*>\\s*<a href="(?<href>/yuedu/$segment/content/id/(?<id>\\d+)\\.html)"[^>]*>(?<title>.*?)</a>\\s*'
    r'(?:<p class="m-right"[^>]*>(?<time>[^<]*)</p>)?',
    dotAll: true,
  );
  for (final m in block.allMatches(html)) {
    final id = int.tryParse(m.namedGroup('id') ?? '') ?? 0;
    if (id <= 0) continue;
    final title = _stripTags(m.namedGroup('title') ?? '').trim();
    final rawTime = _stripTags(m.namedGroup('time') ?? '').trim();
    // 附近若有「源数量:N」就记下来（用于估算要导入多少）
    final tail = html.substring(m.end, (m.end + 400).clamp(0, html.length));
    final countMatch = RegExp(r'源数量[:：]\s*(\d+)').firstMatch(tail);
    items.add(
      SourceHubItem(
        id: id,
        title: title,
        jsonUrl: '$baseUrl/yuedu/$segment/json/id/$id.json',
        time: parseHubTime(rawTime, now: now),
        rawTime: rawTime,
        sourceCount: int.tryParse(countMatch?.group(1) ?? '') ?? 0,
      ),
    );
  }
  return items;
}

String _stripTags(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&middot;', '·')
    .replaceAll('&hellip;', '…')
    .replaceAll('&mdash;', '—')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// 源仓库客户端（可注入 http.Client 方便测试）。
class SourceHubClient {
  SourceHubClient({
    http.Client? client,
    this.baseUrl = 'https://www.yckceo.com',
    this.kind = HubKind.collections,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  /// 按用户配置（prefs.sourceHubUrl）建客户端；没配就用默认的合集页。
  factory SourceHubClient.fromUrl(String url, {http.Client? client}) {
    final target = HubTarget.parse(url) ?? HubTarget.defaultTarget;
    return SourceHubClient(
      client: client,
      baseUrl: target.baseUrl,
      kind: target.kind,
    );
  }

  /// 按多行配置建一组客户端（多个源仓库）。
  static List<SourceHubClient> fromTargets(
    String urlsText, {
    http.Client? client,
  }) => [
    for (final t in HubTarget.parseAll(urlsText))
      SourceHubClient(client: client, baseUrl: t.baseUrl, kind: t.kind),
  ];

  final http.Client _client;
  final String baseUrl;
  final HubKind kind;
  final Duration timeout;

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36';

  String get segment => kind == HubKind.collections ? 'shuyuans' : 'shuyuan';

  /// 去重用的站点标识（同一个 id 在不同站是两条）。
  String get hostKey {
    final uri = Uri.tryParse(baseUrl);
    final host = uri?.host ?? baseUrl;
    return uri?.hasPort == true ? '$host:${uri!.port}' : host;
  }

  /// 展示用名字。
  String get label => '${Uri.tryParse(baseUrl)?.host ?? baseUrl}'
      '（${kind == HubKind.collections ? '合集' : '单源'}）';

  /// 首页列表（第 1 页 = 最新）。
  Future<List<SourceHubItem>> latest({int pages = 1}) async {
    final out = <SourceHubItem>[];
    for (var page = 1; page <= pages; page++) {
      final uri = Uri.parse(
        '$baseUrl/yuedu/$segment/index.html${page > 1 ? '?page=$page' : ''}',
      );
      final resp = await _client
          .get(uri, headers: const {'User-Agent': _ua})
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw HubException('列表页 HTTP ${resp.statusCode}', uri: uri);
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      out.addAll(parseHubIndex(html, baseUrl: baseUrl, segment: segment));
    }
    return out;
  }

  /// 下载某一条的全部书源（阅读 3.0 数组；单个书源页就是一条一个）。
  Future<List<Map<String, dynamic>>> collection(int item) async {
    final uri = Uri.parse('$baseUrl/yuedu/$segment/json/id/$item.json');
    final resp = await _client
        .get(uri, headers: const {'User-Agent': _ua})
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw HubException('下载 HTTP ${resp.statusCode}', uri: uri);
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['sources'] is List)
        ? decoded['sources'] as List
        : const [];
    return [
      for (final e in list)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }
}

/// 一个轻量的 HTTP 异常（避免调用方依赖 dart:io 类型）。
class HubException implements Exception {
  HubException(this.message, {this.uri});
  final String message;
  final Uri? uri;
  @override
  String toString() => uri == null ? message : '$message（$uri）';
}
