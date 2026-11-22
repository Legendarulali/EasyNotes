import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_app/src/canvas/painters.dart';
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/pin_board.dart';
import 'package:flutter_app/src/rust/document.dart';
import 'package:flutter_app/src/rust/geometry/point.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/ui/selection_actions.dart';
import 'package:flutter_app/widgets/pinned_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 4-unit-wide black horizontal line from x = 10 to 190 at height [y].
StrokeRender _line(String id, double y) => StrokeRender(
  id: id,
  tool: ToolType.pen,
  kind: RenderKind.openPolyline,
  color: 0xFF000000,
  opacity: 1,
  width: 4,
  geometry: Float32List.fromList([10, y, 190, y]),
  bounds: ViewportRect(left: 8, top: y - 2, right: 192, bottom: y + 2),
);

/// Test images of the given sizes (created one at a time: [createTestImage] is guarded).
Future<List<ui.Image>> _images(WidgetTester tester, List<(int, int)> sizes) async => (await tester.runAsync(() async => [
  for (final (w, h) in sizes) await createTestImage(width: w, height: h, cache: false),
]))!;

/// Alpha of the pixel at ([x], [y]) of an RGBA image.
int _alpha(ByteData rgba, int width, int x, int y) => rgba.getUint8((y * width + x) * 4 + 3);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PinBoard', () {
    testWidgets('pins, moves, resizes, stacks and unpins; images are freed', (tester) async {
      final images = await _images(tester, [(200, 100), (100, 100)]);
      final board = PinBoard();
      final a = board.pin(images[0], label: 'A', position: const Offset(10, 10), width: 300);
      final b = board.pin(images[1], label: 'B', position: const Offset(50, 50), width: 20);
      expect(board.boxes, [a, b]);
      expect(a.height, PinnedBox.headerHeight + 150, reason: 'the picture keeps its 2 : 1 aspect ratio');
      expect(b.width, PinnedBox.minWidth, reason: 'never smaller than the minimum');

      board.move(a, const Offset(70, 80));
      board.resize(a, 400);
      board.toggleSeeThrough(a);
      expect((a.position, a.width, a.seeThrough), (const Offset(70, 80), 400.0, true));
      board.bringToFront(a);
      expect(board.boxes, [b, a]);

      board.remove(a);
      expect(board.boxes, [b]);
      expect(images[0].debugDisposed, isTrue);
      board.dispose();
      expect(images[1].debugDisposed, isTrue, reason: 'the board frees what is left');
    });

    test('new pins go top right below the toolbar and cascade', () {
      final board = PinBoard();
      const size = Size(200, 130);
      const bounds = Size(1000, 700);
      final first = board.placeNew(size, bounds, top: 70);
      expect(first, const Offset(1000 - 200 - 16, 70 + 16));
      expect(board.placeNew(const Size(2000, 130), bounds), const Offset(0, 16), reason: 'clamped inside');
      board.dispose();
    });
  });

  group('Pinned overlay box', () {
    late PinBoard board;
    late ui.Image image;

    setUp(() => board = PinBoard());
    tearDown(() => board.dispose());

    Future<void> pumpLayer(WidgetTester tester, {Size bounds = const Size(800, 600), VoidCallback? onPage}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: bounds,
                  child: Stack(
                    children: [
                      // Stands in for the page canvas under the pins.
                      Positioned.fill(child: GestureDetector(onTap: onPage, child: const ColoredBox(color: Colors.grey))),
                      Positioned.fill(child: PinnedBoxesLayer(board: board, bounds: bounds)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    Rect cardRect(WidgetTester tester) => tester.getRect(find.byType(PinnedOverlayBox));

    testWidgets('header drags it, the corner resizes it, opacity toggles, × unpins', (tester) async {
      image = (await tester.runAsync(() => createTestImage(width: 300, height: 150)))!;
      final box = board.pin(image, label: 'Lecture 4 · page 1', position: const Offset(100, 100), width: 240);
      var pageTaps = 0;
      await pumpLayer(tester, onPage: () => pageTaps++);
      expect(find.text('Lecture 4 · page 1'), findsOneWidget);
      expect(cardRect(tester), const Rect.fromLTWH(100, 100, 240, PinnedBox.headerHeight + 120));

      // Drag by the header.
      await tester.drag(find.text('Lecture 4 · page 1'), const Offset(150, 80));
      await tester.pumpAndSettle();
      expect(cardRect(tester).topLeft.dx, greaterThan(200));
      expect(box.position, cardRect(tester).topLeft);

      // Resize from the bottom-right corner: the picture keeps its aspect ratio.
      final before = cardRect(tester);
      await tester.drag(find.byTooltip('Drag to resize'), const Offset(120, 10));
      await tester.pumpAndSettle();
      final after = cardRect(tester);
      expect(after.width, greaterThan(before.width + 60));
      expect(after.height - PinnedBox.headerHeight, closeTo(after.width / 2, 0.5));
      expect(after.topLeft, before.topLeft);

      // 75 % opacity and back.
      double opacity() => tester.widget<Opacity>(find.byType(Opacity)).opacity;
      expect(opacity(), 1);
      await tester.tap(find.byTooltip('Make see-through (75 %)'));
      await tester.pump();
      expect(opacity(), 0.75);
      await tester.tap(find.byTooltip('Make opaque (100 %)'));
      await tester.pump();
      expect(opacity(), 1);

      // Taps on the card stay on the card; next to it they reach the page.
      await tester.tapAt(cardRect(tester).center);
      await tester.tapAt(const Offset(20, 580));
      expect(pageTaps, 1);

      await tester.tap(find.byTooltip('Unpin'));
      await tester.pump();
      expect(board.isEmpty, isTrue);
      expect(find.byType(PinnedOverlayBox), findsNothing);
      expect(image.debugDisposed, isTrue);
    });

    testWidgets('several pins at once; a smaller window keeps them reachable', (tester) async {
      final images = await _images(tester, [(200, 200), (200, 100)]);
      board
        ..pin(images[0], label: 'Matrix A', position: const Offset(600, 40), width: 180)
        ..pin(images[1], label: 'Formula', position: const Offset(560, 500), width: 200);
      await pumpLayer(tester);
      expect(find.byType(PinnedOverlayBox), findsNWidgets(2));

      await pumpLayer(tester, bounds: const Size(400, 300));
      for (final card in find.byType(PinnedOverlayBox).evaluate()) {
        final rect = tester.getRect(find.byWidget(card.widget));
        expect(rect.right, lessThanOrEqualTo(400));
        expect(rect.top, lessThanOrEqualTo(300 - PinnedBox.headerHeight));
      }
      expect(board.boxes.first.position, const Offset(600, 40), reason: 'its place is kept for a larger window');
    });
  });

  group('Pin snapshot', () {
    late Directory tmp;
    late EditorController c;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('easynotes_pin');
      final library = LibraryService(tmp);
      final entry = await library.createNotebook(tmp, 'Algebra', NotebookTemplate.grid);
      c = EditorController(entry: entry, library: library);
      c.scene.load(SceneSnapshot(strokes: [_line('s1', 20), _line('s2', 80)], notes: const [], selection: const SelectionInfo(ids: [])));
    });

    tearDown(() async {
      c.dispose();
      await tmp.delete(recursive: true);
    });

    testWidgets('renders only the selected items, sharply', (tester) async {
      const area = Rect.fromLTWH(0, 0, 200, 100);
      final (onlyS1, everything) = (await tester.runAsync(() async {
        final a = await renderArea(c, area, scale: 2, only: {'s1'});
        final b = await renderArea(c, area, scale: 2);
        return (a, b);
      }))!;
      expect((onlyS1.width, onlyS1.height), (400, 200), reason: '2 pixels per world unit');
      final bytes = (await tester.runAsync(
        () => Future.wait([
          onlyS1.toByteData(format: ui.ImageByteFormat.rawRgba),
          everything.toByteData(format: ui.ImageByteFormat.rawRgba),
        ]),
      ))!;
      expect(_alpha(bytes[0]!, 400, 200, 40), greaterThan(200), reason: 's1 at y = 20');
      expect(_alpha(bytes[0]!, 400, 200, 160), 0, reason: 's2 (y = 80) was not selected');
      expect(_alpha(bytes[1]!, 400, 200, 160), greaterThan(200));
      onlyS1.dispose();
      everything.dispose();
    });

    test('the pinned area keeps a margin, stays on the page, and the resolution is capped', () {
      c.viewport.setContentExtent(width: 1000, height: 2000);
      expect(pinAreaFor(c, const Rect.fromLTRB(5, 300, 995, 400)), const Rect.fromLTRB(0, 284, 1000, 416));
      expect(pinRenderScale(const Rect.fromLTWH(0, 0, 200, 100), 1.5), 4.5);
      expect(pinRenderScale(const Rect.fromLTWH(0, 0, 1000, 2000), 2), closeTo(4096 / 2000, 1e-9));
    });
  });

  testWidgets('the selection bar has Pin next to the other actions', (tester) async {
    final tmp = (await tester.runAsync(() => Directory.systemTemp.createTemp('easynotes_pinbar')))!;
    final library = LibraryService(tmp);
    final entry = (await tester.runAsync(() => library.createNotebook(tmp, 'Bar', NotebookTemplate.ruled)))!;
    final c = EditorController(entry: entry, library: library);
    var pins = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SelectionActionBar(controller: c, onEditNote: (_) {}, onPin: () => pins++)),
      ),
    );
    final pin = find.byIcon(Icons.push_pin_outlined);
    expect(pin, findsOneWidget);
    expect(tester.getCenter(pin).dx, lessThan(tester.getCenter(find.byIcon(Icons.delete_outline)).dx));
    await tester.tap(pin);
    expect(pins, 1);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SelectionActionBar(controller: c, onEditNote: (_) {}))));
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing, reason: 'no Pin without a handler');
    c.dispose();
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
