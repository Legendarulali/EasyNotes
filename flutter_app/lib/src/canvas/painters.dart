import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../editor/editor_controller.dart';
import '../rust/document/page.dart';
import 'scene_cache.dart';
import 'stroke_renderer.dart';

/// Smokey "desk" around the pages of paged documents.
const Color kDeskColor = Color(0xFF1E1E1E);
const Color _pageSeparatorColor = Color(0x2E000000);
const Color _pageNumberColor = Color(0x66000000);

/// Paints the committed document for the world rectangle [visible] onto a [canvas] that
/// is already in world coordinates: page backgrounds (paper pattern or imported PDF
/// page), sticky notes, highlighters (beneath) and ink.
///
/// Shared by the on-screen [ScenePainter] and [renderThumbnail]. [pixelRatio] is device
/// pixels per world unit (decides the PDF raster resolution).
void paintDocument(
  Canvas canvas,
  EditorController c,
  Rect visible, {
  required double pixelRatio,
  bool interactive = true,
}) {
  final scene = c.scene;
  final preview = interactive ? c.selectionPreview.value : null;
  final selected = preview == null ? const <String>{} : c.selectedIds.toSet();
  final notePreview = interactive ? c.notePreview.value : null;

  // Background in the same layer so the highlighter's multiply blend sees the paper.
  if (c.isPaged) {
    _paintPages(canvas, c, visible, pixelRatio: pixelRatio, decorations: interactive);
  } else {
    paintPaper(canvas, visible, c.paperSpec);
  }

  // Sticky notes sit beneath the ink so you can annotate on top of them.
  for (final note in scene.notes) {
    if (selected.contains(note.id)) continue;
    final rect = notePreview?.id == note.id ? notePreview!.rect : note.rect;
    if (!rect.overlaps(visible)) continue;
    drawStickyNote(canvas, note, scene.noteTextPainter(note, width: rect.width), rect: rect);
  }

  // Highlighters first (beneath), then pens / pencils.
  for (final pass in const [true, false]) {
    for (final s in scene.strokes) {
      if (s.isHighlighter != pass || selected.contains(s.id) || !s.bounds.overlaps(visible)) continue;
      drawStrokePath(canvas, s.path, s.render);
    }
  }

  // Selection being moved / resized: draw it through the preview transform.
  if (preview != null) {
    canvas.save();
    preview.applyTo(canvas);
    for (final id in selected) {
      final note = scene.note(id);
      if (note != null) drawStickyNote(canvas, note, scene.noteTextPainter(note));
    }
    for (final pass in const [true, false]) {
      for (final id in selected) {
        final s = scene.stroke(id);
        if (s != null && s.isHighlighter == pass) drawStrokePath(canvas, s.path, s.render);
      }
    }
    canvas.restore();
  }
}

/// Index of the first page whose bottom lies below [y].
int firstPageAt(List<CanvasPage> pages, double y) {
  var lo = 0, hi = pages.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (pages[mid].top + pages[mid].height <= y) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

void _paintPages(Canvas canvas, EditorController c, Rect visible, {required double pixelRatio, required bool decorations}) {
  final pages = c.pages;
  final pdf = c.pdfBackgrounds;
  final visiblePdf = <int>{};
  if (decorations && pages.isNotEmpty) {
    // Soft shadow along the page column.
    final column = Rect.fromLTRB(0, 0, pages.first.width, pages.last.top + pages.last.height);
    final shadow = column.inflate(8 / math.max(pixelRatio, 0.05));
    canvas.drawRect(shadow.intersect(visible.inflate(12)), Paint()..color = const Color(0x40000000));
  }
  for (var i = firstPageAt(pages, visible.top); i < pages.length; i++) {
    final p = pages[i];
    if (p.top > visible.bottom) break;
    final rect = Rect.fromLTWH(0, p.top, p.width, p.height);
    final area = rect.intersect(visible);
    if (area.isEmpty) continue;
    final pdfPage = p.pdfPage;
    if (pdfPage != null) {
      canvas.drawRect(area, Paint()..color = const Color(0xFFFFFFFF));
      visiblePdf.add(pdfPage);
      pdf?.request(pdfPage, p.width * pixelRatio);
      final img = pdf?.image(pdfPage);
      if (img != null) {
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    } else {
      canvas.save();
      canvas.clipRect(rect);
      paintPaper(canvas, area, c.paperSpec, originY: p.top);
      canvas.restore();
    }
    if (decorations) {
      if (i > 0) {
        canvas.drawLine(
          Offset(0, p.top),
          Offset(p.width, p.top),
          Paint()
            ..color = _pageSeparatorColor
            ..strokeWidth = 1.5 / math.max(pixelRatio, 0.05),
        );
      }
      final label = _pageLabel(i + 1);
      label.paint(canvas, Offset(p.width - label.width - 16, p.top + p.height - label.height - 12));
    }
  }
  pdf?.setVisible(visiblePdf);
}

final Map<int, TextPainter> _pageLabels = {};

TextPainter _pageLabel(int number) {
  final cached = _pageLabels[number];
  if (cached != null) return cached;
  if (_pageLabels.length > 400) {
    for (final p in _pageLabels.values) {
      p.dispose();
    }
    _pageLabels.clear();
  }
  return _pageLabels[number] = TextPainter(
    text: TextSpan(
      text: '$number',
      style: const TextStyle(fontSize: 14, color: _pageNumberColor, fontFamily: 'NoteFont'),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

/// Committed content. Repaints only when the scene, viewport, PDF rasters or a transform
/// preview change – never while a stroke is being drawn (that's the [LivePainter]'s job).
class ScenePainter extends CustomPainter {
  ScenePainter(this.controller)
    : super(
        repaint: Listenable.merge([
          controller.scene,
          controller.viewport,
          controller.selectionPreview,
          controller.notePreview,
          controller.pdfBackgrounds,
        ]),
      );

  final EditorController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final vp = controller.viewport;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (controller.isPaged) canvas.drawRect(Offset.zero & size, Paint()..color = kDeskColor);
    vp.applyTo(canvas);
    paintDocument(
      canvas,
      controller,
      vp.visibleWorldRect(size),
      pixelRatio: vp.scale * controller.devicePixelRatio,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ScenePainter old) => old.controller != controller;
}

/// Renders a PNG preview of the first page (or the top-left of a whiteboard) for the
/// home screen.
Future<Uint8List?> renderThumbnail(EditorController c, {int width = 360}) async {
  Rect area;
  if (c.isPaged && c.pages.isNotEmpty) {
    final p = c.pages.first;
    area = Rect.fromLTWH(0, 0, p.width, math.min(p.height, p.width * 1.5));
  } else {
    final b = c.scene.contentBounds;
    final side = b == null ? 1000.0 : math.max(b.right, b.bottom / 0.75).clamp(600.0, 4000.0);
    area = Rect.fromLTWH(0, 0, side, side * 0.75);
  }
  final scale = width / area.width;
  final height = math.max(1, (area.height * scale).round());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.clipRect(area);
  paintDocument(canvas, c, area, pixelRatio: scale, interactive: false);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Stroke in progress, lasso / box marquee and eraser cursor.
class LivePainter extends CustomPainter {
  LivePainter(this.controller) : super(repaint: Listenable.merge([controller.live, controller.viewport]));

  final EditorController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final live = controller.live;
    final vp = controller.viewport;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    vp.applyTo(canvas);

    final preview = live.preview;
    if (preview != null) drawStrokePath(canvas, preview.path, preview.render);

    final hairline = 1.5 / vp.scale;
    final accent = const Color(0xFF3949AB);
    if (live.lasso.length > 1) {
      final path = ui.Path()..addPolygon(live.lasso, false);
      canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.06));
      _drawDashedPath(canvas, path, accent, hairline, 6 / vp.scale);
    }
    final box = live.box;
    if (box != null) {
      canvas.drawRect(box, Paint()..color = accent.withValues(alpha: 0.06));
      _drawDashedPath(canvas, ui.Path()..addRect(box), accent, hairline, 6 / vp.scale);
    }
    final eraser = live.eraserCursor;
    if (eraser != null) {
      canvas.drawCircle(eraser, live.eraserRadius, Paint()..color = const Color(0x22000000));
      canvas.drawCircle(
        eraser,
        live.eraserRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hairline
          ..color = const Color(0x99000000),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LivePainter old) => old.controller != controller;
}

/// Corner handle positions of a selection rectangle.
enum SelectionHandle { move, topLeft, topRight, bottomLeft, bottomRight }

/// Dotted selection box + resize handles, drawn in screen space so handles keep a
/// constant on-screen size at any zoom.
class SelectionOverlayPainter extends CustomPainter {
  SelectionOverlayPainter(this.controller)
    : super(repaint: Listenable.merge([controller, controller.viewport, controller.selectionPreview]));

  final EditorController controller;
  static const double handleRadius = 7;

  /// Screen rect of the selection (including an in-flight preview), or `null`.
  static Rect? screenRect(EditorController c) {
    final world = c.selectionPreview.value?.to ?? c.selectionBounds;
    if (world == null || !c.hasSelection) return null;
    return c.viewport.worldRectToScreen(world).inflate(6);
  }

  static Map<SelectionHandle, Offset> handles(Rect r) => {
    SelectionHandle.topLeft: r.topLeft,
    SelectionHandle.topRight: r.topRight,
    SelectionHandle.bottomLeft: r.bottomLeft,
    SelectionHandle.bottomRight: r.bottomRight,
  };

  /// Which handle (or the body) is under [screen]; `null` when outside.
  static SelectionHandle? hitTestSelection(EditorController c, Offset screen, {required double slop}) {
    final r = screenRect(c);
    if (r == null) return null;
    for (final e in handles(r).entries) {
      if ((e.value - screen).distance <= slop) return e.key;
    }
    return r.contains(screen) ? SelectionHandle.move : null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = screenRect(controller);
    if (r == null) return;
    const accent = Color(0xFF3949AB);
    canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.05));
    _drawDashedPath(canvas, ui.Path()..addRect(r), accent, 1.5, 6);
    for (final p in handles(r).values) {
      canvas.drawCircle(p, handleRadius + 1.5, Paint()..color = const Color(0x33000000));
      canvas.drawCircle(p, handleRadius, Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawCircle(
        p,
        handleRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SelectionOverlayPainter old) => old.controller != controller;
}

void _drawDashedPath(Canvas canvas, ui.Path path, Color color, double width, double dash) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color;
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      final end = math.min(d + dash, metric.length);
      canvas.drawPath(metric.extractPath(d, end), paint);
      d = end + dash * 0.8;
    }
  }
}
