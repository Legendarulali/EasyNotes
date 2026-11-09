import 'package:flutter/painting.dart';
import 'package:flutter_app/src/canvas/viewport.dart';
import 'package:flutter_app/src/ui/color_picker_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Viewport (restrictive scroll, whiteboard)', () {
    test('cannot pan above or left of the page origin', () {
      final vp = Viewport()..setViewportSize(const Size(800, 600));
      vp.panBy(const Offset(300, 200)); // finger drags right/down → would reveal negative space
      expect(vp.scroll, Offset.zero);
      vp.panBy(const Offset(-500, -800)); // drag left/up → scroll right/down
      expect(vp.scroll, const Offset(500, 800));
      vp.panBy(const Offset(10000, 10000));
      expect(vp.scroll.dx, Viewport.minScrollX);
      expect(vp.scroll.dy, Viewport.minScrollY);
    });

    test('zoom keeps the focal point fixed and respects the boundary', () {
      final vp = Viewport()
        ..setViewportSize(const Size(800, 600))
        ..panBy(const Offset(-1000, -1000));
      const focal = Offset(200, 150);
      final before = vp.screenToWorld(focal);
      vp.zoomAt(focal, 2);
      expect(vp.scale, 2);
      final after = vp.screenToWorld(focal);
      expect((after - before).distance, lessThan(1e-9));

      // Zooming out at the origin must not reveal negative coordinates.
      final atOrigin = Viewport()..setViewportSize(const Size(800, 600));
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

  group('Status bar zoom reset (bug fix)', () {
    test('resetZoom only changes the zoom and keeps the pan offsets', () {
      final vp = Viewport()..setViewportSize(const Size(800, 600));
      vp.panBy(const Offset(-1300, -4200));
      vp.zoomAt(const Offset(400, 300), 2.5);
      final offsets = vp.scroll;
      expect(offsets, isNot(Offset.zero));
      vp.resetZoom();
      expect(vp.scale, 1.0);
      expect(vp.scroll, offsets, reason: 'offset_x / offset_y must not jump back to (0, 0)');
    });

    test('resetZoom on a paged document keeps the vertical position', () {
      final vp = Viewport()
        ..setViewportSize(const Size(400, 800))
        ..setContentExtent(width: 1000, height: 5000)
        ..zoomAt(Offset.zero, 2)
        ..panBy(const Offset(-300, -2400));
      final before = vp.scroll;
      vp.resetZoom();
      expect(vp.scale, 1);
      expect(vp.scroll, before);
    });
  });

  group('Paged documents', () {
    test('horizontal scroll stops at the 1000-unit page edges', () {
      final vp = Viewport()
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

    test('swiping past the last page appends one (continuous scroll)', () {
      var height = 1000.0;
      var appended = 0;
      final vp = Viewport()
        ..setViewportSize(const Size(1000, 800))
        ..setContentExtent(width: 1000, height: height);
      vp.onReachEnd = () {
        appended++;
        height += 1000;
        vp.setContentExtent(width: 1000, height: height);
      };
      // Scroll to the end of page 1: max = 1000 - 800 * 0.75 = 400.
      vp.panBy(const Offset(0, -400));
      expect(vp.scroll.dy, 400);
      expect(appended, 0);
      // Keep pulling: a small pull is not enough, a real swipe appends a page.
      vp.panBy(const Offset(0, -40));
      expect(appended, 0);
      vp.panBy(const Offset(0, -80));
      expect(appended, 1);
      expect(vp.contentHeight, 2000);
      // Scrolling continues seamlessly into the new page.
      vp.panBy(const Offset(0, -500));
      expect(vp.scroll.dy, greaterThan(400));
      // Scrolling back up never appends.
      vp.panBy(const Offset(0, 3000));
      expect(vp.scroll.dy, 0);
      expect(appended, 1);
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
