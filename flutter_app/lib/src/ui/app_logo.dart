import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Which part of the logo [paintAppLogo] draws.
///
/// Android's adaptive launcher icon is two 108 dp square layers that the launcher masks to its
/// own shape (circle, squircle, rounded square…). The logo's 120-unit tile maps onto their inner
/// 72 dp, the part every mask shows, so the mark keeps the proportions it has on the tile and
/// stays inside the 66 dp safe zone.
enum AppLogoLayer {
  /// The whole logo: the mark on its rounded graphite tile.
  full,

  /// The adaptive icon's back layer: the tile's gradient, filling the square.
  adaptiveBackground,

  /// The adaptive icon's front layer: the mark alone, on transparency.
  adaptiveForeground,
}

/// The app mark: a sheet of ruled paper and a stroke of blue ink on a graphite tile.
///
/// It is the one source of the logo: the website's `docs/logo.png`
/// (`integration_test/website_screenshots_test.dart`), the Windows icon and the Android launcher
/// icons (`tool/generate_app_icon.dart`) are all drawn from it.
void paintAppLogo(Canvas canvas, double size, {AppLogoLayer layer = AppLogoLayer.full}) {
  canvas.save();
  if (layer == AppLogoLayer.full) {
    canvas.scale(size / 120);
  } else {
    canvas
      ..scale(size / 108)
      ..translate(18, 18)
      ..scale(72 / 120);
  }
  switch (layer) {
    case AppLogoLayer.full:
      final tile = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 120, 120), const Radius.circular(27));
      canvas
        ..drawRRect(tile, _tilePaint())
        ..drawRRect(
          tile.deflate(.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0x22FFFFFF),
        );
      _paintMark(canvas);
    case AppLogoLayer.adaptiveBackground:
      // The whole 108 dp layer, in tile units; the gradient clamps beyond the tile.
      canvas.drawRect(const Rect.fromLTWH(-30, -30, 180, 180), _tilePaint());
    case AppLogoLayer.adaptiveForeground:
      _paintMark(canvas);
  }
  canvas.restore();
}

Paint _tilePaint() =>
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(120, 120), const [Color(0xFF3B404A), Color(0xFF15171B)]);

/// The paper and the ink, in the tile's 120-unit space.
void _paintMark(Canvas canvas) {
  canvas
    ..save()
    ..translate(57, 60)
    ..rotate(-.14);
  final paper = RRect.fromRectAndRadius(const Rect.fromLTWH(-28, -36, 56, 72), const Radius.circular(7));
  canvas.drawRRect(
    paper.shift(const Offset(0, 3)),
    Paint()
      ..color = const Color(0x80000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );
  canvas.drawRRect(paper, Paint()..color = const Color(0xFFF6F5F0));
  final rule = Paint()
    ..color = const Color(0xFFCFDDF6)
    ..strokeWidth = 1.6;
  for (final y in [-18.0, -6.0, 6.0, 18.0]) {
    canvas.drawLine(Offset(-20, y), Offset(20, y), rule);
  }
  canvas.restore();
  final ink = Path()
    ..moveTo(28, 84)
    ..cubicTo(42, 82, 64, 66, 61, 53)
    ..cubicTo(59, 43, 45, 46, 46, 59)
    ..cubicTo(47, 74, 72, 80, 96, 44);
  canvas.drawPath(
    ink,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = ui.Gradient.linear(const Offset(28, 84), const Offset(96, 44), const [Color(0xFF8AB4F8), Color(0xFF3B78F0)]),
  );
}

/// [paintAppLogo] rendered into a [size]×[size] image (transparent where nothing is drawn).
Future<ui.Image> renderAppLogo(int size, {AppLogoLayer layer = AppLogoLayer.full}) {
  final recorder = ui.PictureRecorder();
  paintAppLogo(Canvas(recorder), size.toDouble(), layer: layer);
  final picture = recorder.endRecording();
  return picture.toImage(size, size).whenComplete(picture.dispose);
}
