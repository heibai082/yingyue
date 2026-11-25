// WebDAV 自动备份（0.50）：每天首次启动自动上传一次，云端只留最近 N 份。
import 'backup_service.dart';
import 'prefs.dart';
import 'webdav_client.dart';

/// 自动备份结果。
class AutoBackupResult {
  const AutoBackupResult({
    required this.ran,
    this.uploaded = false,
    this.deleted = 0,
    this.reason,
  });

  final bool ran;
  final bool uploaded;
  final int deleted;
  final String? reason;
}

/// 从云端备份列表里挑出要删的（保留最近的 [keep] 份）。
///
/// 只认 `.zip`；按修改时间排序（没有时间就用文件名里的日期兜底）。
List<WebdavEntry> pickBackupsToDelete(
  List<WebdavEntry> entries, {
  int keep = 7,
}) {
  final backups = [
    for (final e in entries)
      if (!e.isDirectory && e.name.toLowerCase().endsWith('.zip')) e,
  ];
  if (backups.length <= keep) return const [];
  backups.sort((a, b) {
    final am = a.modified, bm = b.modified;
    if (am != null && bm != null && am != bm) return bm.compareTo(am);
    return b.name.compareTo(a.name); // 文件名里带日期，倒序即可
  });
  return backups.sublist(keep);
}

/// 自动备份服务（不依赖 UI，方便测试）。
class AutoBackupService {
  AutoBackupService({
    required this.prefs,
    BackupService? backup,
    WebdavClient? client,
    DateTime Function()? now,
  }) : _backup = backup ?? BackupService(prefs: prefs),
       _client = client,
       _now = now ?? DateTime.now;

  final AppPrefs prefs;
  final BackupService _backup;
  final WebdavClient? _client;
  final DateTime Function() _now;

  /// 云端只留几份。
  static const int keep = 7;

  bool get configured =>
      prefs.webdavUrl.trim().isNotEmpty && prefs.webdavUser.trim().isNotEmpty;

  /// 今天是否已经备份过。
  bool get due {
    if (!prefs.autoBackupEnabled || !configured) return false;
    final today = _dayKey(_now());
    return prefs.lastAutoBackupDay != today;
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 到点就跑一次；返回 null 表示「不需要跑」。
  Future<AutoBackupResult?> runIfDue() async {
    if (!due) return null;
    final client =
        _client ??
        WebdavClient(
          baseUrl: prefs.webdavUrl,
          user: prefs.webdavUser,
          pass: prefs.webdavPass,
        );
    var uploaded = false;
    var deleted = 0;
    String? reason;
    try {
      final dir = prefs.webdavDir.trim().isEmpty
          ? 'sakura-read/'
          : (prefs.webdavDir.endsWith('/')
                ? prefs.webdavDir
                : '${prefs.webdavDir}/');
      await client.ensureDir(dir);
      final zip = await _backup.createBackup();
      final name = zip.uri.pathSegments.last;
      await client.upload('$dir$name', await zip.readAsBytes());
      uploaded = true;
      try {
        final entries = await client.list(dir);
        for (final e in pickBackupsToDelete(entries, keep: keep)) {
          if (await client.delete('$dir${e.name}')) deleted++;
        }
      } catch (_) {
        // 清理失败不影响「今天已经备份过」
      }
    } catch (e) {
      reason = '$e';
    }
    // 无论成功失败都记今天：失败时避免一天里反复重试刷流量
    prefs.setLastAutoBackupDay(_dayKey(_now()));
    return AutoBackupResult(
      ran: true,
      uploaded: uploaded,
      deleted: deleted,
      reason: reason,
    );
  }
}
