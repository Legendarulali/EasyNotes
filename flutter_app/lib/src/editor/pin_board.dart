import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A picture of part of a notebook pinned over the canvas ("Pin" on a selection): a
/// reference, e.g. a matrix or a formula, that stays in place on screen while the pages
/// scroll underneath, the split screen changes or another tab is shown.
///
/// It is only a picture: it is never written into the document, its save file or its PDF
/// export.
class PinnedBox {
  PinnedBox._(this.id, this.image, this.label, this.position, this.width);

  /// Height of the card's header bar (drag handle, opacity, close).
  static const double headerHeight = 30;
  static const double minWidth = 140;

  final int id;

  /// High-resolution render of the pinned area. Owned by the [PinBoard].
  final ui.Image image;

  /// Where it came from, e.g. "Lecture 4 · page 2".
  final String label;

  /// Top-left corner, in logical pixels from the top-left of the canvas area.
  Offset position;

  /// Card width; the picture keeps its aspect ratio, so the height follows.
  double width;

  /// Shown at 75 % opacity, so the page underneath shows through.
  bool seeThrough = false;

  double get aspectRatio => image.width / math.max(1, image.height);
  double get height => headerHeight + width / aspectRatio;
  Size get size => Size(width, height);
}

/// The pinned reference boxes, bottom to top. They belong to the editor session (they
/// outlive tab switches and trips to the library), not to a notebook.
class PinBoard extends ChangeNotifier {
  final List<PinnedBox> _boxes = [];
  int _nextId = 1;
  bool _disposed = false;

  /// Bottom to top.
  List<PinnedBox> get boxes => List.unmodifiable(_boxes);
  int get length => _boxes.length;
  bool get isEmpty => _boxes.isEmpty;

  /// Adds [image] (the board disposes it with the box) on top of the other boxes.
  PinnedBox pin(ui.Image image, {required String label, required Offset position, required double width}) {
    if (_disposed) {
      image.dispose();
      throw StateError('PinBoard is disposed');
    }
    final box = PinnedBox._(_nextId++, image, label, position, math.max(PinnedBox.minWidth, width));
    _boxes.add(box);
    notifyListeners();
    return box;
  }

  /// Where a new box of [size] goes in a canvas area of [bounds]: the top-right corner,
  /// below [top] (the docked toolbar), each further box a little lower and to the left so
  /// none hides another completely.
  Offset placeNew(Size size, Size bounds, {double top = 0, double margin = 16}) {
    final step = 28.0 * (_boxes.length % 6);
    final x = bounds.width - size.width - margin - step;
    final y = top + margin + step;
    return Offset(
      x.clamp(0.0, math.max(0.0, bounds.width - size.width)),
      y.clamp(0.0, math.max(0.0, bounds.height - PinnedBox.headerHeight)),
    );
  }

  void move(PinnedBox box, Offset position) {
    if (!_boxes.contains(box) || box.position == position) return;
    box.position = position;
    notifyListeners();
  }

  void resize(PinnedBox box, double width) {
    final w = math.max(PinnedBox.minWidth, width);
    if (!_boxes.contains(box) || box.width == w) return;
    box.width = w;
    notifyListeners();
  }

  /// 100 % ↔ 75 % opacity.
  void toggleSeeThrough(PinnedBox box) {
    if (!_boxes.contains(box)) return;
    box.seeThrough = !box.seeThrough;
    notifyListeners();
  }

  /// The box the user grabs comes on top of the others.
  void bringToFront(PinnedBox box) {
    if (_boxes.isEmpty || identical(_boxes.last, box) || !_boxes.remove(box)) return;
    _boxes.add(box);
    notifyListeners();
  }

  void remove(PinnedBox box) {
    if (!_boxes.remove(box)) return;
    box.image.dispose();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final b in _boxes) {
      b.image.dispose();
    }
    _boxes.clear();
    super.dispose();
  }
}
