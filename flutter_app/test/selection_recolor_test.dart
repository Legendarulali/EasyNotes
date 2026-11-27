import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/tools.dart';
import 'package:flutter_app/src/rust/document.dart';
import 'package:flutter_app/src/rust/geometry/point.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/ui/selection_actions.dart';
import 'package:flutter_test/flutter_test.dart';

StrokeRender _stroke(String id, {ToolType tool = ToolType.pen, int color = 0xFF1A1A1A}) => StrokeRender(
  id: id,
  tool: tool,
  kind: RenderKind.openPolyline,
  color: color,
  opacity: 1,
  width: 4,
  geometry: Float32List.fromList([10, 20, 190, 20]),
  bounds: const ViewportRect(left: 8, top: 18, right: 192, bottom: 22),
);

String _hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

void main() {
  late Directory tmp;
  late EditorController c;

  Future<void> setUpController(WidgetTester tester, List<StrokeRender> strokes) async {
    tmp = (await tester.runAsync(() => Directory.systemTemp.createTemp('easynotes_recolor')))!;
    final library = LibraryService(tmp);
    final entry = (await tester.runAsync(() => library.createNotebook(tmp, 'Colours', NotebookTemplate.ruled)))!;
    c = EditorController(entry: entry, library: library);
    c.scene.load(SceneSnapshot(strokes: strokes, notes: const [], selection: const SelectionInfo(ids: [])));
  }

  Future<void> tearDownController(WidgetTester tester) async {
    c.dispose();
    await tester.runAsync(() => tmp.delete(recursive: true));
  }

  Widget bar() => MaterialApp(
    home: Scaffold(body: SelectionActionBar(controller: c, onEditNote: (_) {})),
  );

  testWidgets('selected ink gets a row of ink colours; the shared colour is marked', (tester) async {
    await setUpController(tester, [_stroke('s1'), _stroke('s2', color: 0xFF1A1A1A)]);
    c.debugSetSelection(['s1', 's2']);
    await tester.pumpWidget(bar());
    for (final color in kInkSwatches) {
      expect(find.byKey(ValueKey('recolor-${_hex(color)}')), findsOneWidget);
    }
    expect(tester.getSemantics(find.bySemanticsLabel('Recolour selection #1A1A1A')), isSemantics(isSelected: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Recolour selection #D32F2F')), isSemantics(isSelected: false));
    expect(SelectionActionBar.heightFor(c), greaterThan(SelectionActionBar.height));
    // Without a running engine the tap does nothing, but it must not throw.
    await tester.tap(find.byKey(ValueKey('recolor-${_hex(kInkSwatches[2])}')));
    await tester.pump();
    await tearDownController(tester);
  });

  testWidgets('selected highlighter strokes get the highlighter colours', (tester) async {
    await setUpController(tester, [_stroke('h1', tool: ToolType.highlighter, color: 0xFFFFEB3B)]);
    c.debugSetSelection(['h1']);
    await tester.pumpWidget(bar());
    expect(SelectionActionBar.swatchesFor(c.selectedStrokes), kHighlighterSwatches);
    for (final color in kHighlighterSwatches) {
      expect(find.byKey(ValueKey('recolor-${_hex(color)}')), findsOneWidget);
    }
    await tearDownController(tester);
  });

  testWidgets('a selection of only sticky notes shows no colour row', (tester) async {
    await setUpController(tester, [_stroke('s1')]);
    c.debugSetSelection(['n1']);
    await tester.pumpWidget(bar());
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('recolor-')), findsNothing);
    expect(SelectionActionBar.heightFor(c), SelectionActionBar.height);
    await tearDownController(tester);
  });
}
