import 'package:flutter/painting.dart';
import 'package:flutter_app/src/canvas/viewport.dart';
import 'package:flutter_app/src/ui/color_picker_dialog.dart';
import 'package:flutter_app/widgets/draggable_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

/// Paged viewport (1000-unit column) whose [Viewport.onReachEnd] appends 1000-unit pages
/// the way the editor does, counting them.
class _Notebook {
  _Notebook({Size size = const Size(1000, 800), EdgeInsets insets = EdgeInsets.zero, this._height = 1000})
    : vp = Viewport(insets: insets) {
    vp
      ..setViewportSize(size)
      ..setContentExtent(width: 1000, height: _height)
      ..onReachEnd = (y) {
        // Same rule as the Rust engine: one page per call, only within 50 units of the end.
        if (y < _height - Viewport.appendMargin) return;
        appended++;
        lastReachY = y;
        _height += 1000;
        vp.setContentExtent(width: 1000, height: _height);
      };
  }

  final Viewport vp;
  double _height;
  int appended = 0;
  double? lastReachY;
  int get pages => (_height / 1000).round();

  /// One touch / trackpad drag step (the path that used to never append).
  void drag(double dy) => vp.pinch(focalScreen: const Offset(500, 400), scaleFactor: 1, focalDelta: Offset(0, dy));
}

void main() {
  group('Viewport (restrictive scroll, whiteboard)', () {
    test('cannot pan above or left of the origin', () {
      final vp = Viewport(insets: EdgeInsets.zero)..setViewportSize(const Size(800, 600));
      vp.panBy(const Offset(300, 200)); // finger drags right/down → would reveal negative space
      expect(vp.scroll, Offset.zero);
      vp.panBy(const Offset(-500, -800)); // drag left/up → scroll right/down
      expect(vp.scroll, const Offset(500, 800));
      vp.panBy(const Offset(10000, 10000));
      expect(vp.scroll, Offset(vp.minScrollX, vp.minScrollY));
      expect(vp.scroll, Offset.zero);
    });

    test('zoom keeps the focal point fixed and respects the boundary', () {
      final vp = Viewport(insets: EdgeInsets.zero)
        ..setViewportSize(const Size(800, 600))
        ..panBy(const Offset(-1000, -1000));
      const focal = Offset(200, 150);
      final before = vp.screenToWorld(focal);
      vp.zoomAt(focal, 2);
      expect(vp.scale, 2);
      final after = vp.screenToWorld(focal);
      expect((after - before).distance, lessThan(1e-9));

      // Zooming out at the origin must not reveal negative coordinates.
      final atOrigin = Viewport(insets: EdgeInsets.zero)..setViewportSize(const Size(800, 600));
      atOrigin.zoomAt(const Offset(400, 400), 0.5);
      expect(atOrigin.scroll, Offset.zero);
      expect(atOrigin.screenToWorld(Offset.zero), Offset.zero);
    });

    test('scale is clamped', () {
      final vp = Viewport();
      vp.zoomAt(Offset.zero, 100);
      expect(vp.scale, Viewport.maxScale);
      vp.zoomAt(Offset.zero, 0.001);
      expect(vp.scale, Viewport.minScale);
    });

    test('world ↔ screen round-trip', () {
      final vp = Viewport()
        ..panBy(const Offset(-120, -80))
        ..zoomAt(const Offset(50, 50), 1.7);
      const p = Offset(333, 444);
      expect((vp.screenToWorld(vp.worldToScreen(p)) - p).distance, lessThan(1e-9));
    });
  });

  group('Status bar zoom reset', () {
    test('resetZoom only changes the zoom and keeps the pan offsets', () {
      final vp = Viewport()..setViewportSize(const Size(800, 600));
      vp.panBy(const Offset(-1300, -4200));
      vp.zoomAt(const Offset(400, 300), 2.5);
      final offsets = vp.offset;
      expect(offsets, isNot(Offset.zero));
      vp.resetZoom();
      expect(vp.scale, 1.0);
      expect(vp.offset, offsets, reason: 'offset_x / offset_y must not jump back to (0, 0)');
    });

    test('resetZoom on a paged document keeps the vertical position', () {
      final vp = Viewport()
        ..setViewportSize(const Size(400, 800))
        ..setContentExtent(width: 1000, height: 5000)
        ..zoomAt(Offset.zero, 2)
        ..panBy(const Offset(-300, -2400));
      final before = vp.offset;
      vp.resetZoom();
      expect(vp.scale, 1);
      expect(vp.offset, before);
    });

    test('resetZoom at the top of page 1 keeps it below the toolbar', () {
      final vp = Viewport(insets: const EdgeInsets.only(top: 80))
        ..setViewportSize(const Size(600, 800))
        ..setContentExtent(width: 1000, height: 3000)
        ..fitPageWidth();
      expect(vp.worldToScreen(Offset.zero).dy, 80);
      vp.resetZoom();
      expect(vp.worldToScreen(Offset.zero).dy, 80);
      expect(vp.offset.dy, 0);
    });
  });

  group('Bug A: canvas top offset / toolbar collision', () {
    final topToolbar = toolbarObstruction(ToolbarDock.top, const Size(600, 56));

    test('a top-docked toolbar reserves margin + height + gap (80 px)', () {
      expect(topToolbar, const EdgeInsets.only(top: 80));
      expect(toolbarObstruction(ToolbarDock.topRight, const Size(60, 56)).top, 80);
      expect(toolbarObstruction(ToolbarDock.bottom, const Size(600, 56)), const EdgeInsets.only(bottom: 80));
      expect(toolbarObstruction(ToolbarDock.left, const Size(56, 500)), const EdgeInsets.only(left: 80));
      expect(toolbarObstruction(ToolbarDock.floating, const Size(600, 56)), EdgeInsets.zero);
      // Nothing docked at the top still leaves a little air above page 1.
      expect(Viewport.insetsFor(EdgeInsets.zero).top, Viewport.defaultInsets.top);
      expect(Viewport.insetsFor(topToolbar).top, 80);
    });

    test('page 1 starts below the toolbar and cannot be scrolled under it', () {
      final vp = Viewport(insets: Viewport.insetsFor(topToolbar))
        ..setViewportSize(const Size(1400, 800))
        ..setContentExtent(width: 1000, height: 2000);
      expect(vp.worldToScreen(Offset.zero), const Offset(200, 80));
      vp.panBy(const Offset(0, 500)); // pull down at the top: nothing above page 1
      expect(vp.worldToScreen(Offset.zero).dy, 80);
      // Status bar shows Y 0 at the top, and stroke coordinates are unchanged: the
      // point right under the toolbar band is world y = 0, the top edge of page 1.
      expect(vp.offset.dy, 0);
      expect(vp.screenToWorld(const Offset(700, 80)), const Offset(500, 0));
      expect(vp.screenToWorld(const Offset(700, 580)), const Offset(500, 500));
    });

    test('a view resting at the top follows the toolbar; a scrolled view does not jump', () {
      final atTop = Viewport()
        ..setViewportSize(const Size(1000, 800))
        ..setContentExtent(width: 1000, height: 3000);
      expect(atTop.worldToScreen(Offset.zero).dy, Viewport.defaultInsets.top);
      atTop.setInsets(Viewport.insetsFor(topToolbar)); // toolbar docked at the top
      expect(atTop.worldToScreen(Offset.zero).dy, 80);

      final scrolled = Viewport()
        ..setViewportSize(const Size(1000, 800))
        ..setContentExtent(width: 1000, height: 3000)
        ..panBy(const Offset(0, -700));
      final before = scrolled.scroll;
      scrolled.setInsets(Viewport.insetsFor(topToolbar));
      expect(scrolled.scroll, before);
    });

    test('a side-docked toolbar centres the page in the remaining width', () {
      final vp = Viewport(insets: const EdgeInsets.only(left: 80))
        ..setViewportSize(const Size(1280, 800))
        ..setContentExtent(width: 1000, height: 1000);
      // Free area 80…1280 (1200 px): the 1000 px page sits at 180…1180.
      expect(vp.worldToScreen(Offset.zero).dx, 180);
      // Zoomed in, the page's left edge stops at the toolbar instead of under it.
      vp.zoomAt(const Offset(640, 400), 2);
      vp.panBy(const Offset(5000, 0));
      expect(vp.worldToScreen(Offset.zero).dx, 80);
    });

    test('fitPageWidth fits the page between the insets', () {
      final vp = Viewport(insets: const EdgeInsets.only(left: 80, top: 24))
        ..setViewportSize(const Size(512, 900))
        ..setContentExtent(width: 1000, height: 1000)
        ..fitPageWidth();
      expect(vp.scale, closeTo((512 - 80 - 32) / 1000, 1e-9));
      expect(vp.worldToScreen(Offset.zero).dy, 24);
    });
  });

  group('Paged documents', () {
    test('horizontal scroll stops at the 1000-unit page edges', () {
      final vp = Viewport(insets: EdgeInsets.zero)
        ..setViewportSize(const Size(400, 800))
        ..setContentExtent(width: 1000, height: 3000);
      vp.panBy(const Offset(-5000, 0));
      expect(vp.scroll.dx, 600); // 1000 - 400
      vp.panBy(const Offset(5000, 0));
      expect(vp.scroll.dx, 0);
    });

    test('a page narrower than the screen is centred', () {
      final vp = Viewport()
        ..setViewportSize(const Size(1400, 800))
        ..setContentExtent(width: 1000, height: 1000);
      expect(vp.scroll.dx, -200);
      expect(vp.worldToScreen(const Offset(500, 0)).dx, 700);
    });

    test('fitPageWidth zooms out narrow screens only', () {
      final phone = Viewport()
        ..setViewportSize(const Size(432, 900))
        ..setContentExtent(width: 1000, height: 1000)
        ..fitPageWidth();
      expect(phone.scale, closeTo(0.4, 1e-9));
      final desktop = Viewport()
        ..setViewportSize(const Size(1800, 900))
        ..setContentExtent(width: 1000, height: 1000)
        ..fitPageWidth();
      expect(desktop.scale, 1);
    });
  });

  group('Bug B: continuous page creation while scrolling', () {
    test('touch / trackpad scrolling appends page N+1 within 50 units of the end', () {
      final nb = _Notebook(); // 1000 × 800 canvas, one page, 100 %
      // Visible bottom at 800 + 140 = 940: still 60 units above the end of page 1.
      nb.drag(-140);
      expect(nb.appended, 0);
      nb.drag(-15); // bottom at 955 ≥ 1000 − 50
      expect(nb.appended, 1);
      expect(nb.pages, 2);
      expect(nb.lastReachY, closeTo(955, 1e-9));
      // Scrolling continues seamlessly into page 2 and on to page 3.
      for (var i = 0; i < 10; i++) {
        nb.drag(-100);
      }
      expect(nb.vp.scroll.dy, greaterThan(1000));
      expect(nb.pages, 3);
    });

    test('mouse wheel scrolling appends too', () {
      final nb = _Notebook();
      for (var i = 0; i < 4; i++) {
        nb.vp.panBy(const Offset(0, -50)); // one wheel notch
      }
      expect(nb.appended, 1);
    });

    test('scrolling up, zooming and resizing never append', () {
      final nb = _Notebook(size: const Size(1000, 1000), height: 2000)..drag(-400);
      expect(nb.appended, 0); // bottom at 1400 of 2000
      nb.vp.zoomAt(const Offset(500, 500), 0.5); // whole stack in view, but no scroll
      expect(nb.appended, 0);
      nb.drag(300); // scroll up
      nb.vp.setViewportSize(const Size(1000, 4000));
      expect(nb.appended, 0);
    });

    test('one page per scroll step even when zoomed far out', () {
      final nb = _Notebook(size: const Size(1000, 1000));
      nb.vp.zoomAt(Offset.zero, Viewport.minScale); // 4000 units visible
      nb.drag(-10);
      expect(nb.appended, 1);
      nb.drag(-10);
      expect(nb.appended, 2);
    });

    test('the end of the stack is still reachable when no page can be added', () {
      final vp = Viewport(insets: EdgeInsets.zero)
        ..setViewportSize(const Size(1000, 800))
        ..setContentExtent(width: 1000, height: 1000);
      vp.panBy(const Offset(0, -5000));
      expect(vp.scroll.dy, vp.maxScrollY);
      expect(vp.maxScrollY, 1000 - 800 * (1 - Viewport.endSlack));
    });
  });

  group('hex colours', () {
    test('parses #RGB, #RRGGBB and #AARRGGBB', () {
      expect(parseHexColor('#f00')!.toARGB32(), 0xFFFF0000);
      expect(parseHexColor('1E40AF')!.toARGB32(), 0xFF1E40AF);
      expect(parseHexColor('#801E40AF')!.toARGB32(), 0x801E40AF);
      expect(parseHexColor('#12'), isNull);
      expect(parseHexColor('#GGGGGG'), isNull);
    });

    test('formats back to hex', () {
      expect(toHex(const Color(0xFF1E40AF)), '#1E40AF');
      expect(toHex(const Color(0x801E40AF)), '#801E40AF');
    });
  });
}
