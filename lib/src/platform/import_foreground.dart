// 后台任务的前台服务：切后台/锁屏也不被系统冻结（导入、书源体检共用）。
//
// 关键点（Android 13/14）：
// - 必须声明 serviceTypes: dataSync，否则 startService 直接抛异常；
// - 通知权限要单独申请，没授权时服务能跑但通知不显示；
// - 需要一个 TaskHandler 回调，插件才会真正把服务拉起来。
//
// 说明：真正的活仍在主 isolate 里跑，这里只借前台服务保活 + 出通知栏进度。
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 服务的入口回调（必须顶层函数 + vm:entry-point）
@pragma('vm:entry-point')
void importTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundTaskHandler());
}

/// 我们只借前台服务保活，不需要它做任何事
class _BackgroundTaskHandler extends TaskHandler {
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

  /// 当前任务的标题（通知栏用；换任务时一起更新）
  static String _title = '嘤阅 · 正在导入';

  static Future<void> _ensureInit() async {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'yingyue_tasks',
        channelName: '后台任务',
        channelDescription: '导入书架、书源体检等需要后台继续跑的任务',
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

  /// 启动（或复用）前台服务，并设置标题/文案。
  static Future<bool> startTask({
    required String title,
    required String text,
  }) async {
    try {
      _title = title;
      await _ensureInit();
      if (await FlutterForegroundTask.isRunningService) {
        await updateTask(title: title, text: text);
        return true;
      }
      // MIUI/省电模式会拦前台服务，先申请忽略电池优化（失败也无妨）
      try {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      } catch (_) {}

      final result = await FlutterForegroundTask.startService(
        serviceId: 2101,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: title,
        notificationText: text,
        notificationIcon: null,
        callback: importTaskCallback,
      );
      if (result is ServiceRequestSuccess) {
        lastError = null;
        return true;
      }
      lastError = result is ServiceRequestFailure
          ? result.error.toString()
          : result.toString();
      return false;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  /// 刷新通知栏标题与进度。
  static Future<void> updateTask({
    required String title,
    required String text,
  }) async {
    try {
      _title = title;
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {}
  }

  /// 停止当前任务的前台服务。
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  /// 当前标题（调试/日志用）。
  static String get currentTitle => _title;

  /// 兼容旧调用：导入书架。
  static Future<bool> start(String text) =>
      startTask(title: '嘤阅 · 正在导入', text: text);

  /// 兼容旧调用：刷新导入进度。
  static Future<void> update(String text) =>
      updateTask(title: '嘤阅 · 正在导入', text: text);
}
