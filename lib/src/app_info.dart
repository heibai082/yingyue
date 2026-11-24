/// 应用基本信息（版本 / 作者 / 仓库）——设置页与「关于」卡共用。
///
/// 版本号与 `pubspec.yaml` 的 `version` 保持同步（发版时一起改）。
class AppInfo {
  AppInfo._();

  /// 语义化版本（不含 build 号）。
  static const String version = '0.38';

  /// 作者（本构建的维护者）。
  static const String author = 'heibai082';

  /// 原项目：嘤阅是在 sakura-read 基础上改的，MIT 许可，必须署名致谢。
  static const String upstream = 'https://github.com/akira399/sakura-read';

  /// 原作者。
  static const String upstreamAuthor = 'akira399';

  /// 开源仓库地址。
  static const String repo = 'https://github.com/heibai082/yingyue';

  /// 自己的下载镜像目录（APK 就放在这里），比 GitHub 镜像快很多
  static const String updateMirror =
      'https://rakazo.130824.xyz:3824/wecom-rk/share';

  /// 用途声明：这版是自用构建，不对外分发。
  static const String buildNotice = '个人自用构建 · 不对外分发 · 不提供支持';

  /// 许可证。
  static const String license = 'MIT License';
}
