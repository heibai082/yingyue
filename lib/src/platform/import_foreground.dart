// 导入时的前台服务：切后台/锁屏也不被系统冻结
//
// 关键点（Android 13/14）：
// - 必须声明 serviceTypes: dataSync，否则 startService 直接抛异常；
// - 通知权限要单独申请，没授权时服务能跑但通知不显示；
// - 需要一个 TaskHandler 回调，插件才会真正把服务拉起来。
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 服务的入口回调（必须顶层函数 + vm:entry-point）
@pragma('vm:entry-point')
void importTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_ImportTaskHandler());
}

/// 我们只借前台服务保活，不需要它做任何事
class _ImportTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class ImportForeground {
  static bool _inited = false;

  /// 最近一次启动失败的原因（页面可展示）
  static String? lastError;

  static Future<void> _ensureInit() async {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'yingyue_import',
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

  /// 检查/申请通知权限；返回是否已授权。
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

  /// 开始导入时调用；返回是否真的把服务拉起来了
  static Future<bool> start(String text) async {
    try {
      await _ensureInit();
      if (await FlutterForegroundTask.isRunningService) {
        await update(text);
        return true;
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 2101,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: '嘤阅 · 正在导入',
        notificationText: text,
        notificationIcon: null,
        callback: importTaskCallback,
      );
      if (result is ServiceRequestSuccess) {
        lastError = null;
        return true;
      }
      lastError = result.toString();
      return false;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  /// 刷新通知栏进度
  static Future<void> update(String text) async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: '嘤阅 · 正在导入',
        notificationText: text,
      );
    } catch (_) {}
  }

  /// 导入结束（含异常）都要停
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
