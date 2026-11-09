import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Pan / zoom state of the canvas.
///
/// `scroll` is the world coordinate at the top-left corner of the canvas widget. The
/// canvas is partly covered by floating chrome (the docked toolbar), so the viewport has
/// screen-space [insets]: at the scroll limits the content edges stop at the inset lines
/// instead of the widget edges. World `y = 0` (the top of page 1) therefore rests just
/// below a top-docked toolbar instead of behind it; stroke coordinates are unaffected
/// (world `y = 0` is always the top edge of page 1).
///
/// [offset] is the world point at the inset corner — what the status bar shows as
/// `X` / `Y` — and it is `(0, 0)` when the view is at the top-left of the document.
/// Nothing can be scrolled into view above or left of the origin, so no content is
/// created at negative coordinates.
///
/// Paged documents additionally have a fixed content width (the 1000-unit page column):
/// horizontal scrolling stops at the page edges, and when the page is narrower than the
/// free area it is centred there. Vertically the stack grows on demand: any downward
/// scroll (wheel, touch, trackpad, pinch) that brings the bottom of the visible area within
/// [appendMargin] world units of the end of the last page calls [onReachEnd], which
/// appends the next page (continuous scroll).
class Viewport extends ChangeNotifier {
  Viewport({EdgeInsets insets = defaultInsets}) : _insets = insets {
    _scroll = Offset(-insets.left, -insets.top);
  }

  static const double minScale = 0.25;
  static const double maxScale = 6.0;

  /// Share of the screen height that may show dark space below the last page (only seen
  /// when no page can be appended, e.g. at the page limit).
  static const double endSlack = 0.25;

  /// World units before the bottom of the last page at which scrolling down appends the
  /// next page (`Y ≥ N · 1000 − appendMargin`).
  static const double appendMargin = 50;

  /// Breathing room above page 1 when nothing is docked at the top.
  static const EdgeInsets defaultInsets = EdgeInsets.only(top: 24);

  late Offset _scroll;
  double _scale = 1.0;
  Size _size = Size.zero;
  double? _contentWidth;
  double? _contentHeight;
  EdgeInsets _insets;

  /// Called after a downward scroll when the bottom of the visible area (its world Y is
  /// passed) is within [appendMargin] of the end of the page stack. The callback
  /// typically appends a page and calls [setContentExtent] with the new height.
  ValueChanged<double>? onReachEnd;

  Offset get scroll => _scroll;
  double get scale => _scale;
  Size get size => _size;
  EdgeInsets get insets => _insets;
  double? get contentWidth => _contentWidth;
  double? get contentHeight => _contentHeight;
  bool get isPaged => _contentWidth != null;

  Offset worldToScreen(Offset world) => (world - _scroll) * _scale;
  Offset screenToWorld(Offset screen) => screen / _scale + _scroll;

  Rect worldRectToScreen(Rect r) => Rect.fromPoints(worldToScreen(r.topLeft), worldToScreen(r.bottomRight));

  /// World point at the top-left corner of the free (un-obstructed) area: the status
  /// bar's pan offsets.
  Offset get offset => screenToWorld(Offset(_insets.left, _insets.top));

  /// World-space rectangle visible in a canvas of [size].
  Rect visibleWorldRect(Size size) => Rect.fromLTWH(_scroll.dx, _scroll.dy, size.width / _scale, size.height / _scale);

  /// World Y of the bottom edge of the canvas.
  double get visibleBottom => _scroll.dy + _size.height / _scale;

  /// Smallest scroll: the origin sits at the inset corner.
  double get minScrollX => -_insets.left / _scale;
  double get minScrollY => -_insets.top / _scale;

  /// Largest vertical scroll before the end of the page stack (`null` = unbounded).
  double? get maxScrollY {
    final h = _contentHeight;
    if (h == null) return null;
    final slack = math.max(_insets.bottom, _size.height * endSlack);
    return math.max(minScrollY, h - (_size.height - slack) / _scale);
  }

  /// Page column width (`null` for unbounded whiteboards) and total page height.
  void setContentExtent({double? width, double? height}) {
    if (width == _contentWidth && height == _contentHeight) return;
    _contentWidth = width;
    _contentHeight = height;
    _clamp();
    notifyListeners();
  }

  /// Canvas widget size in logical pixels. Called during layout, so it does not notify:
  /// the painters read the clamped values on their next paint.
  void setViewportSize(Size size) {
    if (size == _size) return;
    _size = size;
    _clamp();
  }

  /// Screen-space margins kept free of content at the scroll limits (the area behind a
  /// docked toolbar). A view resting at the top / left edge stays there, so the first
  /// page moves out from under a toolbar that was just docked over it.
  void setInsets(EdgeInsets insets) {
    if (insets == _insets) return;
    final eps = 0.5 / _scale;
    final pinnedTop = (_scroll.dy - minScrollY).abs() < eps;
    final pinnedLeft = (_scroll.dx - minScrollX).abs() < eps;
    _insets = insets;
    _scroll = Offset(pinnedLeft ? minScrollX : _scroll.dx, pinnedTop ? minScrollY : _scroll.dy);
    _clamp();
    notifyListeners();
  }

  /// Insets for a canvas whose edges are covered by [obstruction] (e.g. a docked
  /// toolbar), never less than [defaultInsets].
  static EdgeInsets insetsFor(EdgeInsets obstruction) => EdgeInsets.fromLTRB(
    math.max(defaultInsets.left, obstruction.left),
    math.max(defaultInsets.top, obstruction.top),
    math.max(defaultInsets.right, obstruction.right),
    math.max(defaultInsets.bottom, obstruction.bottom),
  );

  /// Pans by a screen-space delta (finger movement / wheel).
  void panBy(Offset screenDelta) {
    if (screenDelta == Offset.zero) return;
    final before = _scroll.dy;
    _scroll = _scroll - screenDelta / _scale;
    _settle(before);
  }

  /// Zooms to [newScale] keeping the world point under [focalScreen] fixed (subject to
  /// the boundaries).
  void zoomAt(Offset focalScreen, double newScale) {
    final target = newScale.clamp(minScale, maxScale);
    if (target == _scale) return;
    final focalWorld = screenToWorld(focalScreen);
    _scale = target;
    _scroll = focalWorld - focalScreen / _scale;
    _clamp();
    notifyListeners();
  }

  /// Combined pinch / drag update (touch and trackpad): scale about the focal point,
  /// then pan by the focal delta.
  void pinch({required Offset focalScreen, required double scaleFactor, required Offset focalDelta}) {
    final before = _scroll.dy;
    final focalWorld = screenToWorld(focalScreen - focalDelta);
    _scale = (_scale * scaleFactor).clamp(minScale, maxScale);
    _scroll = focalWorld - focalScreen / _scale;
    _settle(before);
  }

  /// Resets the zoom to 100 % **without** moving: the pan offsets ([offset], the world
  /// point at the top-left of the free area) are kept, only re-clamped if 100 % would
  /// show space outside the page bounds.
  void resetZoom() {
    if (_scale == 1.0) return;
    final anchor = offset;
    _scale = 1.0;
    _scroll = anchor - Offset(_insets.left, _insets.top);
    _clamp();
    notifyListeners();
  }

  /// Initial view of a freshly opened document: top of the first page, and the whole
  /// page width on screen when the free area is narrower than the page (never zooms in
  /// beyond 100 %).
  void fitPageWidth({double margin = 16}) {
    final w = _contentWidth;
    if (w == null || _size.width <= 0) return;
    final free = _size.width - _insets.horizontal;
    _scale = math.min(1.0, (free - 2 * margin) / w).clamp(minScale, maxScale);
    _scroll = Offset(minScrollX, minScrollY);
    _clamp();
    notifyListeners();
  }

  /// Jumps to the top-left of the document at 100 %.
  void reset() {
    _scale = 1.0;
    _scroll = Offset(minScrollX, minScrollY);
    _clamp();
    notifyListeners();
  }

  /// Clamps a requested scroll, notifies, and – if the request moved the view down –
  /// lets [onReachEnd] grow the page stack.
  void _settle(double previousY) {
    final movedDown = _scroll.dy > previousY + 1e-9;
    _clamp();
    notifyListeners();
    if (movedDown) _checkReachEnd();
  }

  void _checkReachEnd() {
    final h = _contentHeight;
    final reachEnd = onReachEnd;
    if (h == null || reachEnd == null || _size.height <= 0) return;
    final bottom = visibleBottom;
    if (bottom >= h - appendMargin) reachEnd(bottom);
  }

  void _clamp() {
    var x = math.max(minScrollX, _scroll.dx);
    var y = math.max(minScrollY, _scroll.dy);
    final w = _contentWidth;
    if (w != null && _size.width > 0) {
      final free = _size.width - _insets.horizontal;
      final pageWidth = w * _scale;
      if (free <= 0 || pageWidth <= free) {
        // Centred in the free area (or the whole widget if the insets leave no room).
        final left = free > 0 ? _insets.left : 0.0;
        final room = free > 0 ? free : _size.width;
        x = -(left + (room - pageWidth) / 2) / _scale;
      } else {
        x = _scroll.dx.clamp(minScrollX, w - (_size.width - _insets.right) / _scale);
      }
    }
    final maxY = maxScrollY;
    if (maxY != null && _size.height > 0) y = math.min(y, maxY);
    _scroll = Offset(x, y);
  }

  /// Applies the world → screen transform to [canvas].
  void applyTo(Canvas canvas) {
    canvas.scale(_scale);
    canvas.translate(-_scroll.dx, -_scroll.dy);
  }
}
