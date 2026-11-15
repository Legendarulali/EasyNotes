// End-to-end checks through the real FFI bridge. Run on a device / desktop with:
//   flutter test integration_test/engine_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/screens/editor_screen.dart';
import 'package:flutter_app/src/canvas/note_canvas.dart';
import 'package:flutter_app/src/editor/tools.dart';
import 'package:flutter_app/src/rust/api/stroke_api.dart';
import 'package:flutter_app/src/rust/document/eraser.dart';
import 'package:flutter_app/src/rust/document/page.dart';
import 'package:flutter_app/src/rust/document/paper.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:flutter_app/src/rust/geometry/point.dart';
import 'package:flutter_app/src/rust/geometry/shape_detector.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_app/widgets/canvas_status_bar.dart';
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

/// Samples along the polyline through [path] (20 per segment).
List<StrokePoint> _samples(List<Offset> path) => [
  for (var i = 0; i + 1 < path.length; i++)
    for (var k = 0; k < 20; k++) _point(Offset.lerp(path[i], path[i + 1], k / 20)!),
  _point(path.last),
];

StrokePoint _point(Offset p) => StrokePoint(x: p.dx, y: p.dy, pressure: 0.5);

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

  test('lines, circles, triangles and stars snap on pen-up', () {
    final line = _drawPolyline(const [Offset(100, 300), Offset(500, 306)])!;
    expect(line.kind, RenderKind.openPolyline);
    expect(line.geometry, hasLength(4));
    expect(line.geometry[1], line.geometry[3], reason: 'levelled');

    List<Offset> circle(Offset c, double r) => [
      for (var i = 0; i <= 64; i++) c + Offset.fromDirection(2 * math.pi * i / 64, r),
    ];
    final round = _drawPolyline(circle(const Offset(300, 600), 90), steps: 3)!;
    expect(round.kind, RenderKind.closedPolygon);
    expect(round.geometry.length, greaterThanOrEqualTo(64));

    final triangle = detectShape(
      points: _samples(const [Offset(100, 300), Offset(320, 306), Offset(180, 120), Offset(100, 300)]),
    );
    expect(triangle?.kind, ShapeClass.triangle);
    expect(triangle!.points, hasLength(4), reason: '3 corners + closing corner');
    final tips = [
      for (var i = 0; i < 5; i++)
        const Offset(400, 400) + Offset.fromDirection(-math.pi / 2 + 2 * math.pi * i / 5, 150),
    ];
    final star = detectShape(points: _samples([for (var i = 0; i <= 5; i++) tips[(2 * i) % 5]]));
    expect(star?.kind, ShapeClass.star);
    expect(detectShape(points: _samples(const [Offset(10, 10), Offset(200, 60), Offset(260, 30)])), isNull);
  });

  test('undo / redo through the bridge keep ids, z-order and the spatial index', () {
    expect(canUndo(), isFalse);
    expect(undo(), isNull);
    final a = _drawPolyline(const [Offset(20, 100), Offset(400, 100)], autoCorrect: false)!;
    final b = _drawPolyline(const [Offset(20, 200), Offset(400, 200)], autoCorrect: false)!;
    final r0 = documentRevision();

    // Erase `a` with one eraser drag (several calls, one undo step).
    beginHistoryGroup();
    eraseAlong(x0: 100, y0: 60, x1: 100, y1: 100, radius: 6, mode: EraserMode.partial);
    eraseAlong(x0: 100, y0: 100, x1: 300, y1: 140, radius: 6, mode: EraserMode.partial);
    endHistoryGroup();
    expect(getScene().strokes.length, greaterThan(2));

    final restored = undo()!;
    expect(documentRevision(), isNot(r0));
    expect(getScene().strokes.map((s) => s.id), [a.id, b.id], reason: 'a is back below b');
    expect(restored.upsertedStrokes.map((s) => s.id), contains(a.id));
    expect(selectAt(x: 50, y: 100, tolerance: 4), [a.id], reason: 'hit-testing finds it again');
    expect(canRedo(), isTrue);

    redo();
    expect(getScene().strokes.length, greaterThan(2));
    undo();
    undo(); // b
    expect(getScene().strokes.map((s) => s.id), [a.id]);
    // A new edit drops the redo history.
    _drawPolyline(const [Offset(20, 300), Offset(400, 300)], autoCorrect: false);
    expect(canRedo(), isFalse);

    // Selection edits and notes.
    final n = createStickyNote(x: 500, y: 500, width: 160, height: 120, color: 0xFFFFF59D, text: 'x');
    selectInRegion(rect: const ViewportRect(left: 0, top: 0, right: 1000, bottom: 1000));
    transformSelection(scaleX: 1, scaleY: 1, dx: 40, dy: 40);
    deleteSelection();
    expect(getScene().strokes, isEmpty);
    undo();
    undo();
    expect(getScene().notes.single.x, n.x);
    resetDocument();
    expect(getScene().strokes, isEmpty);
    undo();
    expect(getScene().strokes, hasLength(2), reason: 'clearing is undoable');
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

  test('near-end append (scroll / pen) and trimming of unused trailing pages', () {
    expect(appendPageIfNearEnd(y: 940, margin: 50), isNull);
    final p2 = appendPageIfNearEnd(y: 955, margin: 50)!;
    expect((p2.index, p2.top), (1, 1000));
    appendPageIfNearEnd(y: 1990, margin: 50);
    expect(pageCount(), 3);
    _drawPolyline(const [Offset(100, 1100), Offset(300, 1150)], autoCorrect: false);
    expect(trimTrailingBlankPages(), 1);
    expect(pageCount(), 2);
    expect(maxPageCount(), greaterThanOrEqualTo(1000));
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

  testWidgets('app boots into the library with the Google account button top-right', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_lib');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    await sync.start(); // no OAuth ids compiled into tests → "not set up"
    await tester.pumpWidget(EasyNotesApp(library: lib, sync: sync));
    await tester.pumpAndSettle();
    expect(find.text('EasyNotes'), findsOneWidget);
    expect(find.text('New'), findsWidgets);
    final signIn = find.text('Sign in with Google');
    expect(signIn, findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold).first);
    final button = tester.getRect(signIn);
    expect(button.right, greaterThan(screen.width - 200), reason: 'account control sits in the top-right corner');
    expect(button.top, lessThan(80));
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('editor: page 1 starts below the top toolbar; touch scrolling appends pages', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_editor');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final entry = await lib.createNotebook(dir, 'Scroll test', NotebookTemplate.ruled);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEasyNotesTheme(),
        home: EditorScreen(entry: entry, library: lib, sync: sync),
      ),
    );
    await tester.pumpAndSettle();

    final bar = tester.widget<CanvasStatusBar>(find.byType(CanvasStatusBar));
    final c = bar.controller;
    expect(c.isOpen, isTrue);
    expect(c.pages, hasLength(1));
    expect(find.text('Page 1 / 1'), findsOneWidget);

    // Bug A: the toolbar is docked at the top by default; the top edge of page 1 must be
    // visible below it, not hidden behind it.
    final canvas = tester.getRect(find.byType(NoteCanvas));
    final toolbarBottom = tester.getRect(find.byTooltip('Collapse toolbar')).bottom;
    final pageTop = canvas.top + c.viewport.worldToScreen(Offset.zero).dy;
    expect(pageTop, greaterThan(toolbarBottom), reason: 'page 1 starts below the toolbar');
    expect(c.viewport.offset.dy, 0, reason: 'status bar Y is 0 at the top of page 1');
    expect(find.textContaining('Y 0'), findsOneWidget);

    // Bug B: a two-finger touch drag (the gesture that never appended before) scrolls
    // down; reaching the bottom of page 1 appends page 2 beneath it.
    Future<void> twoFingerDrag(double dy) async {
      final center = canvas.center;
      final a = await tester.startGesture(center - const Offset(40, 0), pointer: 11, kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(center + const Offset(40, 0), pointer: 12, kind: PointerDeviceKind.touch);
      for (var i = 0; i < 10; i++) {
        await a.moveBy(Offset(0, dy / 10));
        await b.moveBy(Offset(0, dy / 10));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
    }

    for (var i = 0; i < 12 && c.pages.length < 2; i++) {
      await twoFingerDrag(-200);
    }
    expect(c.pages.length, greaterThanOrEqualTo(2), reason: 'scrolling down appended page 2');
    expect(c.pages[1].top, 1000);
    // Keep scrolling into page 2: the status bar follows the page boundary.
    for (var i = 0; i < 20 && c.pageIndexAt(c.viewport.offset.dy + 100) != 1; i++) {
      await twoFingerDrag(-150);
    }
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'Page 2 / \d')), findsOneWidget);
    expect(c.viewport.offset.dy, greaterThanOrEqualTo(900));
    // The scroll gesture did not draw anything (two fingers navigate).
    expect(c.scene.strokeCount, 0);

    // Closing drops the blank pages that were only created by scrolling.
    await c.close();
    expect(c.pages, hasLength(1));
    final meta = await lib.readNotebook(entry.dir);
    expect(meta.meta.pageCount, 1);

    // Writing into the last 50 units of the last page opens the next page under the pen.
    c.beginStroke(EditorTool.pen, const Offset(200, 880), 0.5);
    c.addPoint(const Offset(200, 940), 0.5);
    expect(c.pages, hasLength(1));
    c.addPoint(const Offset(200, 965), 0.5);
    expect(c.pages, hasLength(2));
    c.finishStroke(EditorTool.pen);
    await tester.pump();
    expect(find.text('Page 1 / 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('editor: undo / redo from the toolbar and the keyboard; both autosave', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_undo');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final entry = await lib.createNotebook(dir, 'Undo test', NotebookTemplate.ruled);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEasyNotesTheme(),
        home: EditorScreen(entry: entry, library: lib, sync: sync),
      ),
    );
    await tester.pumpAndSettle();
    final c = tester.widget<CanvasStatusBar>(find.byType(CanvasStatusBar)).controller;
    // Saves are what marks the Drive backup as pending (EditorScreen wires onSaved).
    var saves = 0;
    final markPending = c.onSaved;
    c.onSaved = () {
      saves++;
      markPending?.call();
    };
    InkWell chip(String tooltip) =>
        tester.widget<InkWell>(find.descendant(of: find.byTooltip(tooltip), matching: find.byType(InkWell)));
    Future<void> keys(List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
      for (final m in modifiers) {
        await tester.sendKeyDownEvent(m);
      }
      await tester.sendKeyEvent(key);
      for (final m in modifiers.reversed) {
        await tester.sendKeyUpEvent(m);
      }
      await tester.pump();
    }

    expect(chip('Undo (Ctrl+Z)').onTap, isNull);
    expect(chip('Redo (Ctrl+Y)').onTap, isNull);

    c.beginStroke(EditorTool.pen, const Offset(100, 200), 0.5);
    for (var i = 1; i <= 20; i++) {
      c.addPoint(Offset(100 + i * 10, 200 + math.sin(i.toDouble()) * 30), 0.5);
    }
    c.finishStroke(EditorTool.pen);
    await tester.pump();
    expect(c.scene.strokeCount, 1);
    expect(chip('Undo (Ctrl+Z)').onTap, isNotNull, reason: 'enabled once there is history');
    expect(chip('Redo (Ctrl+Y)').onTap, isNull);
    await c.save();
    expect(saves, 1);

    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect(c.scene.strokeCount, 0);
    expect(chip('Redo (Ctrl+Y)').onTap, isNotNull);
    expect(chip('Undo (Ctrl+Z)').onTap, isNull);
    await c.save();
    expect(saves, 2, reason: 'undo changed the document: saved and marked for backup');

    await keys([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyZ);
    expect(c.scene.strokeCount, 1);
    await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await tester.pump();
    expect(c.scene.strokeCount, 0);
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyY);
    expect(c.scene.strokeCount, 1);
    await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await tester.pump();
    await tester.tap(find.byTooltip('Redo (Ctrl+Y)'));
    await tester.pump();
    expect(c.scene.strokeCount, 1);
    await c.save();
    expect(saves, 3);

    // One eraser drag across the canvas is one undo step.
    c.selectTool(EditorTool.eraser);
    await tester.pump();
    final canvas = tester.getRect(find.byType(NoteCanvas));
    Offset screen(Offset world) => canvas.topLeft + c.viewport.worldToScreen(world);
    final drag = await tester.startGesture(screen(const Offset(150, 120)), kind: PointerDeviceKind.stylus);
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(screen(Offset(150 + i * 2.0, 120 + i * 18.0)));
    }
    await drag.up();
    await tester.pump();
    expect(c.scene.strokeCount, isNot(1), reason: 'the classic eraser cut the stroke');
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect(c.scene.strokeCount, 1);

    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    await dir.delete(recursive: true);
  });
}
