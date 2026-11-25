// 超长图分段渲染（只用于「已经落盘」的图片，网络图继续走原生的 Image.network）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/long_image_split.dart';

/// 本地图片：普通图直接显示；超长图按段画，避免一次性生成超大纹理。
class SlicedFileImage extends StatefulWidget {
  const SlicedFileImage({
    super.key,
    required this.file,
    this.fit = BoxFit.fitWidth,
    this.maxSliceHeight = kMaxSliceHeight,
  });

  final File file;
  final BoxFit fit;
  final double maxSliceHeight;

  @override
  State<SlicedFileImage> createState() => _SlicedFileImageState();
}

class _SlicedFileImageState extends State<SlicedFileImage> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SlicedFileImage old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) {
      _image?.dispose();
      _image = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final provider = FileImage(widget.file);
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!mounted) return;
        setState(() => _failed = true);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    // 还没解码完 / 解码失败 / 不是超长图：交给普通 Image（首帧快、行为不变）
    if (image == null || _failed) {
      return Image.file(widget.file, fit: widget.fit);
    }
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final slices = splitLongImage(w, h, maxSliceHeight: widget.maxSliceHeight);
    if (slices.length <= 1) {
      return Image.file(widget.file, fit: widget.fit);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final rect in slices)
          AspectRatio(
            aspectRatio: rect.width / rect.height,
            child: CustomPaint(painter: _SlicePainter(image, rect)),
          ),
      ],
    );
  }
}

class _SlicePainter extends CustomPainter {
  _SlicePainter(this.image, this.src);

  final ui.Image image;
  final Rect src;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_SlicePainter old) => old.image != image || old.src != src;
}
