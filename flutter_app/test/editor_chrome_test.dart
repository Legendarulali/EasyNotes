import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/tools.dart';
import 'package:flutter_app/src/rust/document/eraser.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/widgets/canvas_status_bar.dart';
import 'package:flutter_app/widgets/editor_app_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late EditorController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easynotes_chrome');
    final library = LibraryService(tmp);
    final entry = await library.createNotebook(tmp, 'Lecture 4', NotebookTemplate.grid);
    controller = EditorController(entry: entry, library: library);
  });

  tearDown(() async {
    controller.dispose();
    await tmp.delete(recursive: true);
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
  );

  test('shape auto-correct is off until the user turns it on', () {
    expect(controller.autoCorrect, isFalse);
    controller.setAutoCorrect(true);
    expect(controller.autoCorrect, isTrue);
  });

  testWidgets('the status bar shows no tool hints, whatever the tool', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(SizedBox(width: 1200, child: CanvasStatusBar(controller: controller))));
    for (final tool in EditorTool.values) {
      controller.selectTool(tool);
      for (final mode in EraserMode.values) {
        controller.setEraserMode(mode);
        await tester.pump();
        expect(find.textContaining('snap'), findsNothing);
        expect(find.textContaining('Drag to select'), findsNothing);
        expect(find.textContaining('Tap to add'), findsNothing);
        expect(find.text(mode.hint), findsNothing);
      }
    }
    expect(find.text('100%'), findsOneWidget, reason: 'zoom and position are still shown');
  });

  testWidgets('a tab shows the notebook and closes with × or a middle click', (tester) async {
    var selected = 0;
    var closed = 0;
    await tester.pumpWidget(
      host(
        NotebookTab(
          controller: controller,
          active: false,
          onSelect: () => selected++,
          onClose: () => closed++,
        ),
      ),
    );
    expect(find.text('Lecture 4'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'not loaded yet');

    await tester.tap(find.text('Lecture 4'));
    expect((selected, closed), (1, 0));
    await tester.tap(find.byTooltip('Close tab'));
    expect((selected, closed), (1, 1));

    final middle = await tester.startGesture(
      tester.getCenter(find.text('Lecture 4')),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await middle.up();
    await tester.pump();
    expect(closed, 2);
  });
}
