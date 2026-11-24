import 'dart:math';

/// 书籍格式。
enum BookFormat { txt, epub, online }

/// 离线缓存的「范围偏好」。
///
/// 用户反馈：「这个缓存的章节不能有我们决定嘛，比如全部缓存，或者从当前章节
/// 缓存到最新（并且开启自动追剧模式缓存）」——原来只有一个「缓存整本」，
/// 长书（两千多章）既费流量又占空间，而且从第 1 章开始下，读到的地方反而
/// 排到很后面才下好。所以把范围做成每本书自己的设置。
enum CacheMode {
  /// 全部章节（含已经读过的）。
  all,

  /// 从某一章缓存到最新，之后自动追更。
  from,

  /// 只缓存一段固定区间（第 X 章 ~ 第 Y 章）。
  range,

  /// 这本书不自动缓存（阅读时也不再顺手预取）。
  off,
}

/// 一本书的缓存计划（范围偏好），跟着书一起持久化。
class BookCachePlan {
  const BookCachePlan({
    this.mode = CacheMode.all,
    this.start,
    this.end,
    this.updatedAt = 0,
  });

  final CacheMode mode;

  /// [CacheMode.from] 的起点 / [CacheMode.range] 的起点（0 起章节序号）。
  final int? start;

  /// [CacheMode.range] 的终点（含；null = 到最新）。
  final int? end;

  /// 最后一次设置时间（毫秒；0 = 从没设置过，按默认「全部」处理）。
  final int updatedAt;

  static const BookCachePlan defaults = BookCachePlan();

  bool get isOff => mode == CacheMode.off;

  /// 是否带「自动追更」：全部 / 从某章到最新 都算，追加新章后自动补下。
  bool get autoTrack => mode == CacheMode.all || mode == CacheMode.from;

  /// 新章节是否在这个范围内（追更时判断「要不要下这一章」）。
  ///
  /// [newestFirst] 表示目录是「最新话在前」（漫画），此时序号越小越新。
  bool covers(int index, {required bool newestFirst}) {
    switch (mode) {
      case CacheMode.all:
        return true;
      case CacheMode.off:
        return false;
      case CacheMode.from:
        final from = start ?? 0;
        // 正序目录：只要 index >= from；降序目录：只要 index <= from
        return newestFirst ? index <= from : index >= from;
      case CacheMode.range:
        final a = start ?? 0;
        final b = end;
        final lo = b == null ? a : (a < b ? a : b);
        final hi = b == null ? 1 << 30 : (a < b ? b : a);
        return index >= lo && index <= hi;
    }
  }

  /// 给用户看的一句话（详情页 / 提示用）。
  String describe(int chapterCount) {
    switch (mode) {
      case CacheMode.all:
        return '全部章节（共 $chapterCount 章）';
      case CacheMode.off:
        return '不自动缓存';
      case CacheMode.from:
        final n = ((start ?? 0) + 1).clamp(
          1,
          chapterCount <= 0 ? 1 : chapterCount,
        );
        return '第 $n 章 → 最新（自动追更）';
      case CacheMode.range:
        final a = ((start ?? 0) + 1).clamp(
          1,
          chapterCount <= 0 ? 1 : chapterCount,
        );
        final b = end == null
            ? chapterCount
            : ((end! + 1).clamp(1, chapterCount <= 0 ? 1 : chapterCount));
        return '第 $a ~ $b 章';
    }
  }

  BookCachePlan copyWith({
    CacheMode? mode,
    int? start,
    int? end,
    bool clearStart = false,
    bool clearEnd = false,
    int? updatedAt,
  }) => BookCachePlan(
    mode: mode ?? this.mode,
    start: clearStart ? null : (start ?? this.start),
    end: clearEnd ? null : (end ?? this.end),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory BookCachePlan.fromJson(Map<String, dynamic> json) => BookCachePlan(
    mode: switch (json['mode'] as String?) {
      'from' => CacheMode.from,
      'range' => CacheMode.range,
      'off' => CacheMode.off,
      _ => CacheMode.all,
    },
    start: (json['start'] as num?)?.toInt(),
    end: (json['end'] as num?)?.toInt(),
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'start': start,
    'end': end,
    'updatedAt': updatedAt,
  };
}

/// 章节引用（TXT 用字符偏移；EPUB 用 zip 条目路径）。
class ChapterRef {
  ChapterRef({
    required this.title,
    this.start,
    this.end,
    this.href,
    this.charCount = 0,
  });

  String title;

  /// TXT：章节起始字符偏移。
  final int? start;

  /// TXT：章节结束字符偏移（不含）。
  final int? end;

  /// EPUB：zip 内条目路径。
  final String? href;

  /// 章节字数（导入时计算）。
  int charCount;

  int get span => (end ?? start ?? 0) - (start ?? 0);

  factory ChapterRef.fromJson(Map<String, dynamic> json) => ChapterRef(
    title: json['title'] as String? ?? '',
    start: (json['start'] as num?)?.toInt(),
    end: (json['end'] as num?)?.toInt(),
    href: json['href'] as String?,
    charCount: (json['charCount'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'start': start,
    'end': end,
    'href': href,
    'charCount': charCount,
  };
}

/// 书架里的书籍。
class Book {
  Book({
    required this.id,
    required this.title,
    this.author = '',
    required this.format,
    required this.path,
    this.sourceUrl,
    this.coverPath,
    this.generatedCover = true,
    this.intro = '',
    List<ChapterRef>? chapters,
    this.totalChars = 0,
    this.chapterIndex = 0,
    this.charOffset = 0,
    int? addedAt,
    int? lastReadAt,
    this.finished = false,
    this.group = '',
    this.cachePlan = BookCachePlan.defaults,
    this.lastTrackedAt = 0,
    this.chapterCache = const {},
    this.discoveredChapters = const [],
  }) : chapters = chapters ?? [],
       addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch,
       lastReadAt = lastReadAt ?? 0;

  final String id;
  String title;
  String author;
  final BookFormat format;

  /// 书籍源文件绝对路径（在线书籍时为书页地址；换源时可更新）。
  String path;

  /// 在线书籍：来源书源地址（bookSourceUrl；换源时可更新）。
  String? sourceUrl;

  /// 封面图片路径（EPUB 提取后缓存的文件）。
  String? coverPath;

  /// 无封面文件时使用程序生成的渐变封面。
  bool generatedCover;

  String intro;

  final List<ChapterRef> chapters;

  /// 全书总字数（按章节 charCount 汇总）。
  int totalChars;

  /// 阅读进度：章节序号。
  int chapterIndex;

  /// 阅读进度：章节内字符偏移（与排版设置无关）。
  int charOffset;

  int addedAt;
  int lastReadAt;
  bool finished;

  /// 书架分组名（'' = 未分组）。
  ///
  /// 用户反馈：「书架里的书籍可以分组吗自定义分组」——按用户自定义的
  /// 分组名归类，分组只是书签性质，不移动文件。
  String group;

  /// 离线缓存的「范围偏好」（全部 / 从某章到最新 / 一段区间 / 不缓存）。
  ///
  /// 跟着书一起存进 book.json，换设备恢复备份后仍然生效。
  BookCachePlan cachePlan;

  /// 最后一次「追更检查」（抓目录看有没有新章）的时间（毫秒；0 = 从没查过）。
  int lastTrackedAt;

  /// 「已缓存正文的章节序号」快照（由 BookStore 维护，不写进 book.json）。
  ///
  /// 为什么放在 Book 上：读网页时每读一章都会写缓存，但没人统计过「现在缓存了
  /// 哪些章」。详情页 / 阅读页按「范围偏好」算计划时要用这份集合来跳过已缓存
  /// 的章节；放进 Book 后，各页面都能拿到同一份，且书一更新（追加新章）就
  /// 自动失效重算。
  Set<int> chapterCache;

  /// 追更时从站点目录发现的新章节（等正文缓存成功后才并入 [chapters]）。
  ///
  /// 这样「目录变了」和「缓存下好了」是同一个时间点：不会出现目录多出几十章、
  /// 正文却还没落地，用户断网一点就报错。
  List<ChapterRef> discoveredChapters;

  static final Random _rnd = Random();

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rnd.nextInt(1 << 30).toRadixString(36)}';

  int get chapterCount => chapters.length;

  int get safeChapterIndex {
    if (chapters.isEmpty) return 0;
    return chapterIndex.clamp(0, chapters.length - 1).toInt();
  }

  ChapterRef? get chapter =>
      chapters.isEmpty ? null : chapters[safeChapterIndex];

  /// 阅读进度 0~1。
  double get progress {
    if (chapters.isEmpty) return 0;
    if (finished) return 1;
    final ch = chapters[safeChapterIndex];
    final local = ch.charCount > 0 ? charOffset / ch.charCount : 0.0;
    return ((safeChapterIndex + local.clamp(0.0, 1.0)) / chapters.length)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  /// 已读字数（估算）。
  int get readChars {
    var n = 0;
    for (var i = 0; i < safeChapterIndex && i < chapters.length; i++) {
      n += chapters[i].charCount;
    }
    return n + charOffset;
  }

  String get formatLabel => switch (format) {
    BookFormat.txt => 'TXT',
    BookFormat.epub => 'EPUB',
    BookFormat.online => '在线',
  };

  String get progressLabel => '${(progress * 100).round()}%';

  factory Book.fromJson(Map<String, dynamic> json) {
    final chapters = <ChapterRef>[];
    final raw = json['chapters'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          chapters.add(ChapterRef.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return Book(
      id: json['id'] as String? ?? newId(),
      title: json['title'] as String? ?? '未命名',
      author: json['author'] as String? ?? '',
      format: switch (json['format'] as String?) {
        'epub' => BookFormat.epub,
        'online' => BookFormat.online,
        _ => BookFormat.txt,
      },
      path: json['path'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String?,
      coverPath: json['coverPath'] as String?,
      generatedCover: json['generatedCover'] as bool? ?? true,
      intro: json['intro'] as String? ?? '',
      chapters: chapters,
      totalChars: (json['totalChars'] as num?)?.toInt() ?? 0,
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      charOffset: (json['charOffset'] as num?)?.toInt() ?? 0,
      addedAt: (json['addedAt'] as num?)?.toInt(),
      lastReadAt: (json['lastReadAt'] as num?)?.toInt(),
      finished: json['finished'] as bool? ?? false,
      group: json['group'] as String? ?? '',
      cachePlan: json['cachePlan'] is Map
          ? BookCachePlan.fromJson(
              Map<String, dynamic>.from(json['cachePlan'] as Map),
            )
          : BookCachePlan.defaults,
      lastTrackedAt: (json['lastTrackedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format.name,
    'path': path,
    'sourceUrl': sourceUrl,
    'coverPath': coverPath,
    'generatedCover': generatedCover,
    'intro': intro,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'totalChars': totalChars,
    'chapterIndex': chapterIndex,
    'charOffset': charOffset,
    'addedAt': addedAt,
    'lastReadAt': lastReadAt,
    'finished': finished,
    'group': group,
    // 没设置过缓存范围的旧书不写这两项，保持 book.json 干净
    if (cachePlan.mode != CacheMode.all ||
        cachePlan.start != null ||
        cachePlan.end != null ||
        cachePlan.updatedAt != 0)
      'cachePlan': cachePlan.toJson(),
    if (lastTrackedAt != 0) 'lastTrackedAt': lastTrackedAt,
  };
}
