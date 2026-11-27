// End-to-end checks through the real FFI bridge. Run on a device / desktop with:
//   flutter test integration_test/engine_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/screens/editor_screen.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/src/canvas/note_canvas.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/open_notebooks.dart';
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
import 'package:flutter_app/widgets/draggable_toolbar.dart';
import 'package:flutter_app/widgets/editor_app_bar.dart';
import 'package:flutter_app/widgets/pinned_overlay.dart';
import 'package:flutter_app/widgets/split_view.dart';
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
  // Engine-level tests work on the scratch document (slot 0).
  setUp(() {
    activateDocument(slot: 0);
    newDocument(slot: 0, kind: DocumentKind.notebook, paper: PaperStyle.dictando);
  });

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

  test('recolouring the selection through the bridge is one undo step', () {
    final a = _drawPolyline(const [Offset(20, 20), Offset(120, 20)], autoCorrect: false)!;
    final b = _drawPolyline(const [Offset(20, 80), Offset(120, 80)], autoCorrect: false)!;
    final c = _drawPolyline(const [Offset(20, 400), Offset(120, 400)], autoCorrect: false)!;
    selectInRegion(rect: const ViewportRect(left: 0, top: 0, right: 200, bottom: 120));

    final delta = recolorSelection(color: 0xFFD32F2F);
    expect(delta.upsertedStrokes.map((s) => s.id), unorderedEquals([a.id, b.id]));
    expect(delta.upsertedStrokes.every((s) => s.color == 0xFFD32F2F), isTrue);
    expect(delta.selection.ids, unorderedEquals([a.id, b.id]), reason: 'the selection stays');
    final scene = getScene().strokes;
    expect(scene.map((s) => s.id), [a.id, b.id, c.id], reason: 'ids and z-order kept');
    expect(scene.map((s) => s.color), [0xFFD32F2F, 0xFFD32F2F, 0xFF1A1A1A]);

    undo();
    expect(getScene().strokes.map((s) => s.color), everyElement(0xFF1A1A1A), reason: 'one step undoes both');
    redo();
    expect(getScene().strokes.map((s) => s.color), [0xFFD32F2F, 0xFFD32F2F, 0xFF1A1A1A]);
    undo();
    undo();
    expect(getScene().strokes.map((s) => s.id), [a.id, b.id], reason: 'the step before was drawing c');
  });

  test('whiteboard page guides follow the content', () {
    expect(whiteboardPageGuides(), isEmpty, reason: 'notebooks have real pages');
    newDocument(slot: 0, kind: DocumentKind.whiteboard, paper: PaperStyle.whiteboard);
    _drawPolyline(const [Offset(0, 0), Offset(800, 0)], autoCorrect: false);
    expect(whiteboardPageGuides(), hasLength(1));
    _drawPolyline(const [Offset(0, 3000), Offset(800, 3000)], autoCorrect: false);
    final pages = whiteboardPageGuides();
    expect(pages.length, greaterThan(1));
    for (var i = 1; i < pages.length; i++) {
      expect(pages[i].top, closeTo(pages[i - 1].bottom, 0.01), reason: 'slices follow each other');
    }
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
    final report = await saveDocument(slot: 0, path: path);
    expect(report.byteSize, greaterThan(16));
    newDocument(slot: 0, kind: DocumentKind.whiteboard, paper: PaperStyle.whiteboard);
    final info = await loadDocument(slot: 0, path: path);
    expect(info.kind, DocumentKind.notebook);
    expect(getScene().notes.single.text, 'Notă');
    for (final style in [PaperStyle.dictando, PaperStyle.matematica, PaperStyle.whiteboard]) {
      setPaperStyle(style: style);
      final bytes = await exportToPdfBytes(slot: 0);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    }
    await dir.delete(recursive: true);
  });

  test('documents in other slots keep their content and history; async calls name their slot', () async {
    newDocument(slot: 101, kind: DocumentKind.notebook, paper: PaperStyle.dictando);
    newDocument(slot: 102, kind: DocumentKind.whiteboard, paper: PaperStyle.whiteboard);
    expect(openDocuments(), containsAll(<int>[101, 102]));
    expect(activateDocument(slot: 999), isFalse, reason: 'nothing is open in 999');
    expect(activateDocument(slot: 101), isTrue);
    _drawPolyline(const [Offset(20, 100), Offset(400, 100)], autoCorrect: false);
    _drawPolyline(const [Offset(20, 200), Offset(400, 200)], autoCorrect: false);

    expect(activateDocument(slot: 102), isTrue);
    expect(activeDocument(), 102);
    expect(documentInfo().kind, DocumentKind.whiteboard);
    expect(getScene().strokes, isEmpty);
    expect(canUndo(), isFalse);

    // The parked notebook is saved and exported while the whiteboard stays active.
    final dir = await Directory.systemTemp.createTemp('easynotes_slots');
    final path = '${dir.path}${Platform.pathSeparator}content.ezn';
    await saveDocument(slot: 101, path: path);
    expect(activeDocument(), 102);
    expect((await exportToPdfBytes(slot: 101)).length, greaterThan(100));

    activateDocument(slot: 101);
    expect(getScene().strokes, hasLength(2));
    expect(undo(), isNotNull, reason: 'history survived the switch');
    expect(getScene().strokes, hasLength(1));

    // Loading into a parked slot leaves the active document alone.
    await loadDocument(slot: 103, path: path);
    expect(activeDocument(), 101);
    activateDocument(slot: 103);
    expect(getScene().strokes, hasLength(2), reason: 'the file has both strokes');

    for (final slot in [101, 102, 103]) {
      closeDocument(slot: slot);
    }
    expect(openDocuments(), isEmpty);
    expect(activeDocument(), 0, reason: 'the scratch document takes over');
    await expectLater(saveDocument(slot: 101, path: path), throwsA(anything));
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
    final tabs = OpenNotebooks(library: lib, sync: sync)..open(entry);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEasyNotesTheme(),
        home: EditorScreen(tabs: tabs),
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
    tabs.dispose();
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('editor: undo / redo from the toolbar and the keyboard; both autosave', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_undo');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final entry = await lib.createNotebook(dir, 'Undo test', NotebookTemplate.ruled);
    final tabs = OpenNotebooks(library: lib, sync: sync)..open(entry);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEasyNotesTheme(),
        home: EditorScreen(tabs: tabs),
      ),
    );
    await tester.pumpAndSettle();
    final c = tester.widget<CanvasStatusBar>(find.byType(CanvasStatusBar)).controller;
    // Saves are what marks the Drive backup as pending (OpenNotebooks wires onSaved).
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
    tabs.dispose();
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('editor tabs: switch, Ctrl+Tab, separate histories, close; shapes stay ink by default', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_tabs');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final alpha = await lib.createNotebook(dir, 'Alpha', NotebookTemplate.ruled);
    final beta = await lib.createNotebook(dir, 'Beta', NotebookTemplate.whiteboard);
    final tabs = OpenNotebooks(library: lib, sync: sync);
    final a = tabs.open(alpha);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: EditorScreen(tabs: tabs)));
    await tester.pumpAndSettle();

    // Home replaces the back arrow; the status bar has no shape hint any more.
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.widgetWithText(NotebookTab, 'Alpha'), findsOneWidget);
    expect(find.textContaining('snap it into a rectangle'), findsNothing);

    // Shape auto-correct starts OFF: a hand-drawn box stays ink.
    expect(a.autoCorrect, isFalse);
    expect(find.byTooltip('Shape auto-correct: OFF'), findsOneWidget);
    _drawWith(a, const [Offset(100, 100), Offset(300, 104), Offset(297, 220), Offset(102, 216), Offset(101, 102)]);
    await tester.pump();
    expect(a.scene.strokes.single.render.kind, RenderKind.filledOutline);

    // "+" opens another notebook from the library in a new tab.
    await tester.tap(find.byTooltip('Open a notebook in a new tab'));
    await _until(tester, () => find.text('Recent notebooks').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget, reason: 'Alpha is marked as open');
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(tabs.length, 2);
    final b = tabs.active!;
    expect(b.title, 'Beta');
    expect(b.autoCorrect, isFalse);
    expect(find.byType(NotebookTab), findsNWidgets(2));
    _drawWith(b, const [Offset(50, 50), Offset(250, 90), Offset(320, 40)]);
    await tester.pump();
    expect(b.scene.strokeCount, 1);

    Future<void> keys(List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
      for (final m in modifiers) {
        await tester.sendKeyDownEvent(m);
      }
      await tester.sendKeyEvent(key);
      for (final m in modifiers.reversed) {
        await tester.sendKeyUpEvent(m);
      }
      await tester.pumpAndSettle();
    }

    // Ctrl+Tab back to Alpha: its content and history are untouched; undo stays per tab.
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.tab);
    expect(tabs.active, same(a));
    expect(tester.widget<CanvasStatusBar>(find.byType(CanvasStatusBar)).controller, same(a));
    expect(a.scene.strokeCount, 1);
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect(a.scene.strokeCount, 0);
    expect(b.scene.strokeCount, 1);
    await keys([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.tab);
    expect(tabs.active, same(b));
    expect(b.canUndo, isTrue);
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect(b.scene.strokeCount, 0);
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyY);
    expect(b.scene.strokeCount, 1);
    expect(a.scene.strokeCount, 0, reason: 'undo in Beta never touched Alpha');

    // Clicking a tab switches; the tab left behind is written to its own file.
    await tester.tap(find.widgetWithText(NotebookTab, 'Alpha'));
    await tester.pumpAndSettle();
    expect(tabs.active, same(a));
    await b.save();
    await loadDocument(slot: 900, path: beta.documentFile.path);
    activateDocument(slot: 900);
    expect(getScene().strokes, hasLength(1), reason: 'Beta saved its own stroke');
    closeDocument(slot: 900);
    // Alpha's next engine call points the engine back at Alpha.
    await keys([LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyY);
    expect(a.scene.strokeCount, 1);

    // × closes Beta: saved with a thumbnail, its document freed; Alpha stays.
    expect(openDocuments(), hasLength(2));
    await tester.tap(
      find.descendant(of: find.widgetWithText(NotebookTab, 'Beta'), matching: find.byTooltip('Close tab')),
    );
    await _until(tester, () => openDocuments().length == 1);
    await tester.pumpAndSettle();
    expect(tabs.length, 1);
    expect(tabs.active, same(a));
    expect(find.byType(NotebookTab), findsOneWidget);
    expect(await beta.thumbnailFile.exists(), isTrue);

    await tester.pumpWidget(const SizedBox());
    tabs.dispose();
    expect(openDocuments(), isEmpty);
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('home and editor: tabs stay open in the library; opening another notebook adds a tab', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_home_tabs');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    await lib.createNotebook(dir, 'One', NotebookTemplate.ruled);
    await lib.createNotebook(dir, 'Two', NotebookTemplate.grid);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: HomeScreen(library: lib, sync: sync)));
    await tester.pumpAndSettle();
    expect(find.textContaining('open tab'), findsNothing);

    EditorController shown() => tester.widget<CanvasStatusBar>(find.byType(CanvasStatusBar)).controller;
    bool editorShown() => find.byType(EditorScreen).evaluate().isNotEmpty;

    await tester.tap(find.text('One'));
    await tester.pumpAndSettle();
    expect(editorShown(), isTrue);
    final one = shown();
    _drawWith(one, const [Offset(100, 200), Offset(300, 260), Offset(400, 210)]);
    await tester.pump();

    await tester.tap(find.byTooltip('Home'));
    await _until(tester, () => !editorShown());
    await tester.pumpAndSettle();
    expect(find.text('1 open tab'), findsOneWidget);
    expect(await one.entry.documentFile.exists(), isTrue, reason: 'Home saved the tab');

    // Opening another notebook from the library adds a second tab.
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(find.byType(NotebookTab), findsNWidgets(2));
    expect(shown().title, 'Two');
    await tester.tap(find.widgetWithText(NotebookTab, 'One'));
    await tester.pumpAndSettle();
    expect(shown(), same(one), reason: 'the first tab kept its controller');
    expect(one.scene.strokeCount, 1);
    expect(one.canUndo, isTrue, reason: 'and its undo history');

    // Back to the library and straight back to the tabs.
    await tester.tap(find.byTooltip('Home'));
    await _until(tester, () => !editorShown());
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 open tabs'));
    await tester.pumpAndSettle();
    expect(find.byType(NotebookTab), findsNWidgets(2));

    // Closing the last tab returns to the library.
    for (final name in ['Two', 'One']) {
      await tester.tap(
        find.descendant(of: find.widgetWithText(NotebookTab, name), matching: find.byTooltip('Close tab')),
      );
      await _until(tester, () => find.widgetWithText(NotebookTab, name).evaluate().isEmpty);
    }
    await _until(tester, () => !editorShown());
    await tester.pumpAndSettle();
    expect(find.textContaining('open tab'), findsNothing);
    expect(openDocuments(), isEmpty);

    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('split screen: one notebook twice with separate views, then two notebooks side by side', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_split');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final alpha = await lib.createNotebook(dir, 'Alpha', NotebookTemplate.ruled);
    final beta = await lib.createNotebook(dir, 'Beta', NotebookTemplate.grid);
    final tabs = OpenNotebooks(library: lib, sync: sync);
    final a = tabs.open(alpha);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: EditorScreen(tabs: tabs)));
    await tester.pumpAndSettle();
    _drawWith(a, const [Offset(100, 200), Offset(300, 260), Offset(400, 210)]);
    await tester.pump();
    expect(find.byType(PaneHeader), findsNothing);

    // Ctrl+\ splits: the same notebook on both sides, the new right pane focused.
    await _keys(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.backslash);
    expect((tabs.isSplit, tabs.active, tabs.split, tabs.focusedPane), (true, a, a, EditorPane.secondary));
    expect(find.byType(NoteCanvas), findsNWidgets(2));
    expect(find.byType(CanvasStatusBar), findsNWidgets(2));
    expect(find.byType(PaneHeader), findsNWidgets(2));
    expect(find.byTooltip('Close split view'), findsOneWidget, reason: 'only the right pane closes');
    Rect pane(int i) => tester.getRect(find.byType(NoteCanvas).at(i));
    expect((pane(0).width - pane(1).width).abs(), lessThan(2), reason: '50 / 50');
    expect(pane(1).left, greaterThan(pane(0).right));
    final left = a.viewport;
    final right = a.viewOf(EditorPane.secondary);
    expect(right, isNot(same(left)));
    expect(right.scale, closeTo(left.scale, 1e-6), reason: 'both fitted to the same pane width');

    // The wheel scrolls only the pane under the pointer.
    final leftTop = left.offset.dy;
    await _wheel(tester, pane(1).center, 300);
    expect(right.offset.dy, greaterThan(leftTop + 100));
    expect(left.offset.dy, leftTop);

    // Writing in the right pane writes into the one document (both panes show it);
    // Ctrl+Z undoes it there.
    await _penStroke(tester, pane(1).center, const Offset(120, 30));
    expect(a.scene.strokeCount, 2);
    await _keys(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect(a.scene.strokeCount, 1);

    // Scrolling to the end in one pane appends a page; the other pane can scroll to it.
    for (var i = 0; i < 30 && a.pages.length < 2; i++) {
      await _wheel(tester, pane(1).center, 400);
    }
    expect(a.pages.length, greaterThanOrEqualTo(2));
    expect(left.contentHeight, right.contentHeight);

    // Opening Beta fills the focused (right) pane: two notebooks side by side.
    final b = tabs.open(beta);
    await _until(tester, () => b.isOpen);
    await tester.pumpAndSettle();
    expect((tabs.active, tabs.split, tabs.focused), (a, b, b));
    expect(find.widgetWithText(PaneHeader, 'Beta'), findsOneWidget);
    await _penStroke(tester, pane(1).center, const Offset(-140, 40));
    expect((a.scene.strokeCount, b.scene.strokeCount), (1, 1));

    // Touching the left pane's header focuses it: the shortcuts follow.
    await tester.tap(find.widgetWithText(PaneHeader, 'Alpha'));
    await tester.pumpAndSettle();
    expect(tabs.focused, same(a));
    await _keys(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyZ);
    expect((a.scene.strokeCount, b.scene.strokeCount), (0, 1), reason: 'undo stayed in the left notebook');
    await _keys(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyY);
    expect((a.scene.strokeCount, b.scene.strokeCount), (1, 1));
    expect(b.canUndo, isTrue);

    // Each notebook was written to its own file.
    await a.save();
    await b.save();
    for (final (slot, entry) in [(900, alpha), (901, beta)]) {
      await loadDocument(slot: slot, path: entry.documentFile.path);
      activateDocument(slot: slot);
      expect(getScene().strokes, hasLength(1), reason: '${entry.name} saved its own stroke');
      closeDocument(slot: slot);
    }

    // × closes the right pane; Beta stays open as a tab.
    await tester.tap(find.byTooltip('Close split view'));
    await tester.pumpAndSettle();
    expect((tabs.isSplit, tabs.active, tabs.length), (false, a, 2));
    expect(find.byType(NoteCanvas), findsOneWidget);

    // A tab's context menu: "Split right" puts it next to the current notebook.
    await tester.tap(find.widgetWithText(NotebookTab, 'Beta'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split right'));
    await tester.pumpAndSettle();
    expect((tabs.active, tabs.split), (a, b));
    expect(find.byType(NoteCanvas), findsNWidgets(2));
    await _keys(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.backslash);
    expect(tabs.isSplit, isFalse);

    await tester.pumpWidget(const SizedBox());
    tabs.dispose();
    expect(openDocuments(), isEmpty);
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('pin to screen: the selection floats over the canvas and is never part of the notebook', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_pin');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final alpha = await lib.createNotebook(dir, 'Alpha', NotebookTemplate.ruled);
    final beta = await lib.createNotebook(dir, 'Beta', NotebookTemplate.ruled);
    final tabs = OpenNotebooks(library: lib, sync: sync);
    final a = tabs.open(alpha);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: EditorScreen(tabs: tabs)));
    await tester.pumpAndSettle();
    _drawWith(a, const [Offset(100, 200), Offset(300, 260), Offset(400, 210)]);
    var saves = 0;
    final markPending = a.onSaved;
    a.onSaved = () {
      saves++;
      markPending?.call();
    };
    await a.save();
    expect(saves, 1);
    final before = await a.exportPdf('${dir.path}${Platform.pathSeparator}before.pdf');

    a.selectBox(const Rect.fromLTRB(50, 150, 450, 300));
    await tester.pumpAndSettle();
    const pinTooltip = 'Pin to screen (stays in view while you scroll)';
    expect(find.byTooltip(pinTooltip), findsOneWidget, reason: 'next to Copy, Cut, Duplicate and Delete');
    await tester.tap(find.byTooltip(pinTooltip));
    await _until(tester, () => tabs.pins.length == 1);
    await tester.pumpAndSettle();
    expect(find.byType(PinnedOverlayBox), findsOneWidget);
    expect(find.text('Alpha · page 1'), findsOneWidget);
    expect(a.hasSelection, isFalse);
    final box = tabs.pins.boxes.single;
    final card = tester.getRect(find.byType(PinnedOverlayBox));
    expect(box.image.width, greaterThan(card.width * 2), reason: 'rendered at high resolution');

    // The notebook did not change: nothing to save, and the PDF export is identical.
    await a.save();
    expect(saves, 1);
    final after = await a.exportPdf('${dir.path}${Platform.pathSeparator}after.pdf');
    expect(after.pageCount, before.pageCount);
    expect(await File(after.path).readAsBytes(), await File(before.path).readAsBytes());
    expect(a.scene.strokeCount, 1);

    // It stays put on screen while the page scrolls and when another tab is shown.
    final canvas = tester.getRect(find.byType(NoteCanvas));
    final top = a.viewport.offset.dy;
    await _wheel(tester, canvas.center + const Offset(-200, 100), 250);
    expect(a.viewport.offset.dy, greaterThan(top));
    expect(tester.getRect(find.byType(PinnedOverlayBox)), card);
    final b = tabs.open(beta);
    await _until(tester, () => b.isOpen);
    await tester.pumpAndSettle();
    expect(tabs.active, same(b));
    expect(tester.getRect(find.byType(PinnedOverlayBox)), card);
    tabs.activate(0);
    await tester.pumpAndSettle();

    // A second pin cascades below the first; 75 % opacity; × unpins.
    a.selectBox(const Rect.fromLTRB(50, 150, 450, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(pinTooltip));
    await _until(tester, () => tabs.pins.length == 2);
    await tester.pumpAndSettle();
    expect(find.byType(PinnedOverlayBox), findsNWidgets(2));
    await tester.tap(find.byTooltip('Make see-through (75 %)').last);
    await tester.pump();
    expect(tabs.pins.boxes.last.seeThrough, isTrue);
    await tester.tap(find.byTooltip('Unpin').first);
    await tester.pumpAndSettle();
    expect(tabs.pins.length, 1);

    await tester.pumpWidget(const SizedBox());
    tabs.dispose();
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('the toolbar appears when a tab opened in the visible editor finishes loading', (tester) async {
    final dir = await Directory.systemTemp.createTemp('easynotes_toolbar');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final first = await lib.createNotebook(dir, 'First', NotebookTemplate.grid);
    final late = await lib.createNotebook(dir, 'Late', NotebookTemplate.ruled);
    final tabs = OpenNotebooks(library: lib, sync: sync);
    final a = tabs.open(first);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: EditorScreen(tabs: tabs)));
    await _until(tester, () => a.isOpen);
    await tester.pumpAndSettle();
    const grip = 'Drag to move the toolbar';
    expect(find.byTooltip(grip), findsOneWidget);

    // Give the second notebook enough ink that loading it takes a moment.
    final filler = tabs.open(late);
    await _until(tester, () => filler.isOpen);
    for (var i = 0; i < 300; i++) {
      _drawWith(filler, [Offset(60, 40.0 + i * 3), Offset(500, 44.0 + i * 3), Offset(940, 40.0 + i * 3)]);
    }
    await tabs.close(filler);
    await tester.pumpAndSettle();

    // The editor rebuilds for the new tab right away and the notebook finishes loading
    // later: then only the notebook notifies, and the toolbar must still appear.
    var checked = false;
    for (var attempt = 0; attempt < 5 && !checked; attempt++) {
      final b = tabs.open(late);
      await tester.pump();
      checked = !b.isOpen;
      await _until(tester, () => b.isOpen);
      await tester.pumpAndSettle();
      expect(find.byTooltip(grip), findsOneWidget);
      expect(tester.widget<DraggableToolbar>(find.byType(DraggableToolbar)).controller, same(b));
      await tabs.close(b);
      await tester.pumpAndSettle();
    }
    expect(checked, isTrue, reason: 'the notebook always loaded before the editor rebuilt');

    await tester.pumpWidget(const SizedBox());
    tabs.dispose();
    sync.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('phone portrait (384 dp, Android): the editor top bar fits and keeps room for the tabs', (tester) async {
    // A Galaxy S24 Ultra at its default display zoom; Android's 48 dp touch targets.
    tester.view
      ..physicalSize = const Size(1440, 3120)
      ..devicePixelRatio = 3.75;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.reset();
    });

    final dir = await Directory.systemTemp.createTemp('easynotes_phone');
    final lib = LibraryService(dir);
    final sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    final tabs = OpenNotebooks(library: lib, sync: sync);
    final ruled = tabs.open(await lib.createNotebook(dir, 'Lecture notes', NotebookTemplate.ruled));

    // Layout errors (a RenderFlex overflow) are collected, then asserted on.
    final errors = <String>[];
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.toString());
    try {
      await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: EditorScreen(tabs: tabs)));
      await _until(tester, () => ruled.isOpen);
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = reportError;
    }
    expect(errors, isEmpty);
    expect(tester.getSize(find.byType(NotebookTab)).width, greaterThanOrEqualTo(100), reason: 'the tab stays readable');

    // The actions that left the bar are in "More", and they still work.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Export PDF'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, 'Grid'));
    await tester.pumpAndSettle();
    expect(ruled.paperStyle, PaperStyle.matematica);

    await tester.pumpWidget(const SizedBox());
    tabs.dispose();
    sync.dispose();
    await dir.delete(recursive: true);
  });
}

/// Presses [key] with [modifiers] held.
Future<void> _keys(WidgetTester tester, List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
  for (final m in modifiers) {
    await tester.sendKeyDownEvent(m);
  }
  await tester.sendKeyEvent(key);
  for (final m in modifiers.reversed) {
    await tester.sendKeyUpEvent(m);
  }
  await tester.pumpAndSettle();
}

/// One mouse-wheel notch of [dy] pixels at [at].
Future<void> _wheel(WidgetTester tester, Offset at, double dy) async {
  final mouse = TestPointer(77, PointerDeviceKind.mouse)..hover(at);
  await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
  await tester.pump();
}

/// A stylus stroke from [from] by [by], as on a tablet.
Future<void> _penStroke(WidgetTester tester, Offset from, Offset by) async {
  final pen = await tester.startGesture(from, kind: PointerDeviceKind.stylus);
  for (var i = 1; i <= 12; i++) {
    await pen.moveTo(from + by * (i / 12) + Offset(0, math.sin(i.toDouble()) * 6));
    await tester.pump();
  }
  await pen.up();
  await tester.pumpAndSettle();
}

/// Draws a pen stroke through [path] with the controller (as the canvas does).
void _drawWith(EditorController c, List<Offset> path) {
  c.beginStroke(EditorTool.pen, path.first, 0.5);
  for (var i = 0; i + 1 < path.length; i++) {
    for (var k = 1; k <= 20; k++) {
      c.addPoint(Offset.lerp(path[i], path[i + 1], k / 20)!, 0.5);
    }
  }
  c.finishStroke(EditorTool.pen);
}

/// Pumps real-time frames until [done] (saves and file I/O run on real threads here).
Future<void> _until(WidgetTester tester, bool Function() done, {int tries = 200}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(done(), isTrue, reason: 'condition not reached in time');
}
