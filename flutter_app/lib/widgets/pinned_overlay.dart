import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/editor/pin_board.dart';

/// The boxes of a [PinBoard] over the canvas area ([bounds] = its size). Place it in a
/// [Stack] covering the canvas: the space between boxes lets pointers through to the
/// pages underneath.
class PinnedBoxesLayer extends StatelessWidget {
  const PinnedBoxesLayer({super.key, required this.board, required this.bounds});

  final PinBoard board;
  final Size bounds;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: board,
    builder: (context, _) => Stack(
      clipBehavior: Clip.none,
      children: [
        for (final box in board.boxes) PinnedOverlayBox(key: ValueKey(box.id), board: board, box: box, bounds: bounds),
      ],
    ),
  );
}

/// One pinned reference: a card with the snapshot, dragged by its header bar (grip,
/// source, opacity toggle, close) and resized from its bottom-right corner. It sits at a
/// fixed spot on screen, so it stays in view while the pages scroll underneath. When the
/// window shrinks it is kept reachable inside [bounds].
class PinnedOverlayBox extends StatelessWidget {
  const PinnedOverlayBox({super.key, required this.board, required this.box, required this.bounds});

  final PinBoard board;
  final PinnedBox box;
  final Size bounds;

  static const double _grip = 22;

  /// Where the box is drawn: its stored place, pulled back inside [bounds] so the header
  /// can always be grabbed (the stored place is kept for when there is room again).
  static Rect layoutRect(PinnedBox box, Size bounds) {
    final width = math.min(box.width, math.max(PinnedBox.minWidth, bounds.width));
    final height = PinnedBox.headerHeight + width / box.aspectRatio;
    final left = box.position.dx.clamp(0.0, math.max(0.0, bounds.width - width)).toDouble();
    final top = box.position.dy.clamp(0.0, math.max(0.0, bounds.height - PinnedBox.headerHeight)).toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  void _drag(DragUpdateDetails d) {
    final r = layoutRect(box, bounds);
    final next = r.topLeft + d.delta;
    board.move(
      box,
      Offset(
        next.dx.clamp(0.0, math.max(0.0, bounds.width - r.width)),
        next.dy.clamp(0.0, math.max(0.0, bounds.height - PinnedBox.headerHeight)),
      ),
    );
  }

  void _resize(DragUpdateDetails d) {
    final r = layoutRect(box, bounds);
    // Diagonal drag: follow whichever direction grows the picture more.
    final byWidth = r.width + d.delta.dx;
    final byHeight = (r.height - PinnedBox.headerHeight + d.delta.dy) * box.aspectRatio;
    final wanted = d.delta.dx.abs() >= d.delta.dy.abs() ? byWidth : byHeight;
    // Resize from where the box is drawn, not from a place it was pulled back from.
    if (r.topLeft != box.position) board.move(box, r.topLeft);
    board.resize(box, wanted.clamp(PinnedBox.minWidth, math.max(PinnedBox.minWidth, bounds.width - r.left)));
  }

  @override
  Widget build(BuildContext context) {
    final r = layoutRect(box, bounds);
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fromRect(
      rect: r,
      child: Opacity(
        opacity: box.seeThrough ? 0.75 : 1,
        child: Material(
          color: Colors.white,
          elevation: 10,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                children: [
                  _Header(
                    box: box,
                    onDragStart: () => board.bringToFront(box),
                    onDrag: _drag,
                    onToggleOpacity: () => board.toggleSeeThrough(box),
                    onClose: () => board.remove(box),
                  ),
                  Expanded(
                    child: GestureDetector(
                      // Taps on the picture bring it forward and never reach the page below.
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => board.bringToFront(box),
                      child: RawImage(image: box.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                  ),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => board.bringToFront(box),
                    onPanUpdate: _resize,
                    child: Tooltip(
                      message: 'Drag to resize',
                      waitDuration: const Duration(milliseconds: 600),
                      child: SizedBox.square(
                        dimension: _grip,
                        child: CustomPaint(painter: _GripPainter(scheme.primary)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.box,
    required this.onDragStart,
    required this.onDrag,
    required this.onToggleOpacity,
    required this.onClose,
  });

  final PinnedBox box;
  final VoidCallback onDragStart;
  final GestureDragUpdateCallback onDrag;
  final VoidCallback onToggleOpacity;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const iconColor = Colors.white70;
    return Container(
      height: PinnedBox.headerHeight,
      color: const Color(0xFF2B2B2D),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onDragStart(),
              onPanUpdate: onDrag,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Tooltip(
                  message: 'Drag to move',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      const Icon(Icons.drag_indicator, size: 16, color: Colors.white38),
                      const SizedBox(width: 2),
                      const Icon(Icons.push_pin, size: 13, color: Color(0xFF8AB4F8)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          box.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _HeaderButton(
            tooltip: box.seeThrough ? 'Make opaque (100 %)' : 'Make see-through (75 %)',
            icon: box.seeThrough ? Icons.opacity : Icons.water_drop_outlined,
            color: box.seeThrough ? const Color(0xFF8AB4F8) : iconColor,
            onPressed: onToggleOpacity,
          ),
          _HeaderButton(tooltip: 'Unpin', icon: Icons.close, color: iconColor, onPressed: onClose),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.tooltip, required this.icon, required this.color, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon),
    iconSize: 16,
    color: color,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 28, height: PinnedBox.headerHeight),
  );
}

/// Three diagonal strokes in the bottom-right corner.
class _GripPainter extends CustomPainter {
  _GripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (final d in const [5.0, 10.0, 15.0]) {
      canvas.drawLine(Offset(size.width - 3, size.height - 3 - d), Offset(size.width - 3 - d, size.height - 3), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GripPainter old) => old.color != color;
}
