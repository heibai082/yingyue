// 检查更新 + 下载新版本安装包（GitHub Release，国内镜像加速）。
//
// 为什么独立成服务：网络链路（多端点回退 / 镜像前缀 / 大小校验）需要
// 可测试，全部走注入的 http.Client，测试用 MockClient 覆盖。
//
// 链路设计：
//   - 检查：gh-proxy 透传 GitHub API → 直连 GitHub API → ungh.cc，
//     任一成功即出结果（返回 200 但数据不完整时继续下一个）；
//   - 下载：NAS 镜像 → ghfast.top → gh-proxy.com → ghproxy.net → 直连；
//     大包先并发测速再按「实测最快」排序，下载本身走多线程分块，
//     「全程成功 + 大小校验通过」才算成功，否则换下一条线路。
//
// 为什么多线程：自己的 NAS 出口单条 TCP 只有 ~250 KB/s，但 8 条并发能到
// ~2 MB/s（实测），分块下载把这部分带宽吃满；镜像线路同理，只是收益小些。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../app_info.dart';

/// 「检查更新」的结果状态。
enum UpdateCheckStatus {
  /// 有新版本可用。
  updateAvailable,

  /// 已是最新（含设备版本比线上更新的情况）。
  upToDate,

  /// 所有端点都失败（网络问题等）。
  failed,
}

/// 一次「检查更新」的完整结果。
class UpdateCheckResult {
  const UpdateCheckResult._(this.status, this.info, this.error);

  final UpdateCheckStatus status;

  /// 有新版时的详情；其余状态为 null。
  final UpdateInfo? info;

  /// 失败原因（用于调试与日志）。
  final String? error;

  static UpdateCheckResult available(UpdateInfo info) =>
      UpdateCheckResult._(UpdateCheckStatus.updateAvailable, info, null);

  static UpdateCheckResult upToDate() =>
      const UpdateCheckResult._(UpdateCheckStatus.upToDate, null, null);

  static UpdateCheckResult failed([String? error]) =>
      UpdateCheckResult._(UpdateCheckStatus.failed, null, error);
}

/// 线上 release 的解析结果。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.title,
    required this.notes,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.publishedAt,
    required this.pageUrl,
  });

  /// 语义版本（去掉前缀 v），如 `1.0.1`。
  final String version;

  /// release 标题（如「嘤阅 v1.0.1 ── ...」）。
  final String title;

  /// 更新说明（已做 markdown 轻量清洗，可直接展示）。
  final String notes;

  /// GitHub 原始下载地址（下载时依次套用镜像前缀）。
  final String downloadUrl;

  /// 安装包大小（字节；0 = 未知）。
  final int sizeBytes;

  /// 发布时间（ISO8601 字符串，可为空）。
  final String publishedAt;

  /// release 页面地址（浏览器打不开时的兜底去处）。
  final String pageUrl;
}

/// 一条下载线路：显示名 + 拼好的完整 URL。
class DownloadSource {
  const DownloadSource(this.label, this.url);

  /// 给用户看的线路名（如「NAS 镜像」「ghfast.top 镜像」）。
  final String label;

  /// 可直接 GET 的安装包地址。
  final String url;
}

/// 检查更新 / 下载安装包服务。
///
/// 由 [instance] 单例在 App 内共享；测试用 `UpdateService(client: mock)`
/// 构造独立实例（注入 MockClient）。
class UpdateService {
  UpdateService({
    http.Client? client,
    this.connections = 8,
    this.segmentThresholdBytes = 4 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 分块下载的并发连接数。
  final int connections;

  /// 小于该大小的包里不做测速、不分块（一次流式下载就够快，省流量）。
  final int segmentThresholdBytes;

  /// 全局共享实例（App 内使用）。
  static final UpdateService instance = UpdateService();

  /// 单端点超时。
  static const Duration _checkTimeout = Duration(seconds: 10);

  /// 测速时每条线路最多采样的字节数 / 最长耗时。
  static const int _probeSpan = 128 * 1024;
  static const Duration _probeWindow = Duration(milliseconds: 2500);

  /// 检查端点（按顺序回退；由 [AppInfo.repo] 派生，仓库地址只维护一处）。
  static List<String> get checkEndpoints {
    final path = Uri.parse(AppInfo.repo).path; // /akira399/sakura-read
    return [
      'https://gh-proxy.com/https://api.github.com/repos$path/releases/latest',
      'https://api.github.com/repos$path/releases/latest',
      'https://ungh.cc/repos$path/releases/latest',
    ];
  }

  /// 下载镜像前缀（按顺序回退）；空串 = 直连 GitHub。
  ///
  /// 实测（写入项目时）：前三个均能对 release 下载链返回 200；
  /// 直连兜底通常无效但保留（部分网络环境下可通）。
  static const List<String> downloadMirrors = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
    '',
  ];

  /// 检查是否有新版本。
  ///
  /// [currentVersion] 默认取 [AppInfo.version]（测试可传任意版本）。
  Future<UpdateCheckResult> check({
    String currentVersion = AppInfo.version,
  }) async {
    String? lastError;
    for (final endpoint in checkEndpoints) {
      try {
        final resp = await _client
            .get(
              Uri.parse(endpoint),
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'SakuraRead',
              },
            )
            .timeout(_checkTimeout);
        if (resp.statusCode != 200) {
          lastError = '$endpoint -> HTTP ${resp.statusCode}';
          continue;
        }
        final info = parseReleaseJson(jsonDecode(utf8.decode(resp.bodyBytes)));
        if (info == null || info.downloadUrl.isEmpty) {
          lastError = '$endpoint -> 数据不完整';
          continue;
        }
        return isNewerVersion(info.version, currentVersion)
            ? UpdateCheckResult.available(info)
            : UpdateCheckResult.upToDate();
      } catch (e) {
        lastError = '$endpoint -> $e';
      }
    }
    return UpdateCheckResult.failed(lastError);
  }

  /// 下载线路：自己的 NAS 镜像 → 国内 GitHub 镜像 → 直连。
  ///
  /// [downloadUrl] 是 release 附件的原始地址；附件文件名在 NAS 上同名存放。
  List<DownloadSource> sourcesFor(String downloadUrl) {
    final parsed = Uri.tryParse(downloadUrl);
    final assetName = (parsed != null && parsed.pathSegments.isNotEmpty)
        ? parsed.pathSegments.last
        : '';
    return [
      if (assetName.isNotEmpty && AppInfo.updateMirror.trim().isNotEmpty)
        DownloadSource('NAS 镜像', '${AppInfo.updateMirror.trim()}/$assetName'),
      for (final prefix in downloadMirrors)
        DownloadSource(_labelOf(prefix), '$prefix$downloadUrl'),
    ];
  }

  /// 镜像前缀 → 展示名（`''` 是直连 GitHub）。
  static String _labelOf(String prefix) {
    if (prefix.isEmpty) return 'GitHub 直连';
    final host = Uri.tryParse(prefix)?.host ?? '';
    return host.isEmpty ? '镜像' : '$host 镜像';
  }

  /// 下载 APK 到 [targetPath]。
  ///
  /// - 线路按 [sourcesFor] 生成；大包先并发测速，按实测速度排序后再下；
  /// - 每条线路内部先试多线程分块，服务器不支持 Range 时退回单流；
  /// - 任一线路「全程成功 + 大小校验通过」即返回 true，否则换下一条；
  /// - [onProgress]：`(已下载字节, 总字节)`（总字节未知时为 0）；
  /// - [onSource]：当前正在用的线路名（给 UI 显示，避免「国内镜像」这种
  ///   与实际不符的文案）；
  /// - [isCancelled]：返回 true 时中止下载（清理半成品），返回 false。
  Future<bool> download(
    UpdateInfo info,
    String targetPath, {
    void Function(int received, int total)? onProgress,
    void Function(String label)? onSource,
    bool Function()? isCancelled,
  }) async {
    final sources = sourcesFor(info.downloadUrl);
    if (sources.isEmpty) return false;

    final expected = info.sizeBytes;
    final useParts = expected >= segmentThresholdBytes;

    // 多线路时先测速：NAS 单连接受出口带宽限制，镜像有时反而更快
    var ordered = sources;
    if (useParts && sources.length > 1) {
      ordered = await _rankBySpeed(sources, isCancelled);
    }

    for (final source in ordered) {
      if (isCancelled?.call() == true) return false;
      onSource?.call(source.label);
      try {
        if (useParts) {
          final ok = await _downloadSegmented(
            source,
            targetPath,
            expected,
            onProgress,
            isCancelled,
          );
          if (ok) return true;
        }
        final ok = await _downloadSingle(
          source.url,
          targetPath,
          expected,
          onProgress,
          isCancelled,
        );
        if (ok) return true;
      } on _Cancelled {
        return false;
      } catch (_) {
        // 本线路失败：继续下一条
        if (isCancelled?.call() == true) return false;
      }
    }
    return false;
  }

  /// 并发测速后按「快 → 慢」排序；测不出速度的线路排在最后（仍会尝试）。
  Future<List<DownloadSource>> _rankBySpeed(
    List<DownloadSource> sources,
    bool Function()? isCancelled,
  ) async {
    final speeds = await Future.wait(
      sources.map((source) async {
        if (isCancelled?.call() == true) return 0;
        try {
          return await _probeSpeed(source.url);
        } catch (_) {
          return 0;
        }
      }),
    );
    final order = List<int>.generate(sources.length, (i) => i);
    order.sort((a, b) {
      final bySpeed = speeds[b].compareTo(speeds[a]);
      return bySpeed != 0 ? bySpeed : a.compareTo(b);
    });
    return [for (final i in order) sources[i]];
  }

  /// 拉一小段数据估个速度（字节/秒）；0 表示这条线路不通。
  Future<int> _probeSpeed(String url) async {
    final watch = Stopwatch()..start();
    final head = await _openRange(url, 0, _probeSpan - 1);
    if (head.statusCode != 200 && head.statusCode != 206) {
      await _abandon(head);
      return 0;
    }
    var bytes = 0;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final sub = head.stream.listen(
      (chunk) {
        bytes += chunk.length;
        if (bytes >= _probeSpan) finish();
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    final timer = Timer(_probeWindow, finish);
    await done.future;
    timer.cancel();
    await sub.cancel();
    if (bytes <= 0) return 0;
    final ms = watch.elapsedMilliseconds;
    return (bytes * 1000) ~/ (ms <= 0 ? 1 : ms);
  }

  /// 单流下载：先写 `.part` 临时文件，完成后做大小校验并改名。
  Future<bool> _downloadSingle(
    String url,
    String targetPath,
    int expectedBytes,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await _client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    final tmp = File('$targetPath.part');
    final sink = tmp.openWrite();
    var received = 0;
    final total = resp.contentLength ?? expectedBytes;
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in resp.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (isCancelled?.call() == true) throw const _Cancelled();
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 100) {
          lastEmit = now;
          onProgress?.call(received, total);
        }
      }
      await sink.close();
    } catch (e) {
      await sink.close();
      await _quietDelete(tmp);
      rethrow;
    }
    // 大小校验：镜像返回错误页 / 传输截断时拒绝（防止装到坏包）
    if (expectedBytes > 0 && received != expectedBytes) {
      await _quietDelete(tmp);
      throw const FileSystemException('安装包大小校验失败');
    }
    await _quietDelete(file);
    await tmp.rename(targetPath);
    onProgress?.call(received, expectedBytes > 0 ? expectedBytes : total);
    return true;
  }

  /// 多线程分块下载（HTTP Range + 预分配文件）。
  ///
  /// 返回 false = 这条线路不支持 Range，交给 [_downloadSingle] 单流下。
  Future<bool> _downloadSegmented(
    DownloadSource source,
    String targetPath,
    int expectedBytes,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final head = await _openRange(source.url, 0, _probeSpan - 1);
    final total = head.totalBytes > 0 ? head.totalBytes : expectedBytes;
    final rangeOk = head.statusCode == 206 && total > 0;
    await _abandon(head);
    if (!rangeOk) return false;
    if (expectedBytes > 0 && total != expectedBytes) {
      throw const FileSystemException('安装包大小不一致');
    }

    final tmp = File('$targetPath.part');
    await tmp.parent.create(recursive: true);
    final file = await tmp.open(mode: FileMode.write);
    var closed = false;
    var aborted = false;
    final lock = _WriteLock();
    final progress = _PartProgress(onProgress, total, connections);
    try {
      // 预分配：先把文件撑到最终大小，后面各线程按偏移写
      await file.truncate(total);
      final partSize = (total + connections - 1) ~/ connections;
      final tasks = <Future<void>>[];
      for (var i = 0; i < connections; i++) {
        final start = i * partSize;
        if (start >= total) break;
        final end = math.min(total, start + partSize) - 1;
        tasks.add(
          _fetchPart(
            index: i,
            url: source.url,
            start: start,
            end: end,
            file: file,
            lock: lock,
            progress: progress,
            isCancelled: isCancelled,
            isAborted: () => aborted,
          ),
        );
      }
      await Future.wait(tasks);
      await file.close();
      closed = true;
      progress.flush();
      if (await tmp.length() != total) {
        throw const FileSystemException('安装包大小校验失败');
      }
      await _quietDelete(File(targetPath));
      await tmp.rename(targetPath);
      return true;
    } catch (e) {
      aborted = true;
      if (!closed) {
        try {
          await file.close();
        } catch (_) {}
      }
      await _quietDelete(tmp);
      rethrow;
    }
  }

  /// 拉一个分段并写进文件对应偏移；失败重试一次。
  Future<void> _fetchPart({
    required int index,
    required String url,
    required int start,
    required int end,
    required RandomAccessFile file,
    required _WriteLock lock,
    required _PartProgress progress,
    bool Function()? isCancelled,
    required bool Function() isAborted,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      var stopped = false;
      try {
        progress.resetPart(index);
        var pos = start;
        final req = http.Request('GET', Uri.parse(url))
          ..headers['Range'] = 'bytes=$start-$end';
        final resp = await _client.send(req).timeout(
          const Duration(seconds: 20),
        );
        if (resp.statusCode != 206) {
          throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
        }
        await for (final chunk in resp.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (isAborted() || isCancelled?.call() == true) {
            stopped = true;
            throw const _Cancelled();
          }
          final data = chunk;
          await lock.run(() async {
            await file.setPosition(pos);
            await file.writeFrom(data);
          });
          pos += data.length;
          progress.addTo(index, data.length);
        }
        if (pos != end + 1) {
          throw const FileSystemException('分段数据不完整');
        }
        return;
      } on _Cancelled {
        if (stopped || isAborted()) rethrow;
        // 取消：直接退出，不重试
        if (isCancelled?.call() == true) rethrow;
        if (attempt >= 2) rethrow;
      } catch (_) {
        if (attempt >= 2 || isAborted() || isCancelled?.call() == true) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// 发一个 Range 请求，顺带解析出「文件总大小」。
  Future<_RangeHead> _openRange(String url, int start, int end) async {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['Range'] = 'bytes=$start-$end';
    final resp = await _client.send(req).timeout(const Duration(seconds: 15));
    var total = 0;
    final contentRange = resp.headers['content-range'];
    if (contentRange != null) {
      final match = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      if (match != null) total = int.tryParse(match.group(1)!) ?? 0;
    }
    if (total == 0 && resp.statusCode == 200 && resp.contentLength != null) {
      total = resp.contentLength!;
    }
    return _RangeHead(resp.statusCode, total, resp.stream);
  }

  /// 丢掉不再需要的响应体（避免连接泄漏），不等它下完。
  Future<void> _abandon(_RangeHead head) async {
    try {
      final sub = head.stream.listen(null);
      await sub.cancel();
    } catch (_) {}
  }

  Future<void> _quietDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 一次 Range 请求的结果。
class _RangeHead {
  const _RangeHead(this.statusCode, this.totalBytes, this.stream);

  final int statusCode;

  /// 文件总字节数（从 Content-Range / Content-Length 推出来，0 = 未知）。
  final int totalBytes;

  final Stream<List<int>> stream;
}

/// 用户取消下载。
class _Cancelled implements Exception {
  const _Cancelled();
}

/// 串行化对同一个 [RandomAccessFile] 的「定位 + 写入」，避免多线程互相踩。
class _WriteLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return previous.then((_) => action()).whenComplete(released.complete);
  }
}

/// 分段进度汇总：重试的分段会把该段清零，避免百分比虚高。
class _PartProgress {
  _PartProgress(this._onProgress, this.total, int parts)
    : _received = List<int>.filled(parts, 0);

  final void Function(int, int)? _onProgress;
  final int total;
  final List<int> _received;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  int get received => _received.fold(0, (a, b) => a + b);

  void resetPart(int index) => _received[index] = 0;

  void addTo(int index, int bytes) {
    _received[index] += bytes;
    final cb = _onProgress;
    if (cb == null) return;
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds < 120 && received < total) return;
    _last = now;
    cb(received, total);
  }

  void flush() => _onProgress?.call(received, total);
}

/// 语义版本比较：`candidate` 是否比 `current` 新。
///
/// - 容忍 `v` 前缀与 `1.2.3-beta.1` 这类预发布后缀（只比较数字段）；
/// - 逐段比较，缺失段按 0 处理（`1.0` vs `1.0.1` 视作更旧）；
/// - 完全相同时返回 false（避免每次启动重复提示同一版本）。
bool isNewerVersion(String candidate, String current) {
  final a = _versionParts(candidate);
  final b = _versionParts(current);
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

List<int> _versionParts(String raw) {
  final cleaned = raw.trim().replaceFirst(RegExp('^[vV]'), '');
  final core = cleaned.split('-').first.split('+').first;
  return core.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
}

/// 解析 release JSON（同时兼容 GitHub API 与 ungh.cc 两种格式）：
///
/// - GitHub API：`tag_name` / `name` / `body` / `assets[].browser_download_url`
///   / `published_at` / `html_url`；
/// - ungh.cc：`{"release": {tag / name / markdown / assets[].downloadUrl
///   / publishedAt / htmlUrl}}`。
UpdateInfo? parseReleaseJson(Object? json) {
  if (json is! Map) return null;
  final release = json['release'] is Map ? json['release'] as Map : json;

  final tag = _firstString(release, ['tag_name', 'tag']);
  if (tag.isEmpty) return null;

  final asset = _pickApkAsset(release['assets']);

  final downloadUrl = asset == null
      ? ''
      : _firstString(asset, ['browser_download_url', 'downloadUrl']);
  final size = asset == null ? 0 : _firstInt(asset, ['size']);
  final name = _firstString(release, ['name']);
  final body = _firstString(release, ['body', 'markdown']);
  final publishedAt = _firstString(release, ['published_at', 'publishedAt']);
  final htmlUrl = _firstString(release, ['html_url', 'htmlUrl']);

  return UpdateInfo(
    version: tag.replaceFirst(RegExp('^[vV]'), ''),
    title: name.isEmpty ? '嘤阅 $tag' : name,
    notes: cleanReleaseNotes(body),
    downloadUrl: downloadUrl,
    sizeBytes: size,
    publishedAt: publishedAt,
    pageUrl: htmlUrl.isEmpty ? '${AppInfo.repo}/releases' : htmlUrl,
  );
}

/// 从 release 的 `assets[]` 里挑出「应该给这台手机装」的那个 APK。
///
/// 一个 release 同时挂 arm64 与 x86_64 两个包时，GitHub 按**文件名**返回，
/// `…-x86_64.apk` 会排在 `…-arm64.apk` 前面——直接取 `assets[0]` 会让手机
/// 下到只能跑在模拟器上的包（安装报 INSTALL_FAILED_NO_MATCHING_ABIS）。
/// 因此按架构打分：arm64 / aarch64 > universal > 无架构标记 > x86 / x64。
Map? _pickApkAsset(Object? assets) {
  if (assets is! List) return null;
  Map? best;
  var bestScore = -1;
  for (final item in assets) {
    if (item is! Map) continue;
    final name = _firstString(item, [
      'name',
      'browser_download_url',
      'downloadUrl',
    ]).toLowerCase();
    if (!name.contains('.apk')) continue;
    final int score;
    if (name.contains('arm64') || name.contains('aarch64')) {
      score = 3;
    } else if (name.contains('universal') || name.contains('all-abi')) {
      score = 2;
    } else if (name.contains('x86') || name.contains('x64')) {
      score = 0;
    } else {
      score = 1;
    }
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return best;
}

String _firstString(Map map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return '';
}

int _firstInt(Map map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is num) return value.toInt();
  }
  return 0;
}

/// 轻量清洗 release 说明（markdown → 纯文本）：保留结构与换行，去掉装饰。
///
/// 只做「阅读友好」处理，不追求完整 markdown 渲染（详情可跳 release 页）。
String cleanReleaseNotes(String markdown) {
  var s = markdown.replaceAll('\r\n', '\n');
  // 图片 ![alt](url) 与链接 [text](url)
  s = s.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  s = s.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // HTML 标签与行内代码标记
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAll('`', '');
  // 行首标题 # / 引用 > / 列表符（- * + 与数字序号）
  s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '· ');
  s = s.replaceAll(RegExp(r'^\s{0,3}\d+\.\s+', multiLine: true), '· ');
  // 加粗 / 斜体 / 水平线
  s = s.replaceAll('**', '').replaceAll('__', '');
  s = s.replaceAll(RegExp(r'^\s*[-*_]{3,}\s*$', multiLine: true), '');
  // 连续空行压缩（最多保留一个空行）
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}
