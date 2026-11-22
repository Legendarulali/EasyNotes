import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Viewport;
import 'package:flutter_app/src/canvas/note_canvas.dart';
import 'package:flutter_app/src/canvas/viewport.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/open_notebooks.dart';
import 'package:flutter_app/src/editor/tools.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_app/widgets/canvas_status_bar.dart';
import 'package:flutter_app/widgets/editor_app_bar.dart';
import 'package:flutter_app/widgets/split_view.dart';
import 'package:flutter_test/flutter_test.dart';

// These run without the Rust engine: opening a notebook fails (no native library in unit
// tests), which leaves the tab / pane bookkeeping, the views and the input routing to test.
// integration_test/engine_test.dart covers the split screen with the real engine.

/// Waits until [c] finished (or failed) loading.
Future<void> _settled(EditorController c) async {
  for (var i = 0; i < 400 && !c.isOpen && c.openError == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late LibraryService lib;
  late SyncService sync;
  late OpenNotebooks tabs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easynotes_split');
    lib = LibraryService(tmp);
    sync = SyncService(library: lib, auth: GoogleAuth.forPlatform());
    tabs = OpenNotebooks(library: lib, sync: sync);
  });

  tearDown(() async {
    tabs.dispose();
    sync.dispose();
    await tmp.delete(recursive: true);
  });

  Future<EditorController> open(String name) async {
    final entry = await lib.createNotebook(tmp, name, NotebookTemplate.ruled);
    final c = tabs.open(entry);
    await _settled(c);
    return c;
  }

  group('Split screen bookkeeping', () {
    test('split shows the notebook twice and focuses the right pane; tabs then fill the focused pane', () async {
      final a = await open('Alpha');
      final b = await open('Beta');
      tabs.activate(0);
      expect((tabs.isSplit, tabs.focused, tabs.focusedPane), (false, a, EditorPane.primary));

      tabs.splitRight();
      expect(tabs.active, same(a));
      expect(tabs.split, same(a), reason: 'the same notebook in both panes');
      expect(tabs.focusedPane, EditorPane.secondary);
      expect(a.viewOf(EditorPane.secondary), isNot(same(a.viewport)), reason: 'one view per pane');

      // Picking a tab shows it in the focused pane only.
      tabs.activate(1);
      expect((tabs.active, tabs.split, tabs.focused), (a, b, b));

      // The left pane takes over once it is touched.
      tabs.focusPane(EditorPane.primary);
      expect(tabs.focused, same(a));
      final c = await open('Gamma');
      expect(tabs.tabs, [a, c, b], reason: 'a new tab opens next to the focused one');
      expect((tabs.active, tabs.split), (c, b));
      expect(tabs.isShown(a), isFalse);

      // Ctrl+Tab cycles the focused pane's notebook.
      tabs.cycle(1);
      expect((tabs.active, tabs.split), (b, b));
      tabs.cycle(-1);
      expect(tabs.active, same(c));

      // Focusing the right pane of a single-pane editor does nothing.
      tabs.closeSplit();
      tabs.focusPane(EditorPane.secondary);
      expect((tabs.isSplit, tabs.focusedPane, tabs.focused), (false, EditorPane.primary, c));
    });

    test('closing tabs keeps two different notebooks on screen, or falls back to one pane', () async {
      final a = await open('Alpha');
      final b = await open('Beta');
      final c = await open('Gamma');
      tabs
        ..activate(0)
        ..splitRight(b);
      expect((tabs.active, tabs.split, tabs.focused), (a, b, b));

      // Closing the left notebook: its neighbour (Beta) is already on the right, so Gamma.
      await tabs.close(a);
      expect(tabs.tabs, [b, c]);
      expect((tabs.active, tabs.split), (c, b));

      // Only Beta left: one pane again.
      await tabs.close(c);
      expect((tabs.active, tabs.split, tabs.isSplit), (b, null, false));

      // Closing the right pane's notebook closes the split.
      final d = await open('Delta');
      tabs
        ..activate(0)
        ..splitRight(d);
      await tabs.close(d);
      expect((tabs.active, tabs.isSplit, tabs.focusedPane), (b, false, EditorPane.primary));
    });

    test('deleting a notebook from the library closes the pane that showed it', () async {
      final a = await open('Alpha');
      final b = await open('Beta');
      tabs
        ..activate(0)
        ..splitRight(b);
      tabs.discard(b.entry);
      expect(tabs.tabs, [a]);
      expect((tabs.active, tabs.isSplit), (a, false));
    });

    test('the divider ratio stays within bounds', () {
      expect(tabs.splitRatio, 0.5);
      tabs.setSplitRatio(0.05);
      expect(tabs.splitRatio, OpenNotebooks.minSplitRatio);
      tabs.setSplitRatio(0.97);
      expect(tabs.splitRatio, 1 - OpenNotebooks.minSplitRatio);
    });

    test('each pane scrolls and zooms on its own; a second view starts where the first is', () async {
      final a = await open('Alpha');
      final left = a.viewport
        ..setViewportSize(const Size(900, 700))
        ..setContentExtent(width: 1000, height: 3000)
        ..panBy(const Offset(0, -500));
      final top = left.offset.dy;
      expect(top, greaterThan(400));

      tabs.splitRight();
      final right = a.viewOf(EditorPane.secondary);
      expect(right.offset.dy, closeTo(top, 0.5), reason: 'same page as the left pane');
      expect(right.contentHeight, 3000);
      // Both panes are fitted to their new width once laid out, each keeping its page.
      expect(left.takePendingFit()?.top, closeTo(top, 0.5));
      expect(right.takePendingFit()?.top, closeTo(top, 0.5));

      right
        ..setViewportSize(const Size(450, 700))
        ..panBy(const Offset(0, -1200))
        ..zoomAt(Offset.zero, 2);
      expect(left.offset.dy, closeTo(top, 0.5), reason: 'scrolling the right pane left the left one alone');
      expect(left.scale, 1);
      expect(right.scale, 2);
      expect(right.offset.dy, greaterThan(top + 1000));
    });
  });

  group('Viewport', () {
    test('fitPageWidth can keep the page that is on screen', () {
      final v = Viewport(insets: const EdgeInsets.only(top: 80))
        ..setViewportSize(const Size(532, 800))
        ..setContentExtent(width: 1000, height: 5000)
        ..fitPageWidth(top: 2300);
      expect(v.scale, closeTo(0.5, 1e-9), reason: '(532 - 2 × 16 margin) / 1000');
      expect(v.offset.dy, closeTo(2300, 1e-6), reason: 'world Y 2300 at the top of the free area');
      v.fitPageWidth();
      expect(v.offset.dy, closeTo(0, 1e-6));
    });

    test('showSameAs copies zoom and position across different insets', () {
      final a = Viewport(insets: const EdgeInsets.only(top: 80))
        ..setViewportSize(const Size(800, 600))
        ..zoomAt(Offset.zero, 1.5)
        ..panBy(const Offset(0, -300));
      final b = Viewport()..showSameAs(a);
      expect(b.scale, 1.5);
      expect(b.offset.dy, closeTo(a.offset.dy, 1e-6));
      expect(b.takePendingFit(), isNull, reason: 'no fit was asked for');
    });
  });

  group('Two panes, one notebook', () {
    testWidgets('a palm on the other pane is ignored while the pen writes; each pane has its own view', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final a = await tester.runAsync(() => open('Alpha'));
      tabs.splitRight();
      final gate = CanvasInputGate();
      final focusLog = <EditorPane>[];
      Widget pane(EditorPane p) => SizedBox(
        width: 400,
        height: 600,
        child: NoteCanvas(
          controller: a!,
          pane: p,
          gate: gate,
          onFocus: () => focusLog.add(p),
          onEditNote: (_, {isNew = false}) async {},
          onMessage: (_) {},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Row(children: [pane(EditorPane.primary), pane(EditorPane.secondary)]),
        ),
      );

      // The pen writes on the left while the palm lands on the right.
      final pen = await tester.startGesture(const Offset(200, 300), kind: PointerDeviceKind.stylus, pointer: 1);
      await pen.moveBy(const Offset(40, 10));
      final palm = await tester.startGesture(const Offset(600, 300), kind: PointerDeviceKind.touch, pointer: 2);
      await palm.moveBy(const Offset(0, -120));
      expect(focusLog, [EditorPane.primary], reason: 'the palm neither focused nor moved the right pane');
      expect(a!.viewOf(EditorPane.secondary).offset.dy, closeTo(0, 1e-6));
      await palm.up();
      await pen.up();
      await tester.pump();

      // Pen up: the right pane responds again (stylus seen, so a finger scrolls).
      final finger = await tester.startGesture(const Offset(600, 300), kind: PointerDeviceKind.touch, pointer: 3);
      await finger.moveBy(const Offset(0, -150));
      await finger.up();
      expect(focusLog, [EditorPane.primary, EditorPane.secondary]);
      final rightY = a.viewOf(EditorPane.secondary).offset.dy;
      expect(rightY, greaterThan(100));
      expect(a.viewport.offset.dy, closeTo(0, 1e-6), reason: 'the left view did not move');

      // The mouse wheel scrolls the pane under the pointer only.
      final wheel = TestPointer(9, PointerDeviceKind.mouse)..hover(const Offset(200, 300));
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 240)));
      await tester.pump();
      expect(a.viewport.offset.dy, greaterThan(100));
      expect(a.viewOf(EditorPane.secondary).offset.dy, rightY);

      // The eraser cursor follows the pointer into the pane it is over.
      a.selectTool(EditorTool.eraser);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(150, 150));
      await mouse.moveTo(const Offset(160, 150));
      expect(a.live.eraserView, same(a.viewport));
      await mouse.moveTo(const Offset(650, 150));
      expect(a.live.eraserView, same(a.viewOf(EditorPane.secondary)));
      await mouse.removePointer();
    });
  });

  group('Split screen widgets', () {
    late EditorController c;

    setUp(() async {
      final entry = await lib.createNotebook(tmp, 'Lecture 4', NotebookTemplate.grid);
      c = EditorController(entry: entry, library: lib);
    });

    tearDown(() => c.dispose());

    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    );

    testWidgets('pane header: title, focus on tap, × only where it closes the split', (tester) async {
      var focused = 0, closed = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 400,
            child: Column(
              children: [
                PaneHeader(controller: c, focused: false, onFocus: () => focused++),
                PaneHeader(controller: c, focused: true, onFocus: () => focused++, onClose: () => closed++),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Lecture 4'), findsNWidgets(2));
      expect(find.byTooltip('Close split view'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Focused pane: Lecture 4')), findsOneWidget);
      await tester.tap(find.text('Lecture 4').first);
      await tester.tap(find.byTooltip('Close split view'));
      expect((focused, closed), (1, 1));
    });

    testWidgets('divider: drag resizes, double-click resets', (tester) async {
      final moves = <double>[];
      var resets = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            height: 300,
            child: SplitDivider(onDrag: moves.add, onReset: () => resets++),
          ),
        ),
      );
      final grip = await tester.startGesture(tester.getCenter(find.byType(SplitDivider)));
      await grip.moveBy(const Offset(30, 0));
      await grip.moveBy(const Offset(60, 0));
      await grip.up();
      expect(moves.fold<double>(0, (a, b) => a + b), inInclusiveRange(60, 90));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SplitDivider));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(SplitDivider));
      await tester.pumpAndSettle();
      expect(resets, 1);
    });

    testWidgets('a tab dragged onto the right half splits right; onto the left half shows it there', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      EditorController? left, right;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              Draggable<EditorController>(
                data: c,
                affinity: Axis.vertical,
                feedback: const Text('dragging'),
                child: const SizedBox(width: 120, height: 40, child: Text('tab')),
              ),
              Expanded(
                child: TabDropZones(split: false, onDropLeft: (d) => left = d, onDropRight: (d) => right = d),
              ),
            ],
          ),
        ),
      );
      expect(find.text('Split right'), findsNothing, reason: 'the zones only show under a dragged tab');

      final drag = await tester.startGesture(tester.getCenter(find.text('tab')));
      await drag.moveBy(const Offset(0, 40));
      await drag.moveTo(const Offset(600, 300));
      await tester.pump();
      expect(find.text('Split right'), findsOneWidget);
      await drag.up();
      await tester.pump();
      expect((left, right), (null, c));

      final again = await tester.startGesture(tester.getCenter(find.text('tab')));
      await again.moveBy(const Offset(0, 40));
      await again.moveTo(const Offset(200, 300));
      await tester.pump();
      expect(find.text('Open here'), findsOneWidget);
      await again.up();
      await tester.pump();
      expect(left, same(c));
    });

    testWidgets('a tab shown in the other pane is marked; right click opens its menu', (tester) async {
      var menus = 0;
      await tester.pumpWidget(
        host(
          NotebookTab(
            controller: c,
            active: false,
            shownInOtherPane: true,
            onSelect: () {},
            onClose: () {},
            onContextMenu: () => menus++,
          ),
        ),
      );
      final material = tester.widget<Material>(
        find.descendant(of: find.byType(NotebookTab), matching: find.byType(Material)).first,
      );
      expect(material.color, isNot(Colors.transparent));
      await tester.tap(find.text('Lecture 4'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(menus, 1);
    });

    testWidgets('status bar: per pane, and a narrow pane drops the coordinates', (tester) async {
      Future<void> pumpAt(double width) => tester.pumpWidget(
        host(SizedBox(width: width, child: CanvasStatusBar(controller: c, pane: EditorPane.secondary))),
      );
      c.viewOf(EditorPane.secondary).zoomAt(Offset.zero, 1.5);
      await pumpAt(900);
      expect(find.text('150%'), findsOneWidget, reason: 'the right pane’s own zoom');
      expect(find.textContaining('X 0'), findsOneWidget);
      await pumpAt(300);
      expect(find.text('150%'), findsOneWidget);
      expect(find.textContaining('X 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
