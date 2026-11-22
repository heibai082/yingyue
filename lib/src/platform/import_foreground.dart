// 导入时的前台服务：切后台/锁屏也不被系统冻结
//
// 说明：
// - 真正干活的仍是主 isolate 里的导入 Future，这里只负责把进程钉在前台，
//   避免 Android 把 App 冻结或回收。
// - 通知栏会显示「正在导入 x / y」，用户随时能看到进度。
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ImportForeground {
  static bool _inited = false;

  static void _ensureInit() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sakura_import',
        channelName: '导入书架',
        channelDescription: '从备份导入书架时保持后台运行',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _inited = true;
  }

  /// 开始导入时调用；text 是通知栏第一行的文字
  static Future<void> start(String text) async {
    try {
      _ensureInit();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        notificationTitle: '嘤阅 · 正在导入',
        notificationText: text,
        notificationIcon: null,
        callback: null,
      );
    } catch (_) {
      // 权限被拒/系统限制时静默降级，不影响导入本身
    }
  }

  /// 每处理完一本刷新一次进度
  static Future<void> update(String text) async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: '嘤阅 · 正在导入',
        notificationText: text,
      );
    } catch (_) {}
  }

  /// 导入结束（成功/失败/中断）都要停掉
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  /// 检查/申请通知权限；返回是否已授权。
  /// 后台导入的进度全靠通知栏，没权限就看不到。
  static Future<bool> ensurePermission() async {
    try {
      var p = await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        p = await FlutterForegroundTask.requestNotificationPermission();
      }
      return p == NotificationPermission.granted;
    } catch (_) {
      return false;
    }
  }
}
