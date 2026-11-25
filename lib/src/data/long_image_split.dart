// 超长图切分（0.51）：手机 GPU 对超大纹理不友好，把特别长的图切成几段分别画。
import 'dart:ui';

/// 超过这个高宽比就算「超长图」（正常漫画页约 1.4~1.7）。
const double kLongImageRatio = 4.0;

/// 每段最多多少像素高（低于常见 GPU 纹理上限 8192）。
const double kMaxSliceHeight = 4096;

bool isLongImage(double width, double height) =>
    width > 0 && height / width > kLongImageRatio;

/// 把一张图按高度切成若干段（返回源图上的矩形，按从上到下排列）。
List<Rect> splitLongImage(
  double width,
  double height, {
  double maxSliceHeight = kMaxSliceHeight,
}) {
  if (width <= 0 || height <= 0) return const [];
  if (!isLongImage(width, height) || height <= maxSliceHeight) {
    return [Rect.fromLTWH(0, 0, width, height)];
  }
  final count = (height / maxSliceHeight).ceil();
  final sliceHeight = height / count;
  return [
    for (var i = 0; i < count; i++)
      Rect.fromLTWH(0, sliceHeight * i, width, sliceHeight),
  ];
}
