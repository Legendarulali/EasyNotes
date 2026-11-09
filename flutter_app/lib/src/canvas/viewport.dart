import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Pan / zoom state of the canvas.
///
/// `scroll` is the world coordinate shown at the top-left corner of the canvas widget
/// (the status bar's `offset_x, offset_y`). Scrolling never goes above the first page or
/// left of the origin (`minScrollX = minScrollY = 0`), so no content can be created at
/// negative coordinates.
///
/// Paged documents additionally have a fixed content width (the 1000-unit page column):
/// horizontal scrolling stops at the page edges, and when the page is narrower than the
/// screen it is centred. Vertically the stack ends at the last page; trying to scroll
/// past it calls [onReachEnd], which appends a page (continuous scroll).
class Viewport extends ChangeNotifier {
  static const double minScale = 0.25;
  static const double maxScale = 6.0;
  static const double minScrollX = 0;
  static const double minScrollY = 0;

  /// Share of the screen height that may show dark space below the last page.
  static const double endSlack = 0.25;

  /// Screen pixels of pulling past the last page that append one new page.
  static const double appendDistance = 96;

  Offset _scroll = Offset.zero;
  double _scale = 1.0;
  Size _size = Size.zero;
  double? _contentWidth;
  double? _contentHeight;
  double _overscroll = 0;

  /// Called when a pan tries to scroll past the bottom of the last page. The callback
  /// typically appends a page and calls [setContentExtent] with the new height.
  VoidCallback? onReachEnd;

  Offset get scroll => _scroll;
  double get scale => _scale;
  Size get size => _size;
  double? get contentWidth => _contentWidth;
  double? get contentHeight => _contentHeight;
  bool get isPaged => _contentWidth != null;

  Offset worldToScreen(Offset world) => (world - _scroll) * _scale;
  Offset screenToWorld(Offset screen) => screen / _scale + _scroll;

  Rect worldRectToScreen(Rect r) => Rect.fromPoints(worldToScreen(r.topLeft), worldToScreen(r.bottomRight));

  /// World-space rectangle visible in a canvas of [size].
  Rect visibleWorldRect(Size size) => Rect.fromLTWH(_scroll.dx, _scroll.dy, size.width / _scale, size.height / _scale);

  /// Largest vertical scroll before the end of the page stack (`null` = unbounded).
  double? get maxScrollY {
    final h = _contentHeight;
    if (h == null) return null;
    final visible = _size.height / _scale;
    return math.max(0.0, h - visible * (1 - endSlack));
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

  /// Pans by a screen-space delta (finger movement / wheel).
  void panBy(Offset screenDelta) {
    if (screenDelta == Offset.zero) return;
    final target = _scroll - screenDelta / _scale;
    final max = maxScrollY;
    final reachEnd = onReachEnd;
    if (max != null && reachEnd != null && target.dy > max) {
      // Swiping past the last page appends a new one directly beneath it.
      _overscroll += (target.dy - max) * _scale;
      if (_overscroll >= appendDistance) {
        _overscroll = 0;
        reachEnd();
      }
    } else if (screenDelta.dy > 0) {
      _overscroll = 0;
    }
    _scroll = target;
    _clamp();
    notifyListeners();
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

  /// Combined pinch update: scale about the focal point, then pan by the focal delta.
  void pinch({required Offset focalScreen, required double scaleFactor, required Offset focalDelta}) {
    final focalWorld = screenToWorld(focalScreen - focalDelta);
    _scale = (_scale * scaleFactor).clamp(minScale, maxScale);
    _scroll = focalWorld - focalScreen / _scale;
    _clamp();
    notifyListeners();
  }

  /// Resets the zoom to 100 % **without** moving: the current pan offsets are kept
  /// (only re-clamped if 100 % would show space outside the page bounds).
  void resetZoom() {
    if (_scale == 1.0) return;
    _scale = 1.0;
    _clamp();
    notifyListeners();
  }

  /// Initial zoom for a freshly opened document: the whole page width fits on screen
  /// when the screen is narrower than the page (never zooms in beyond 100 %).
  void fitPageWidth({double margin = 16}) {
    final w = _contentWidth;
    if (w == null || _size.width <= 0) return;
    _scale = math.min(1.0, (_size.width - 2 * margin) / w).clamp(minScale, maxScale);
    _clamp();
    notifyListeners();
  }

  /// Jumps to the top-left of the document at 100 %.
  void reset() {
    _scroll = Offset.zero;
    _scale = 1.0;
    _clamp();
    notifyListeners();
  }

  void _clamp() {
    var x = math.max(minScrollX, _scroll.dx);
    var y = math.max(minScrollY, _scroll.dy);
    final w = _contentWidth;
    if (w != null && _size.width > 0) {
      final visible = _size.width / _scale;
      x = visible >= w ? -(visible - w) / 2 : _scroll.dx.clamp(0.0, w - visible);
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
