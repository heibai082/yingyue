import 'dart:async';
import 'dart:io';

import '../source/subscription_link.dart';
import '../source/http_client.dart';

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/book_store.dart';
import '../data/auto_backup.dart';
import '../data/crash_log.dart';
import '../data/download_center.dart';
import '../data/sync_service.dart';
import '../data/cache_tracker.dart';
import '../data/app_activity.dart' show kReaderActive;
import '../data/pet_guide.dart';
import '../data/pet_store.dart';
import '../data/prefs.dart';
import '../data/stats_store.dart';
import '../platform/native_bridge.dart';
import '../platform/open_file_service.dart';
import '../platform/update_service.dart';
import '../source/daily_source_sync.dart';
import '../source/source_store.dart';
import 'reader/reader_page.dart';
import 'recent_page.dart';
import 'settings_page.dart';
import 'shelf_page.dart';
import 'source/discover_page.dart';
import 'storage_permission_page.dart';
import 'update_dialog.dart';
import 'widgets/pet_guide_overlay.dart';
import 'widgets/pet_overlay.dart' show kPetEggActive;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.prefs,
    required this.sourceStore,
    required this.statsStore,
  });

  final BookStore store;
  final AppPrefs prefs;
  final SourceStore sourceStore;
  final StatsStore statsStore;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _index = 0;
  bool? _granted;

  /// 启动后自动检查更新的延迟任务（见 [_scheduleAutoUpdateCheck]）。
  Timer? _updateCheckTimer;

  /// 每天首次打开的「书源同步 + 全量体检」延迟任务。
  Timer? _sourceSyncTimer;

  /// 自动追更 / 补缓存（见 [_scheduleCacheTrack]）。
  late final CacheTracker _cacheTracker = CacheTracker(store: widget.store);
  Timer? _cacheTrackTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 全局下载队列拿到书架（详情页 / 批量缓存都往这里排队）
    DownloadCenter.instance.bind(widget.store);
    // 老书的目录顺序（卷/话混排）也顺手修一遍
    widget.store.normalizeAllChapterOrders();
    // 崩溃日志落盘（设置里可导出）
    CrashLog.install(File('${widget.store.appDirs.files}/logs/crash.log'));
    // 同步服务器：变化推送 + 启动拉取（0.52）
    _sync.start();
    unawaited(_pullOnStartup());
    // 队列进度同步到通知栏（Android；失败静默，不影响下载）
    DownloadCenter.instance.onProgress = (task, fraction) {
      if (task == null) {
        unawaited(NativeBridge.hideDownloadProgress());
      } else {
        unawaited(
          NativeBridge.showDownloadProgress(
            title: '缓存《${task.name}》',
            text: task.label,
            fraction: fraction,
          ),
        );
      }
    };
    // 「重看新手引导」：切回书架页（引导从书架开始，后续锚点也在书架 / 导航栏）
    kPetGuideReplay.addListener(_onGuideReplay);
    kPetGuideStepId.addListener(_onGuideStepChanged);
    // 「用嘤阅打开文件」：接住系统文件打开事件（冷启动取一次 + 热启动持续监听）
    OpenFileService.instance
      ..onOpenFile = _handleOpenedFile
      ..listen();
    unawaited(_consumeLaunchFile());
    _scheduleAutoUpdateCheck();
    _scheduleDailySourceSync();
    _scheduleCacheTrack();
    _scheduleAutoBackup();
    _scheduleCacheSync();
    _check();
  }

  // ==================== 启动自动检查更新 ====================

  /// 启动后延迟几秒做一次静默更新检查。
  ///
  /// - 延迟的目的：避开开屏动画与首屏加载，不跟启动流程抢资源；
  /// - 失败静默：网络不好时不打扰用户（设置页可手动检查）；
  /// - 引导 / 彩蛋进行中不弹（避免打断首启流程与彩蛋体验）。
  void _scheduleAutoUpdateCheck() {
    // 测试环境：不发网络请求、不留 Timer（flutter test 的模拟时钟会有
    // 「pending timer」断言，且测试要完全离线可复现）。
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    _updateCheckTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_autoCheckUpdate());
    });
  }

  Future<void> _autoCheckUpdate() async {
    if (!mounted) return;
    final prefs = widget.prefs;
    if (!prefs.autoCheckUpdate) return;
    // 还没同意条款（首启流程中）→ 不打扰；下次启动再查
    if (!prefs.agreementAccepted) return;
    // 新手引导 / 彩蛋进行中 → 不打断
    if (kPetGuideActive.value || kPetEggActive.value) return;

    final result = await UpdateService.instance.check();
    if (!mounted) return;
    if (result.status != UpdateCheckStatus.updateAvailable) return;
    final info = result.info!;
    // 用户对该版本点过「以后再说」→ 不再自动弹（设置页手动检查仍可见）
    if (prefs.skipUpdateVersion == info.version) return;
    // 检查期间状态可能又变了（开始引导等）
    if (kPetGuideActive.value || kPetEggActive.value) return;

    await showUpdateDialog(context, info: info, isAuto: true, prefs: prefs);
  }

  // ==================== 每天首次：书源同步 + 体检 ====================

  // ==================== 同步服务器 ====================

  late final SyncService _sync = SyncService(
    prefs: widget.prefs,
    store: widget.store,
    marks: BookmarkStore.shared,
    stats: widget.statsStore,
    sources: widget.sourceStore,
    platform: Platform.operatingSystem,
  );

  /// 启动时拉一次最新进度；有变化就提示一句。
  Future<void> _pullOnStartup() async {
    final result = await _sync.pullOnStartup();
    if (result == null || !mounted) return;
    if (!result.ok) return;
    if (result.books > 0 || result.bookmarks > 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已从同步服务器拉取：${result.summary}')));
    }
  }
  // ==================== 缓存自动上传 ====================

  Timer? _cacheSyncTimer;

  /// 已缓存但还没上传的章节：启动后补一次，之后每 3 分钟补一次（Wi-Fi 下）。
  void _scheduleCacheSync() {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    void run() {
      if (!mounted) return;
      unawaited(_sync.silentSync(limit: 60));
    }

    Timer(const Duration(seconds: 20), run);
    _cacheSyncTimer?.cancel();
    _cacheSyncTimer = Timer.periodic(const Duration(minutes: 2), (_) => run());
  }
  // ==================== WebDAV 自动备份 ====================

  Timer? _autoBackupTimer;

  /// 每天首次启动：延迟 20 秒自动备份一次（避开开屏和追更抢网络）。
  void _scheduleAutoBackup() {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    _autoBackupTimer?.cancel();
    _sync.dispose();
    _cacheSyncTimer?.cancel();
    _autoBackupTimer = Timer(const Duration(seconds: 20), () async {
      if (!mounted) return;
      final service = AutoBackupService(prefs: widget.prefs);
      final result = await service.runIfDue();
      if (result == null || !mounted) return;
      final text = result.uploaded
          ? '已自动备份到 WebDAV'
                '${result.deleted > 0 ? '，清理了 ${result.deleted} 份旧备份' : ''}'
          : '自动备份失败：${result.reason ?? '未知原因'}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    });
  }
  // ==================== 自动追更 / 补缓存 ====================

  /// 启动后（以及每次回到前台）给「开了自动追更」的书补新章。
  ///
  /// 用户反馈：「从当前章节缓存到最新（并且开启自动追剧模式缓存）」——
  /// 手机上没法常驻后台，所以把「追更」放在每次打开 App 的头几分钟里做：
  ///   - 延迟 15 秒：避开开屏、更新检查、书源同步那几波请求；
  ///   - 同一本书 30 分钟内不重复抓目录（[CacheTracker.trackInterval]）；
  ///   - 用户一进阅读页 [kReaderActive] 就整轮让路（不抢带宽、不掉帧）；
  ///   - 设置里可以整个关掉（[AppPrefs.autoTrackCache]）。
  void _scheduleCacheTrack() {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    _cacheTrackTimer?.cancel();
    _autoBackupTimer?.cancel();
    _sync.dispose();
    _cacheSyncTimer?.cancel();
    _cacheTrackTimer = Timer(const Duration(seconds: 15), () {
      unawaited(_runCacheTrack());
    });
  }

  Future<void> _runCacheTrack() async {
    if (!mounted) return;
    if (!widget.prefs.agreementAccepted) return;
    if (!widget.prefs.autoTrackCache) return;
    if (kPetGuideActive.value || kPetEggActive.value) return;
    // 只在 Wi-Fi 下缓存：移动网络时先不追更（用户可在设置里关掉这条限制）
    if (widget.prefs.wifiOnlyDownloads && !await NativeBridge.isOnWifi()) {
      debugPrint('[cache_track] 非 Wi-Fi，跳过自动追更');
      return;
    }
    try {
      // 先清孤儿（书架里已没有的书）再追更：避免越用越占地方
      await widget.store.pruneOrphanCaches();
      final results = await _cacheTracker.trackAll();
      // 追更完看一次上限，超了就按最久没读整本清理
      await widget.store.enforceCacheLimit(widget.prefs.cacheLimitMB);
      if (!mounted) return;
      final changed = results.where((r) => r.changed).toList();
      if (changed.isEmpty) return;
      final added = changed.fold<int>(0, (n, r) => n + r.added);
      final downloaded = changed.fold<int>(0, (n, r) => n + r.downloaded);
      final text = added > 0
          ? '追更：新 $added 章，下好 $downloaded 章（${changed.length} 本书）'
          : '补缓存完成：下好 $downloaded 章';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
      );
      // 有新章时再推一条通知栏提醒（在别的页面也能看到）
      if (added > 0) {
        final names = changed.map((r) => r.name).take(3).join('、');
        unawaited(
          NativeBridge.showNewChapters(
            title: '有新章节啦（$added 章）',
            text: changed.length == 1 ? names : '$names 等 ${changed.length} 本',
          ),
        );
      }
    } catch (e) {
      debugPrint('[cache_track] 自动追更失败：$e');
    }
  }

  /// 每天第一次打开 App：拉源仓库 24 小时内的新合集 → 并入 → 全量体检
  /// （同一个源连续失败 2 次会被自动删除）。
  ///
  /// 延迟 8 秒：避开开屏动画与首屏加载，也不跟启动时的更新检查抢网络；
  /// 测试环境不排期（FLUTTER_TEST 下保持完全离线可复现）。
  void _scheduleDailySourceSync() {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    final sync = DailySourceSync(
      store: widget.sourceStore,
      prefs: widget.prefs,
    );
    if (!sync.isDue()) return;
    _sourceSyncTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_runDailySourceSync(sync));
    });
  }

  Future<void> _runDailySourceSync(DailySourceSync sync) async {
    if (!mounted) return;
    if (!widget.prefs.agreementAccepted) return;
    if (kPetGuideActive.value || kPetEggActive.value) return;
    final report = await sync.runIfDue();
    if (!mounted || !report.ran) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('书源自动同步：${report.summary}'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 冷启动：系统带文件启动时，取走路径并处理。
  Future<void> _consumeLaunchFile() async {
    final path = await OpenFileService.instance.consumeLaunchFile();
    if (path == null || !mounted) return;
    // 等首帧后再处理（书架页 / SnackBar 需要已挂载）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleOpenedFile(path);
    });
  }

  /// 分派被打开的文件：txt / epub → 导入书架并打开；json → 导入书源。
  Future<void> _handleOpenedFile(String path) async {
    if (!mounted) return;
    if (path.startsWith('legado:')) {
      try {
        final url = subscriptionUrl(path);
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('导入书源订阅'),
            content: Text('是否获取并导入以下订阅？\n$url'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('导入'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        final client = SourceHttpClient();
        try {
          final response = await client.get(url, retries: 0);
          if (!response.ok) throw StateError('请求失败');
          final report = widget.sourceStore.importFromText(response.body);
          await widget.sourceStore.flush();
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(report.summary)));
          }
        } finally {
          client.close();
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('订阅导入失败，请检查地址与网络')));
        }
      }
      return;
    }
    final ext = path.contains('.')
        ? path.substring(path.lastIndexOf('.') + 1).toLowerCase()
        : '';
    final messenger = ScaffoldMessenger.of(context);

    if (ext == 'json') {
      // 书源文件
      messenger.showSnackBar(const SnackBar(content: Text('正在导入书源…')));
      final report = await widget.sourceStore.importFromFile(path);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(report.summary)));
      setState(() => _index = 0); // 导入书源后停留书架无意义，回书架
      return;
    }

    if (ext == 'txt' || ext == 'epub') {
      // 已在书架：直接打开阅读器
      final existing = widget.store.books.where((b) => b.path == path).toList();
      if (existing.isNotEmpty && mounted) {
        setState(() => _index = 0);
        _openBook(existing.first.id);
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('正在导入…')));
      final result = await widget.store.importFile(path);
      if (!mounted) return;
      if (!result.success) {
        messenger.showSnackBar(SnackBar(content: Text(result.error ?? '导入失败')));
        return;
      }
      setState(() => _index = 0);
      _openBook(result.book!.id);
      return;
    }

    messenger.showSnackBar(SnackBar(content: Text('不支持的文件类型：.$ext')));
  }

  /// 打开指定书籍的阅读器（从书架数据取进度）。
  void _openBook(String bookId) {
    final book = widget.store.byId(bookId);
    if (book == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          store: widget.store,
          prefs: widget.prefs,
          bookId: book.id,
          chapterIndex: book.safeChapterIndex,
          charOffset: book.charOffset,
        ),
      ),
    );
  }

  /// 收到「重看新手引导」请求：把底部导航切回书架（第 1 格）。
  void _onGuideReplay() {
    if (mounted && _index != 0) setState(() => _index = 0);
  }

  Future<void> _check() async {
    final granted = await NativeBridge.hasStoragePermission();
    if (mounted) {
      setState(() => _granted = granted);
      // 权限就绪状态通知桌宠宿主（桌宠 = 开屏结束 + 权限就绪 才显示）
      petMarkHomeReady(granted);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
      // 从后台回来也补一轮（手机上「每天第一次打开」往往就是切回前台）
      _scheduleCacheTrack();
      _scheduleAutoBackup();
      _scheduleCacheSync();
    }
  }

  @override
  void dispose() {
    kPetGuideReplay.removeListener(_onGuideReplay);
    kPetGuideStepId.removeListener(_onGuideStepChanged);
    _updateCheckTimer?.cancel();
    _sourceSyncTimer?.cancel();
    _cacheTrackTimer?.cancel();
    _autoBackupTimer?.cancel();
    _sync.dispose();
    _cacheSyncTimer?.cancel();
    _cacheTracker.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 引导走到「发现 / 最近 / 设置」时，底栏跟着切过去。
  ///
  /// 引导遮罩参与手势竞争：用户点底栏时引导虽然推进了，底栏自己的点击
  /// 偶尔会被竞技场取消，于是「点一下『发现』」看起来没反应。让引导驱动
  /// 切页后，高亮的页面与实际页面永远是同一个。
  void _onGuideStepChanged() {
    const tabs = {'shelf': 0, 'discover': 1, 'recent': 2, 'settings': 3};
    final target = tabs[kPetGuideStepId.value];
    if (target == null) return;

    void apply() {
      if (!mounted) return;
      // 步骤可能已经被推进/跳过，别把用户又拽回旧页面。
      if (tabs[kPetGuideStepId.value] != target) return;
      if (_index != target) setState(() => _index = target);
    }

    apply();
    // 同一次点击里底栏自己也会处理 onSelect（引导推进 + 底栏点击会竞争），
    // 它可能在本方法之后才写回旧下标，所以这一帧结束后再对一次。
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    if (granted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!granted) {
      return StoragePermissionPage(onRecheck: _check);
    }
    return Scaffold(
      // 底栏要「毛玻璃」观感：正文滚动到栏底下时能被模糊透出来，
      // 所以主体延伸到栏后面（用户反馈：底栏玻璃没效果、全是透明）。
      extendBody: true,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: IndexedStack(
          index: _index,
          children: [
            ShelfPage(
              store: widget.store,
              prefs: widget.prefs,
              sourceStore: widget.sourceStore,
              statsStore: widget.statsStore,
            ),
            // 发现页（原在书架右上角，改到常驻底栏，用户要求）
            DiscoverPage(
              bookStore: widget.store,
              prefs: widget.prefs,
              sourceStore: widget.sourceStore,
            ),
            RecentPage(
              store: widget.store,
              prefs: widget.prefs,
              statsStore: widget.statsStore,
            ),
            SettingsPage(
              store: widget.store,
              prefs: widget.prefs,
              sourceStore: widget.sourceStore,
              statsStore: widget.statsStore,
            ),
          ],
        ),
      ),
      bottomNavigationBar: _GuidedNavBar(
        index: _index,
        onSelect: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// 底部导航 + 每格独立的引导锚点（书架 / 发现 / 最近 / 设置）。
///
/// 四格都在**常驻导航栏**上，因此引导要求用户点击时不会导致页面结构失效——
/// 这是引导设计的硬约束（指向会跳页的按钮会让后续步骤锚点消失）。
class _GuidedNavBar extends StatelessWidget {
  const _GuidedNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  /// 格数（与 [NavigationBar.destinations] 数量保持一致）。
  static const int _slots = 4;

  /// 把整条栏按等分切成 [_slots] 格。
  Rect Function(Size) _cell(int slot) =>
      (size) => Rect.fromLTWH(
        size.width * slot / _slots,
        0,
        size.width / _slots,
        size.height,
      );

  @override
  Widget build(BuildContext context) {
    return PetGuideTarget(
      id: 'nav_shelf',
      rectOf: _cell(0),
      child: PetGuideTarget(
        id: 'nav_discover',
        rectOf: _cell(1),
        child: PetGuideTarget(
          id: 'nav_recent',
          rectOf: _cell(2),
          child: PetGuideTarget(
            id: 'nav_settings',
            rectOf: _cell(3),
            child: _GlassBar(
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: onSelect,
                // 让 NavigationBar 自身透明，透出下面的模糊层，
                // 否则它的实色背景会把毛玻璃整块盖住（正是用户反馈的现象）。
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.auto_stories_outlined),
                    selectedIcon: Icon(Icons.auto_stories),
                    label: '书架',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: '发现',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history_outlined),
                    selectedIcon: Icon(Icons.history),
                    label: '最近',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.favorite_outline_rounded),
                    selectedIcon: Icon(Icons.favorite_rounded),
                    label: '设置',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底栏毛玻璃：真实模糊底下的内容 + 半透明着色 + 顶部高光描边。
///
/// 用户反馈「底栏什么玻璃没效果啊都是透明」：原先底栏背景是不透明纯色
/// （主题里 `navigationBarTheme.backgroundColor`），既没有模糊也看不出玻璃质感。
/// 这里用 [ImageFiltered] 做真实高斯模糊，再叠一层半透明主题色与细描边，
/// 配合 [Scaffold.extendBody] 就能看到正文从底栏下面透出来的玻璃效果。
class _GlassBar extends StatelessWidget {
  const _GlassBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tint = isDark ? const Color(0xFF1D1626) : Colors.white;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 透明度留一点，避免完全遮住底下滚动的内容（玻璃质感的关键）
            color: tint.withValues(alpha: isDark ? .72 : .78),
            border: Border(
              top: BorderSide(
                color: (isDark ? Colors.white : Colors.black).withValues(
                  alpha: .07,
                ),
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
