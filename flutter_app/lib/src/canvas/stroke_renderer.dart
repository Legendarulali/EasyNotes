import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../rust/document/paper.dart';
import '../rust/geometry/sticky_note.dart';
import '../rust/geometry/stroke.dart';

/// Must match `NOTE_PADDING` / `NOTE_LINE_HEIGHT` in the Rust PDF exporter.
const double kNotePadding = 10;
const double kNoteLineHeight = 1.3;
const Color kNoteTextColor = Color(0xFF212121);

TextStyle noteTextStyle(double fontSize) =>
    TextStyle(fontFamily: 'NoteFont', fontSize: fontSize, height: kNoteLineHeight, color: kNoteTextColor);

/// Converts the engine's flattened world-space geometry into a [ui.Path].
ui.Path buildStrokePath(StrokeRender r) {
  final g = r.geometry;
  final path = ui.Path()..fillType = ui.PathFillType.nonZero;
  if (g.length < 2) return path;
  path.moveTo(g[0], g[1]);
  for (var i = 2; i + 1 < g.length; i += 2) {
    path.lineTo(g[i], g[i + 1]);
  }
  switch (r.kind) {
    case RenderKind.filledOutline:
    case RenderKind.closedPolygon:
      path.close();
    case RenderKind.openPolyline:
      if (g.length == 2) path.lineTo(g[0] + 0.01, g[1]); // single dab
    case RenderKind.openShape:
      break;
  }
  return path;
}

/// Paint for a stroke. Highlighters use multiply blending (drawn beneath ink by the
/// scene painter); pencils use a procedural graphite grain when available.
Paint strokePaint(StrokeRender r) {
  final base = Color(r.color);
  final alpha = (base.a * r.opacity).clamp(0.0, 1.0);
  final color = base.withValues(alpha: alpha);
  final paint = Paint()
    ..isAntiAlias = true
    ..color = color;
  switch (r.kind) {
    case RenderKind.filledOutline:
      paint.style = PaintingStyle.fill;
    case RenderKind.openPolyline:
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.round;
    case RenderKind.closedPolygon:
    case RenderKind.openShape:
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.miter
        ..strokeMiterLimit = 10;
  }
  if (r.tool == ToolType.highlighter) {
    paint.blendMode = BlendMode.multiply;
  }
  final grain = PencilGrain.image;
  if (r.tool == ToolType.pencil && grain != null) {
    paint
      ..color = const Color(0xFF000000)
      ..shader = ImageShader(grain, TileMode.repeated, TileMode.repeated, PencilGrain.matrix)
      ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
  }
  return paint;
}

void drawStrokePath(Canvas canvas, ui.Path path, StrokeRender r) {
  canvas.drawPath(path, strokePaint(r));
}

/// Procedurally generated graphite texture (alpha noise with a slight diagonal grain).
class PencilGrain {
  static ui.Image? image;
  static final Float64List matrix = Float64List.fromList(const [
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1,
  ]);
  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _generate();

  static Future<void> _generate() async {
    const n = 96;
    final rnd = math.Random(42);
    final noise = List<double>.generate(n * n, (_) => rnd.nextDouble());
    final pixels = Uint8List(n * n * 4);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        // Average with the diagonal neighbour for a faint directional "tooth".
        final v = 0.6 * noise[y * n + x] + 0.4 * noise[((y + 1) % n) * n + (x + 1) % n];
        final a = (110 + v * 145).round().clamp(0, 255);
        final i = (y * n + x) * 4;
        pixels[i] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
        pixels[i + 3] = a;
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, n, n, ui.PixelFormat.rgba8888, completer.complete);
    image = await completer.future;
  }
}

Color _darken(Color c, double f) => Color.from(alpha: 1, red: c.r * f, green: c.g * f, blue: c.b * f);

/// Draws a sticky note (shadow, body, border, wrapped text) in world coordinates.
void drawStickyNote(Canvas canvas, StickyNote note, TextPainter? text, {Rect? rect}) {
  final r = rect ?? Rect.fromLTWH(note.x, note.y, note.width, note.height);
  final color = Color(note.color);
  canvas.drawRect(r.shift(const Offset(2, 3)), Paint()..color = const Color(0x1F000000));
  canvas.drawRect(r, Paint()..color = color);
  canvas.drawRect(
    r,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _darken(color, 0.82),
  );
  // Small folded-corner accent.
  final fold = math.min(18.0, math.min(r.width, r.height) * 0.18);
  final corner = ui.Path()
    ..moveTo(r.right - fold, r.bottom)
    ..lineTo(r.right, r.bottom - fold)
    ..lineTo(r.right, r.bottom)
    ..close();
  canvas.drawPath(corner, Paint()..color = _darken(color, 0.9));
  if (text != null && note.text.isNotEmpty) {
    canvas.save();
    canvas.clipRect(r);
    text.paint(canvas, r.topLeft + const Offset(kNotePadding, kNotePadding));
    canvas.restore();
  }
}

/// Paints the paper background for the world rectangle [visible]. Geometry comes from the
/// Rust [PaperSpec], so it matches the PDF export exactly. Patterns restart at [originY]
/// (each page's top on paged documents, 0 on whiteboards).
void paintPaper(Canvas canvas, Rect visible, PaperSpec spec, {double originY = 0}) {
  canvas.drawRect(visible, Paint()..color = Color(spec.background));
  switch (spec.kind) {
    case PaperKind.plain:
      return;
    case PaperKind.lined:
      final line = Paint()
        ..color = Color(spec.lineColor)
        ..strokeWidth = spec.lineWidth;
      final s = spec.spacing;
      final first = originY + spec.firstLineY;
      var y = first + math.max(0, ((visible.top - first) / s).ceil()) * s;
      for (; y <= visible.bottom; y += s) {
        canvas.drawLine(Offset(visible.left, y), Offset(visible.right, y), line);
      }
      if (spec.marginX > 0 && spec.marginX >= visible.left && spec.marginX <= visible.right) {
        canvas.drawLine(
          Offset(spec.marginX, visible.top),
          Offset(spec.marginX, visible.bottom),
          Paint()
            ..color = Color(spec.marginColor)
            ..strokeWidth = 1.2,
        );
      }
    case PaperKind.grid:
      final line = Paint()
        ..color = Color(spec.lineColor)
        ..strokeWidth = spec.lineWidth;
      final s = spec.spacing;
      for (var x = (visible.left / s).ceil() * s; x <= visible.right; x += s) {
        canvas.drawLine(Offset(x, visible.top), Offset(x, visible.bottom), line);
      }
      for (var y = originY + ((visible.top - originY) / s).ceil() * s; y <= visible.bottom; y += s) {
        canvas.drawLine(Offset(visible.left, y), Offset(visible.right, y), line);
      }
  }
}
