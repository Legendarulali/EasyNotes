import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_app/src/canvas/scene_cache.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/rust/document.dart';
import 'package:flutter_app/src/rust/geometry/point.dart';
import 'package:flutter_app/src/rust/geometry/sticky_note.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/widgets/draggable_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

StrokeRender _stroke(String id) => StrokeRender(
  id: id,
  tool: ToolType.pen,
  kind: RenderKind.openPolyline,
  color: 0xFF000000,
  opacity: 1,
  width: 2,
  geometry: Float32List.fromList([0, 0, 10, 10]),
  bounds: const ViewportRect(left: 0, top: 0, right: 10, bottom: 10),
);

StickyNote _note(String id) =>
    StickyNote(id: id, x: 0, y: 0, width: 100, height: 80, color: 0xFFFFF59D, text: '', fontSize: 16);

SceneDelta _delta({List<StrokeRender> strokes = const [], List<StickyNote> notes = const [], List<String> removed = const []}) =>
    SceneDelta(
      upsertedStrokes: strokes,
      upsertedNotes: notes,
      removedIds: removed,
      selection: const SelectionInfo(ids: []),
      pageCount: 1,
    );

void main() {
  group('SceneCache z-order', () {
    test('items restored by undo go back to their z-position', () {
      final scene = SceneCache()
        ..load(
          SceneSnapshot(
            strokes: [_stroke('s1'), _stroke('s2'), _stroke('s5')],
            notes: [_note('n3'), _note('n7')],
            selection: const SelectionInfo(ids: []),
          ),
        );
      // Deleting s2 and n3, then undoing the deletion.
      scene.applyDelta(_delta(removed: ['s2', 'n3']));
      expect(scene.strokes.map((s) => s.id), ['s1', 's5']);
      scene.applyDelta(_delta(strokes: [_stroke('s2')], notes: [_note('n3')]), restoreOrder: true);
      expect(scene.strokes.map((s) => s.id), ['s1', 's2', 's5']);
      expect(scene.notes.map((n) => n.id), ['n3', 'n7']);
    });

    test('ordinary edits keep the fast append / in-place update', () {
      final scene = SceneCache()..addStroke(_stroke('s4'));
      final cached = scene.stroke('s4');
      scene.applyDelta(_delta(strokes: [_stroke('s9'), _stroke('s4')]));
      expect(scene.strokes.map((s) => s.id), ['s4', 's9']);
      expect(identical(scene.stroke('s4'), cached), isFalse, reason: 'updated geometry is re-cached');
      expect(engineKey('s42'), 42);
      expect(engineKey('n7'), 7);
    });
  });

  group('Toolbar undo / redo', () {
    late Directory tmp;
    late EditorController controller;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('easynotes_undo_ui');
      final library = LibraryService(tmp);
      final entry = await library.createNotebook(tmp, 'Undo', NotebookTemplate.ruled);
      controller = EditorController(entry: entry, library: library);
    });

    tearDown(() async {
      controller.dispose();
      await tmp.delete(recursive: true);
    });

    InkWell chip(WidgetTester tester, String tooltip) =>
        tester.widget<InkWell>(find.descendant(of: find.byTooltip(tooltip), matching: find.byType(InkWell)));

    testWidgets('buttons sit next to the grip and are disabled without history', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(children: [DraggableToolbar(controller: controller, bounds: const Size(1400, 900))]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Undo (Ctrl+Z)'), findsOneWidget);
      expect(find.byTooltip('Redo (Ctrl+Y)'), findsOneWidget);
      expect(controller.canUndo, isFalse);
      expect(chip(tester, 'Undo (Ctrl+Z)').onTap, isNull);
      expect(chip(tester, 'Redo (Ctrl+Y)').onTap, isNull);
      // Undo / redo come before the tools.
      final undoX = tester.getCenter(find.byTooltip('Undo (Ctrl+Z)')).dx;
      final penX = tester.getCenter(find.byTooltip('Pen')).dx;
      expect(undoX, lessThan(penX));

      // Collapsed, the toolbar shows only the active tool.
      await tester.tap(find.byTooltip('Collapse toolbar'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Undo (Ctrl+Z)'), findsNothing);
    });
  });
}
