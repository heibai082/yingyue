// 全局「当前在看/用 App」状态：后台任务（书源体检、同步）据此让路。
//
// 为什么需要：体检会开多条网络连接 + 解析 HTML，如果和阅读抢资源，
// 翻页、在线取正文会卡。阅读页进入时把 kReaderActive 置 true，
// 后台任务看到就让出并发（暂停领新活），退出阅读再继续。
import 'package:flutter/foundation.dart';

/// 是否正在阅读（阅读页存活期间为 true）。
final ValueNotifier<bool> kReaderActive = ValueNotifier<bool>(false);
