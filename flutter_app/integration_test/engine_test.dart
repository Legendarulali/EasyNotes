// End-to-end checks through the real FFI bridge. Run on a device / desktop with:
//   flutter test integration_test/engine_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_app/main.dart';
import 'package:flutter_app/src/rust/api/stroke_api.dart';
import 'package:flutter_app/src/rust/document/eraser.dart';
import 'package:flutter_app/src/rust/document/page.dart';
import 'package:flutter_app/src/rust/document/paper.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:flutter_app/src/rust/geometry/point.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _pen = Brush(color: 0xFF1A1A1A, width: 3, opacity: 1);

StrokeRender? _drawPolyline(List<Offset> corners, {bool autoCorrect = true, int steps = 20}) {
  beginStroke(tool: ToolType.pen, brush: _pen);
  for (var i = 0; i + 1 < corners.length; i++) {
    for (var k = 0; k < steps; k++) {
      final p = Offset.lerp(corners[i], corners[i + 1], k / steps)!;
      addPoint(
        point: StrokePoint(x: p.dx, y: p.dy + math.sin(k.toDouble()) * 1.5, pressure: 0.5),
      );
    }
  }
  final last = corners.last;
  addPoint(
    point: StrokePoint(x: last.dx, y: last.dy, pressure: 0.5),
  );
  return finishStroke(tool: ToolType.pen, autoCorrect: autoCorrect);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  setUp(() => newDocument(kind: DocumentKind.notebook, paper: PaperStyle.dictando));

  test('hand-drawn rectangle snaps to a clean axis-aligned rectangle on pen-up', () {
    final r = _drawPolyline(const [
      Offset(100, 100),
      Offset(300, 104),
      Offset(297, 220),
      Offset(102, 216),
      Offset(101, 102),
    ])!;
    expect(r.kind, RenderKind.closedPolygon);
    expect(r.geometry.length, 8);
    final g = r.geometry;
    for (var i = 0; i < 4; i++) {
      final dx = (g[(2 * i + 2) % 8] - g[2 * i]).abs();
      final dy = (g[(2 * i + 3) % 8] - g[2 * i + 1]).abs();
      expect(dx < 1e-3 || dy < 1e-3, isTrue, reason: 'edge $i must be axis aligned');
    }
  });

  test('freehand stroke stays freehand', () {
    final r = _drawPolyline(const [Offset(10, 10), Offset(200, 60), Offset(260, 30)])!;
    expect(r.kind, RenderKind.filledOutline);
  });

  test('notebooks start with one 1000 × 1000 page and grow downwards', () {
    final info = documentInfo();
    expect(info.pages, hasLength(1));
    expect(info.pages.first.width, 1000);
    expect(info.pages.first.height, 1000);
    final next = appendPage()!;
    expect(next.top, 1000);
    // Drawing below the last page appends one.
    _drawPolyline(const [Offset(100, 1800), Offset(100, 2400)], autoCorrect: false);
    expect(pageCount(), 3);
  });

  test('stroke eraser deletes, classic eraser splits', () {
    final a = _drawPolyline(const [Offset(20, 100), Offset(400, 100)], autoCorrect: false)!;
    final cut = eraseAlong(x0: 200, y0: 60, x1: 200, y1: 140, radius: 6, mode: EraserMode.partial);
    expect(cut.upsertedStrokes, hasLength(2));
    expect(cut.upsertedStrokes.first.id, a.id);
    final gone = eraseAlong(x0: 100, y0: 100, x1: 100, y1: 100, radius: 6, mode: EraserMode.stroke);
    expect(gone.removedIds, hasLength(1));
    expect(getScene().strokes, hasLength(1));
  });

  test('select → transform → duplicate → cut → paste → delete', () {
    _drawPolyline(const [Offset(20, 20), Offset(120, 20)], autoCorrect: false);
    _drawPolyline(const [Offset(20, 400), Offset(120, 400)], autoCorrect: false);
    final ids = selectInRegion(rect: const ViewportRect(left: 0, top: 0, right: 200, bottom: 60));
    expect(ids, hasLength(1));

    final moved = transformSelection(scaleX: 2, scaleY: 2, dx: 30, dy: 30);
    expect(moved.upsertedStrokes, hasLength(1));
    expect(moved.selection.bounds!.left, greaterThan(40));

    final dup = duplicateSelection();
    expect(dup.upsertedStrokes, hasLength(1));
    expect(getScene().strokes, hasLength(3));

    final cut = cutSelection();
    expect(cut.removedIds, hasLength(1));
    expect(hasClipboard(), isTrue);

    final pasted = pasteClipboard(centerX: 600, centerY: 600);
    expect(pasted.upsertedStrokes, hasLength(1));
    expect(deleteSelection().removedIds, hasLength(1));
    expect(getScene().strokes, hasLength(2));
  });

  test('transforms never leave the page column', () {
    _drawPolyline(const [Offset(10, 10), Offset(80, 10)], autoCorrect: false);
    selectInRegion(rect: const ViewportRect(left: 0, top: 0, right: 100, bottom: 40));
    var d = transformSelection(scaleX: 1, scaleY: 1, dx: -500, dy: -500);
    expect(d.selection.bounds!.left, greaterThanOrEqualTo(-0.01));
    expect(d.selection.bounds!.top, greaterThanOrEqualTo(-0.01));
    d = transformSelection(scaleX: 1, scaleY: 1, dx: 5000, dy: 0);
    expect(d.selection.bounds!.right, lessThanOrEqualTo(1005));
  });

  test('sticky notes are hit-tested and selectable', () {
    final n = createStickyNote(x: 50, y: 50, width: 160, height: 120, color: 0xFFFFF59D, text: 'Salut ăîșț');
    expect(stickyNoteAt(x: 60, y: 60)?.id, n.id);
    expect(selectInLasso(polygon: [0, 0, 400, 0, 400, 400, 0, 400]), contains(n.id));
  });

  test('save / load round trip and PDF export for every paper style', () async {
    _drawPolyline(const [Offset(10, 10), Offset(200, 60)], autoCorrect: false);
    createStickyNote(x: 50, y: 200, width: 160, height: 120, color: 0xFFFFF59D, text: 'Notă');
    final dir = await Directory.systemTemp.createTemp('easynotes_it');
    final path = '${dir.path}${Platform.pathSeparator}content.ezn';
    final report = await saveDocument(path: path);
    expect(report.byteSize, greaterThan(16));
    newDocument(kind: DocumentKind.whiteboard, paper: PaperStyle.whiteboard);
    final info = await loadDocument(path: path);
    expect(info.kind, DocumentKind.notebook);
    expect(getScene().notes.single.text, 'Notă');
    for (final style in [PaperStyle.dictando, PaperStyle.matematica, PaperStyle.whiteboard]) {
      setPaperStyle(style: style);
      final bytes = await exportToPdfBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    }
    await dir.delete(recursive: true);
  });

  testWidgets('app boots into the library', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_lib');
    await tester.pumpWidget(EasyNotesApp(library: LibraryService(dir)));
    await tester.pumpAndSettle();
    expect(find.text('EasyNotes'), findsOneWidget);
    expect(find.text('New'), findsWidgets);
    await dir.delete(recursive: true);
  });
}
