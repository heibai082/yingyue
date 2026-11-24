// 在线书籍服务：详情 / 目录 / 正文的获取与解析。
//
// 数据流（对应内置「笔趣阁家族」源）：
//   搜索（HTTP，M2 已有）
//   → 详情页 HTTP 抓取 + ruleBookInfo 解析（OG meta 等）
//   → 目录：与详情页同页解析（ruleToc），或按 tocUrl 规则单独请求
//   → 正文：隐藏 WebView 渲染（令牌墙 / SPA / 加密接口全部由页面 JS 完成）
//     - 支持 `gatewayPath` 扩展：章节链接先改写到网关（如 /userverify/book/...），
//       由站点服务端 301 到真正的阅读页。
//
// 本文件不依赖 UI；WebView 引擎仅在「取正文」时被调用。
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:html/parser.dart' as html_parser;

import '../data/models.dart';
import 'ad_page_filter.dart';
import 'analyze_rule.dart';
import 'chapter_order.dart';
import 'analyze_url.dart';
import 'http_client.dart';
import 'models.dart';
import 'webview_engine.dart';

/// 详情页解析结果。
class OnlineBookInfo {
  const OnlineBookInfo({
    this.name,
    this.author,
    this.intro,
    this.coverUrl,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.chapters = const [],
  });

  final String? name;
  final String? author;
  final String? intro;
  final String? coverUrl;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final List<ChapterRef> chapters;
}

/// 在线书籍服务。
class OnlineBookService {
  OnlineBookService({SourceHttpClient? client})
    : _client = client ?? SourceHttpClient();

  final SourceHttpClient _client;

  void dispose() => _client.close();

  static const Duration _httpTimeout = Duration(seconds: 20);

  // ---------- 详情 / 目录 ----------

  /// 抓取详情页并解析（含目录；目录为空且有 tocUrl 规则时单独请求）。
  Future<OnlineBookInfo> fetchInfo(BookSource source, String bookUrl) async {
    final html = await _getHtml(source, bookUrl);
    final engine = AnalyzeRule(html, baseUrl: bookUrl);
    final info = source.bookInfoRule;

    String? g(String? rule) {
      final r = rule?.trim();
      if (r == null || r.isEmpty) return null;
      final v = engine.getString(r);
      return (v == null || v.isEmpty) ? null : v;
    }

    var chapters = source.tocRule == null
        ? const <ChapterRef>[]
        : parseChapters(engine, source.tocRule!, bookUrl);

    if (chapters.isEmpty) {
      final tocUrlRule = g(info?.tocUrl);
      if (tocUrlRule != null) {
        final tocUrl = resolveUrl(tocUrlRule, bookUrl);
        if (tocUrl.isNotEmpty && tocUrl != bookUrl) {
          final tocHtml = await _getHtml(source, tocUrl);
          final tocEngine = AnalyzeRule(tocHtml, baseUrl: source.bookSourceUrl);
          chapters = parseChapters(tocEngine, source.tocRule!, tocUrl);
          // 目录分页（`nextTocUrl`）：不少站点目录被拆成 index_1 / index_2 …
          chapters = await _followTocPages(source, tocEngine, tocUrl, chapters);
        }
      }
    } else {
      chapters = await _followTocPages(source, engine, bookUrl, chapters);
    }

    // 目录归一化：漫画源的站点会把「最新几话」在目录最前面再列一遍，
    // 拼起来就重复 + 索引错位（点第1152话却显示 1177/1187）。
    chapters = normalizeChapterOrder(chapters, newestFirst: source.isComic);

    return OnlineBookInfo(
      name: g(info?.name),
      author: g(info?.author),
      intro: g(info?.intro) == null
          ? null
          : html_parser
                .parseFragment(
                  g(info?.intro)!.replaceAll(
                    RegExp(r'<br\s*/?>', caseSensitive: false),
                    '\n',
                  ),
                )
                .text,
      coverUrl: g(info?.coverUrl) == null
          ? null
          : resolveUrl(g(info?.coverUrl)!, bookUrl),
      kind: g(info?.kind),
      lastChapter: g(info?.lastChapter),
      updateTime: g(info?.updateTime),
      chapters: chapters,
    );
  }

  /// 解析目录：chapterList 产出「条目」，逐条取章节名 / 章节链接。
  ///
  /// 支持一个条目里取到多个章节名（如 chapterList 直接选 `<dl>` 的站点），
  /// 也支持一条一个章节（如 `dl.1@tag.dd` 的笔趣阁模板）；按链接去重。
  static List<ChapterRef> parseChapters(
    AnalyzeRule engine,
    TocRule rule,
    String baseUrl,
  ) {
    final listRule = rule.chapterList?.trim() ?? '';
    if (listRule.isEmpty) return const [];
    final nameRule = rule.chapterName?.trim() ?? '';
    final urlRule = (rule.chapterUrl?.trim().isNotEmpty ?? false)
        ? rule.chapterUrl!.trim()
        : 'tag.a@href';

    final out = <ChapterRef>[];
    final seen = <String>{};
    for (final item in engine.getRawList(listRule)) {
      final titles = nameRule.isEmpty
          ? const <String>[]
          : engine.getStrings(nameRule, ctx: item);
      final hrefs = engine.getStrings(urlRule, ctx: item);
      final n = titles.length < hrefs.length ? titles.length : hrefs.length;
      for (var i = 0; i < n; i++) {
        final title = titles[i].trim();
        final rawHref = hrefs[i].trim();
        if (title.isEmpty || rawHref.isEmpty) continue;
        // 跳过「展开全部章节」等 JS 伪链接
        final lower = rawHref.toLowerCase();
        if (lower.startsWith('javascript:') ||
            lower.startsWith('mailto:') ||
            lower.startsWith('tel:')) {
          continue;
        }
        final href = resolveUrl(rawHref, baseUrl);
        if (href.isEmpty) continue;
        if (!seen.add(href)) continue;
        out.add(ChapterRef(title: title, href: href));
      }
    }
    return out;
  }

  /// 沿 `nextTocUrl` 继续翻目录页，把后续页的章节追加进来。
  ///
  /// 站点的分页目录（`/index_2.html`、`?page=2`）在 Legado 里靠
  /// `ruleToc.nextTocUrl` 表达；不支持就等于只能读到第一页目录。
  Future<List<ChapterRef>> _followTocPages(
    BookSource source,
    AnalyzeRule firstEngine,
    String firstUrl,
    List<ChapterRef> first,
  ) async {
    final rule = source.tocRule?.nextTocUrl?.trim() ?? '';
    if (rule.isEmpty) return first;
    final out = <ChapterRef>[...first];
    final seen = <String>{
      for (final c in first)
        if (c.href != null && c.href!.isNotEmpty) c.href!,
    };
    var engine = firstEngine;
    var url = firstUrl;
    final visited = <String>{firstUrl};
    for (var page = 0; page < 10; page++) {
      final rawNext = engine.getString(rule);
      if (rawNext == null || rawNext.isEmpty) break;
      final next = resolveUrl(rawNext, url);
      if (next.isEmpty || !visited.add(next)) break;
      String html;
      try {
        html = await _getHtml(source, next);
      } catch (_) {
        break;
      }
      final e = AnalyzeRule(html, baseUrl: source.bookSourceUrl);
      final more = parseChapters(e, source.tocRule!, next);
      if (more.isEmpty) break;
      var added = 0;
      for (final c in more) {
        final h = c.href;
        if (h == null || h.isEmpty) continue;
        if (seen.add(h)) {
          out.add(c);
          added++;
        }
      }
      if (added == 0) break;
      engine = e;
      url = next;
    }
    return out;
  }

  // ---------- 正文 ----------

  /// 取章节正文。
  ///
  /// 书源 `webView=true` 时走隐藏 WebView（可配 `gatewayPath` 网关重写）；
  /// 否则直接 HTTP 抓取 + ruleContent 解析（普通静态站点）。
  Future<String> fetchChapterText(BookSource source, String chapterUrl) async {
    if (_flag(source.extra['webView'])) {
      final target = webViewChapterUrl(source, chapterUrl);
      final text = await WebViewEngine.instance.fetchRenderedText(
        url: target,
        cssSelectors: contentSelectors(source),
      );
      return cleanChapterText(text);
    }

    final html = await _getHtml(source, chapterUrl);
    var engine = AnalyzeRule(html, baseUrl: source.bookSourceUrl);
    final raw = source.contentRule?.content ?? '';
    if (raw.trim().isEmpty) return '';
    // 正文通常是多段：取规则命中的**全部**结果并按段拼回（getString 只会取第一段）
    final buf = <String>[engine.getStrings(raw).join('\n')];

    // 分页正文（`nextContentUrl`）：一章被站点拆成多页时必须继续抓。
    // 典型写法 `text.下一页@href` / `#linkNext@href` / `a#next:contains(下一页)@href`。
    final nextRule = source.contentRule?.nextContentUrl?.trim() ?? '';
    if (nextRule.isNotEmpty) {
      var url = chapterUrl;
      final visited = <String>{chapterUrl};
      for (var page = 0; page < 5; page++) {
        final rawNext = engine.getString(nextRule);
        if (rawNext == null || rawNext.isEmpty) break;
        final next = resolveUrl(rawNext, url);
        if (next.isEmpty || !visited.add(next) || next == url) break;
        String nextHtml;
        try {
          nextHtml = await _getHtml(source, next);
        } catch (_) {
          break;
        }
        final e = AnalyzeRule(nextHtml, baseUrl: source.bookSourceUrl);
        final part = e.getStrings(raw).join('\n');
        if (part.trim().isEmpty) break;
        buf.add(part);
        engine = e;
        url = next;
      }
    }
    return cleanChapterText(buf.join('\n'));
  }

  /// 章节页在隐藏 WebView 中打开的地址（应用 gatewayPath 网关重写）。
  ///
  /// 例：`https://www.hkmtxt.cc/book/126/2079.html` + gatewayPath `/userverify`
  ///   → `https://www.hkmtxt.cc/userverify/book/126/2079.html`
  ///   （服务端 301 到真正的阅读页）
  static String webViewChapterUrl(BookSource source, String chapterUrl) {
    final gateway = source.extra['gatewayPath']?.toString().trim() ?? '';
    if (gateway.isEmpty) return chapterUrl;
    try {
      final uri = Uri.parse(chapterUrl);
      if (uri.path.startsWith('$gateway/') || uri.path == gateway) {
        return chapterUrl;
      }
      return uri.replace(path: '$gateway${uri.path}').toString();
    } catch (_) {
      return chapterUrl;
    }
  }

  /// 从 ruleContent.content 规则串提取 WebView 可用的 CSS 选择器列表。
  ///
  /// 兼容规则写法：`id.chaptercontent@text || class.content@text`
  ///   → `['#chaptercontent', '.content']`
  static List<String> contentSelectors(BookSource source) {
    final raw = source.contentRule?.content ?? '';
    final out = <String>[];
    for (final alt in raw.split('||')) {
      var seg = alt.trim();
      if (seg.isEmpty) continue;
      seg = seg.split('@').first.trim();
      if (seg.isEmpty || seg.startsWith('@')) continue;
      if (seg.startsWith('tag.')) {
        seg = seg.substring(4);
      } else if (seg.startsWith('class.')) {
        seg = '.${seg.substring(6)}';
      } else if (seg.startsWith('id.')) {
        seg = '#${seg.substring(3)}';
      }
      if (seg.isNotEmpty) out.add(seg);
    }
    return out;
  }

  // ---------- 正文清洗 ----------

  /// 去掉站点水印 / 导航等噪音行。
  static final List<String> _junkMarkers = [
    '请收藏本站',
    '手机版：',
    '手机版:',
    '『点此报错』',
    '『加入书签』',
    '点此报错',
    '加入书签',
    '最新章节',
    // 站点转载声明（常见于抓取失败的整页文本里）
    '转载作品',
    '网友上传',
    '请记住本书',
    '首发域名',
  ];

  static final RegExp _junkExact = RegExp(
    r'^[　\s]*(上一章|下一章|返回目录|目录|加入书签|章节报错|举报|书页|书架)[\s　]*$',
  );

  /// 「导航短行」特征：≤12 字、且**全是**汉字/字母/数字（无标点、无空格）——
  /// 站点菜单项都是干净短语，而正文句子几乎必然带标点。
  static final RegExp _navLikeLine = RegExp(
    r'^[\u4e00-\u9fa5A-Za-z0-9]{1,12}$',
  );

  /// 判断是否是站点导航残留（短行 + 命中栏目词）。
  static bool _isNavResidue(String line) =>
      _navLikeLine.hasMatch(line) && _navWords.any(line.contains);

  /// 站点栏目词（命中即视为导航残留，仅对「导航短行」生效）。
  static const List<String> _navWords = [
    '首页',
    '书架',
    '排行榜',
    '排行',
    '分类',
    '玄幻',
    '武侠',
    '都市',
    '历史',
    '网游',
    '科幻',
    '女生',
    '完本',
    '全部小说',
    '最近更新',
    '登录',
    '注册',
    '护眼',
    '关灯',
    '大中小',
    '手机版',
    '字体',
  ];

  static final RegExp _domainWatermark = RegExp(
    r'([a-z0-9-]+\.)*(bqg\d*|biquge|biqg|qbtr|hkmtxt|shw\d*|ddtxt\d*|qbxs\d*|22biqu)\.[a-z]+',
    caseSensitive: false,
  );

  static final RegExp _trailingCode = RegExp(r'\s*\d{1,3}w\d{1,3}-\d{1,6}\s*$');

  /// 清洗：去空行 / 水印行 / 导航行 / 行尾编号，保留段首全角缩进。
  static String cleanChapterText(String raw) {
    if (raw.isEmpty) return '';
    // 先把正文 HTML 变成纯文本：`@html` 取到的内容里全是 <br>/<p>/&nbsp;，
    // 不还原就会把整章压成**一行**（末尾再带一句站点水印），
    // 而下面按行去广告的过滤器一旦命中水印就会把整章丢掉 → 正文空白。
    var text = raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</?p\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</?div\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final out = <String>[];
    for (final line in text.split('\n')) {
      var l = line.trimRight();
      l = l.replaceFirst(RegExp(r'^[ \t\u00A0]+'), '');
      if (l.trim().isEmpty) continue;
      var skip = false;
      // 只在**短行**上按水印丢弃：长行是真正的正文段落，
      // 因为命中一句水印就整段删掉是致命的（见上面的单行章节问题）。
      if (l.length < 200) {
        for (final marker in _junkMarkers) {
          if (l.contains(marker)) {
            skip = true;
            break;
          }
        }
      }
      if (skip) continue;
      if (_junkExact.hasMatch(l)) continue;
      // 站点阅读器的工具条（“字体：大 中 小 护眼 关灯”）——整行特征明显
      if (l.contains('护眼') && l.contains('关灯')) continue;
      // 导航短行兜底：短、无标点、且命中栏目词 → 视为菜单残留
      if (_isNavResidue(l.trim())) continue;
      if (l.length < 60 && _domainWatermark.hasMatch(l)) continue;
      // 行内水印（长行末尾常带）：就地删掉，保留正文
      l = l.replaceAll(_inlineWatermark, '');
      l = l.replaceAll(_trailingCode, '').trimRight();
      if (l.trim().isEmpty) continue;
      out.add(l);
    }
    return out.join('\n');
  }

  /// 行内站点水印（「请记住本书首发域名：xxx」「鬼吹灯手机版阅读网址：xxx」等）。
  static final RegExp _inlineWatermark = RegExp(
    r'[（(]?请记住本书[^。\n]{0,60}[。]?|[（(]?首发域名[:：]?\s*\S+|'
    r'\S{0,12}手机版阅读网址[:：]?\s*\S*',
  );

  // ---------- 内部工具 ----------

  Future<String> _getHtml(BookSource source, String url) async {
    final headers = headerMap(source);
    // 不少站点对「没有来路的请求」直接 403；补上站内 Referer
    headers.putIfAbsent('Referer', () => source.bookSourceUrl);
    // 老数据里可能存着 `&amp;` 这种实体（以前目录没还原），这里统一洗一遍
    final target = resolveUrl(url, source.bookSourceUrl);
    final resp = await _client.get(
      target,
      headers: headers,
      timeout: _httpTimeout,
      retries: 1,
    );
    if (!resp.ok) {
      throw SourceHttpException('HTTP ${resp.statusCode}');
    }
    return resp.body;
  }

  /// 书源 header（JSON 字符串）→ 请求头。
  ///
  /// 有些源写成 `@js: JSON.stringify({...})`：这里不执行 JS，但会把外层壳剥掉，
  /// 里面的 JSON 对象照样能用（包子漫画这类图片源就是这种写法）。
  static Map<String, String> headerMap(BookSource source) {
    final out = <String, String>{};
    final raw = source.header;
    if (raw == null || raw.trim().isEmpty) return out;
    var text = raw.trim();
    if (text.startsWith('@js:') || text.startsWith('<js>')) {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) text = text.substring(start, end + 1);
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        decoded.forEach((k, v) => out[k.toString()] = v.toString());
      }
    } catch (_) {
      // 忽略非 JSON 的 header
    }
    return out;
  }

  static bool _flag(dynamic v) =>
      v == true || v == 1 || v == 'true' || v == '1';

  // ---------- 漫画（图片）章节 ----------

  /// 抓一章漫画的图片地址列表。
  ///
  /// 阅读 3.0 的图片源里，正文规则通常返回「一串图片地址」或「一段带 <img> 的 HTML」，
  /// 两种都认；规则什么都没给时，再从整页里挑疑似漫画图兜底。
  Future<List<String>> fetchComicImages(
    BookSource source,
    String chapterUrl,
  ) async {
    var last = (urls: const <String>[], why: '这一话没取到图片');
    // 站点偶尔（限流 / 边缘节点抖动）会给一页「没有正文图」的空壳，隔一秒重试一次
    for (var attempt = 0; attempt < 2; attempt++) {
      last = await _comicOnce(source, chapterUrl);
      if (last.urls.isNotEmpty) return last.urls;
      if (attempt == 0) {
        debugPrint('[comic] empty, retry once');
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    }
    throw ComicUnavailable(last.why);
  }

  /// 取一次章节图；取不到时把「为什么」也带出来，方便在手机上直接看懂。
  Future<({List<String> urls, String why})> _comicOnce(
    BookSource source,
    String chapterUrl,
  ) async {
    debugPrint('[comic] chapter=$chapterUrl');
    debugPrint(
      '[comic] rule="${source.contentRule?.content ?? ''}" '
      'header=${source.header ?? ''}',
    );
    final html = await _getHtml(source, chapterUrl);
    debugPrint(
      '[comic] html=${html.length} img=${RegExp(r'<img', caseSensitive: false).allMatches(html).length} '
      'scomic=${html.contains('scomic')}',
    );
    final out = <String>[];
    final rule = source.contentRule?.content ?? '';
    if (rule.trim().isNotEmpty) {
      try {
        final engine = AnalyzeRule(html, baseUrl: source.bookSourceUrl);
        for (final part in engine.getStrings(rule)) {
          out.addAll(extractImageUrls(part, baseUrl: chapterUrl));
        }
        debugPrint('[comic] byRule=${out.length}');
      } catch (e) {
        debugPrint('[comic] ruleError=$e');
      }
    }
    if (out.isEmpty) {
      out.addAll(extractImageUrls(html, baseUrl: chapterUrl));
      debugPrint('[comic] byFallback=${out.length}');
    }
    // 去重但保留顺序（分页站点会有重复图）
    final seen = <String>{};
    final deduped = [
      for (final url in out)
        if (seen.add(url)) url,
    ];
    // 广告图按地址过滤；但如果过滤完啥都不剩，说明规则可能误伤，改用原列表
    final filtered = [
      for (final url in deduped)
        if (!looksLikeAdUrl(url)) url,
    ];
    final urls = filtered.isEmpty ? deduped : filtered;
    debugPrint(
      '[comic] static=${urls.length} first=${urls.take(3).join(' | ')}',
    );

    // 有的章节站点只给一页「广告 / 推荐」图（真图要 App 或会员才给）。
    // 章节地址里的 comic_id 一般也出现在图片路径里，能对上就只留对得上的，
    // 免得把别的漫画的推广图当成本话正文。
    _keepOnlyThisComic(urls, chapterUrl);

    // 图片站常见：正文规则是 `@js:`（要执行脚本）或图片由 JS 插进 DOM，
    // 静态 HTML 里只有占位符。这时让真浏览器跑一遍，从 DOM 里取大图。
    //
    // 注意：不能因为「规则是 @js」就无条件跑 WebView —— 包子漫画这种源
    // 静态 HTML 里就有整话的 <amp-img>，再跑一遍 WebView 只是白等 30 秒。
    // 页面本身就在喊「打开 App / 解锁」、而且一张正文图都没有：浏览器里也不会突然有，
    // 再跑 12 秒 WebView 只是让读者多等，直接跳过。
    final gated = urls.isEmpty && _looksGated(html);
    if (urls.length < 3 && !gated) {
      try {
        final rendered = await WebViewEngine.instance.fetchRenderedImages(
          url: chapterUrl,
          // 静态解析已经尽量拿到整话了，这里的定位是「补漏」，别让读者干等
          totalWait: const Duration(seconds: 12),
        );
        debugPrint('[comic] webview=${rendered.length}');
        for (final u in rendered) {
          // WebView 从 DOM 里拿的图不经过 extractImageUrls 的过滤，
          // 导流图 / 封面 / 二维码这些得在这里挡掉
          if (_isJunkImage(u)) continue;
          if (seen.add(u)) urls.add(u);
        }
        _keepOnlyThisComic(urls, chapterUrl);
      } catch (e) {
        debugPrint('[comic] webviewError=$e');
      }
    }
    debugPrint('[comic] total=${urls.length}');
    final kept = filterChapterImages(urls, chapterUrl);
    if (kept.isEmpty) {
      return (urls: const <String>[], why: _whyNoImages(html, chapterUrl));
    }
    return (urls: kept, why: '');
  }

  /// 页面是不是「只有 App / 会员能看」的空壳页。
  static bool _looksGated(String html) =>
      html.contains('打开APP') ||
      html.contains('安装包子漫画') ||
      html.contains('解锁最新') ||
      html.contains('APP解锁');

  /// 取不到图时给读者的解释（带上页面大小，远程排查时能看出是空壳页还是解析失败）。
  static String _whyNoImages(String html, String chapterUrl) {
    final kb = html.length ~/ 1024;
    final reason = _looksGated(html)
        ? '页面里只有「打开 App / 解锁」的推广，站点没给网页版正文图'
        : '页面 ${kb}KB，但一张正文图都没识别到（站点可能临时限流，或这一话还没放出）';
    return '这一话取不到图：$reason。\n'
        '先点「重试」；还不行就翻上一话/下一话，或者换个漫画源。\n'
        '章节地址：$chapterUrl';
  }

  /// 广告页过滤要逐张探测尺寸（18 张图大约 4~6 秒），所以**不要**卡在打开章节的路上：
  /// 调用方先渲染，再在后台调这个方法，有删减就刷新一次列表。
  Future<List<String>> removeAdPages(List<String> urls) => _dropAdPages(urls);

  static final ImageProbe _probe = ImageProbe();

  /// 去掉正文里插的「推广页」（站点生成的二维码长图）。
  ///
  /// 只取每张图的前 24 KB 读尺寸，探测失败就原样返回，绝不误删正文。
  static Future<List<String>> _dropAdPages(List<String> urls) async {
    if (urls.length < 4) return urls;
    try {
      final sizes = await _probe.probe(urls);
      final kept = dropAdPages(urls, sizes);
      if (kept.length != urls.length) {
        debugPrint('[comic] adPages=${urls.length - kept.length}');
      }
      return kept;
    } catch (_) {
      return urls;
    }
  }

  /// 收尾过滤：广告 / 封面墙 / 别的漫画的推广图都不算这一话的正文。
  ///
  /// 暴露出来是为了能离线测试（真实站点的新话就是这样：网页版只给
  /// 1 张别人的漫画 + 6 张「猜你喜欢」封面）。
  @visibleForTesting
  static List<String> filterChapterImages(
    List<String> urls,
    String chapterUrl,
  ) {
    final kept = [
      for (final u in urls)
        if (!_isJunkImage(u)) u,
    ];
    _keepOnlyThisComic(kept, chapterUrl);
    return kept;
  }

  /// 从 HTML 或「一行一个地址」的文本里提取图片 URL（相对地址按 [baseUrl] 补全）。
  ///
  /// 过滤掉站点图标 / 占位图 / 追踪像素这些明显不是漫画的图。
  static List<String> extractImageUrls(
    String source, {
    required String baseUrl,
  }) {
    final urls = <String>[];
    // 包子漫画这类 AMP 站点用的是 `<amp-img src="…" data-src="…">`，
    // 不是 `<img>`；只认 <img> 会把整话的图全漏掉。
    final imgTag = RegExp(
      r'<(?:img|amp-img|image|source)\b[^>]*>',
      caseSensitive: false,
    );
    if (imgTag.hasMatch(source)) {
      // 懒加载站点常把真地址放 data-src，src 里是占位图 → 按优先级取
      for (final m in imgTag.allMatches(source)) {
        final tag = m.group(0)!;
        // 标签上声明的尺寸很小（1×1、16×16 这类）就是占位/广告图，
        // 包子漫画新话网页版给的那张「别人的漫画」推广图就是 width=1 height=1
        if (_declaredTiny(tag)) continue;
        for (final key in const [
          'data-src',
          'data-original',
          'data-lazy-src',
          'data-echo',
          'src',
        ]) {
          final a = RegExp(
            '$key\\s*=\\s*["\']([^"\']+)["\']',
            caseSensitive: false,
          ).firstMatch(tag);
          if (a != null) {
            urls.add(a.group(1)!);
            break;
          }
        }
      }
    } else {
      // 纯文本：按空白 / 换行 / || 拆
      for (final piece in source.split(RegExp(r'[\s|,]+'))) {
        if (_looksLikeImage(piece)) urls.add(piece);
      }
    }

    final out = <String>[];
    for (final raw in urls) {
      final url = resolveUrl(raw.trim(), baseUrl);
      if (url.isEmpty) continue;
      if (!_looksLikeImage(url)) continue;
      if (_isJunkImage(url)) continue;
      out.add(url);
    }
    return out;
  }

  /// 标签上声明的 width/height 很小 → 占位图 / 广告图，不是漫画正文。
  static bool _declaredTiny(String tag) {
    int? attr(String name) {
      final m = RegExp(
        '\\s$name\\s*=\\s*["\']?(\\d+)',
        caseSensitive: false,
      ).firstMatch(tag);
      return m == null ? null : int.tryParse(m.group(1)!);
    }

    final w = attr('width');
    final h = attr('height');
    if (w == null && h == null) return false;
    if (w != null && w > 0 && w < 50) return true;
    if (h != null && h > 0 && h < 50) return true;
    return false;
  }

  /// 章节地址里的「这本书」标识（`comic_id=xxx` / 路径最后一段）。
  static String? comicSlug(String chapterUrl) {
    final uri = Uri.tryParse(resolveUrl(chapterUrl, ''));
    if (uri == null) return null;
    var raw = uri.queryParameters['comic_id'] ?? uri.queryParameters['comicId'];
    raw ??= uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (raw == null || raw.isEmpty) return null;
    // 站点给变体加的后缀：`hanghaiwang-weitianrongyilang_i6wg8y` → 去掉
    final base = raw.split('_').first.toLowerCase().trim();
    if (base.length < 6) return null;
    if (base == 'comic' || base == 'chapter' || base == 'index') return null;
    return base;
  }

  /// 只留「和这一话同一本漫画」的图。
  ///
  /// 有的站点（包子漫画的新话）网页版只给一张别的漫画的推广图，真图要 App/会员。
  /// 章节地址里的 comic_id 一般也出现在真图的路径里，能对上就据此过滤；
  /// 一张都对不上且本来就只有一两张 → 当没取到，别把别人的漫画当正文显示。
  static void _keepOnlyThisComic(List<String> urls, String chapterUrl) {
    final slug = comicSlug(chapterUrl);
    if (slug == null || urls.isEmpty) return;
    final matched = urls.where((u) => u.toLowerCase().contains(slug)).toList();
    if (matched.isEmpty) {
      // 一张都对不上：章节标识很长且带连字符时（`hanghaiwang-weitianrongyilang`
      // 这种）基本可以断定是别的漫画的推广图 → 全丢，让上层提示「这话没图」。
      final strong = slug.length >= 10 && slug.contains('-');
      if (strong || urls.length <= 2) {
        debugPrint('[comic] dropForeign=${urls.length} slug=$slug');
        urls.clear();
      }
      return;
    }
    if (matched.length != urls.length) {
      debugPrint('[comic] foreign=${urls.length - matched.length} slug=$slug');
      urls
        ..clear()
        ..addAll(matched);
    }
  }

  static bool _looksLikeImage(String s) {
    if (s.isEmpty) return false;
    final lower = s.toLowerCase();
    if (lower.startsWith('data:')) return false;
    if (lower.startsWith('javascript:')) return false;
    // 书源模板没渲染出来的占位（`{{value.url}}`）不是真地址
    if (s.contains('{{') || s.contains('}}')) return false;
    if (RegExp(r'\.(jpe?g|png|webp|bmp|avif)(\?|$)').hasMatch(lower))
      return true;
    // CDN 上不带扩展名的也不少；只要像图片路径就放行
    return lower.contains('/comic/') ||
        lower.contains('/scomic/') ||
        lower.contains('/manga/') ||
        lower.contains('/chapter/');
  }

  /// 站点图标 / 占位图 / 广告追踪：不是漫画正文。
  static bool _isJunkImage(String url) {
    final lower = url.toLowerCase();
    const junk = [
      'icon',
      'logo',
      'avatar',
      'favicon',
      'placeholder',
      'loading',
      'blank.',
      'spacer',
      'pixel',
      'spacer.gif',
      '/static/',
      '/ad/',
      'stat.',
      'guiding', // 腾讯动漫的「App 导流」图
      'app-',
      'default_cover',
      'cover-default',
      '/cover/', // 站点底部的「猜你喜欢」封面墙
      'qrcode',
      'banner',
    ];
    if (lower.endsWith('.svg') || lower.endsWith('.gif')) return true;
    return junk.any(lower.contains);
  }
}

/// 这一话取不到图时抛出，携带给读者看的原因。
class ComicUnavailable implements Exception {
  ComicUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
