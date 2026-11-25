// 漫画阅读的纯逻辑：双页分组、阅读方向、亮度/色温的取值约束。
//
// 抽出来是为了能单测（UI 里只负责画），也避免"双页模式吞图/漏图"这类低级错。

/// 每页放几张图：0 = 单页，1 = 双页。
int imagesPerPage({required bool doublePage}) => doublePage ? 2 : 1;

/// 把一话的图片按顺序分组。双页从第 1 张开始两两一组（单数时最后一张单独一页）。
List<List<String>> paginateImages(
  List<String> urls, {
  required bool doublePage,
}) {
  if (urls.isEmpty) return const [];
  final per = imagesPerPage(doublePage: doublePage);
  if (per <= 1)
    return [
      for (final u in urls) [u],
    ];
  final out = <List<String>>[];
  for (var i = 0; i < urls.length; i += per) {
    final end = (i + per) > urls.length ? urls.length : i + per;
    out.add(urls.sublist(i, end));
  }
  return out;
}

/// 双页只在横屏（或屏幕够宽）时启用，竖屏仍单页，避免字太小。
bool shouldUseDoublePage({
  required bool landscape,
  required double width,
  double minWidth = 720,
}) => landscape || width >= minWidth;

/// 亮度限制（0.3 = 最暗，1 = 原始）。太暗会看不见画面，不允许到 0。
double clampBrightness(double v) => v.clamp(0.3, 1.0);

/// 色温（-1 冷 / 0 原色 / +1 暖），只用来叠一层很淡的颜色。
double clampWarmth(double v) => v.clamp(-1.0, 1.0);

/// 亮度对应的黑色遮罩透明度（亮度 1 → 0，亮度 0.3 → 0.7）。
double dimAlphaFor(double brightness) =>
    (1.0 - clampBrightness(brightness)).clamp(0.0, 0.7).toDouble();

/// 色温对应的叠加色透明度（很淡，最多 0.18）。
double warmthAlphaFor(double warmth) =>
    (clampWarmth(warmth).abs() * 0.18).toDouble();

/// 阅读方向的翻页顺序：从右往左读时 PageView 要 reverse。
bool reversePages({required bool rightToLeft}) => rightToLeft;
