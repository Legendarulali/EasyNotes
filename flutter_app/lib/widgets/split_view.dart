import 'package:flutter/material.dart';

import '../src/editor/editor_controller.dart';
import '../src/editor/tools.dart';

const Color _accent = Color(0xFF8AB4F8);

/// Slim bar above each pane of the split screen: which notebook the pane shows, and
/// whether it is the focused pane (accent line and bright title) that the toolbar and
/// keyboard work on. Tapping it focuses the pane; the right pane's bar has the × that
/// closes the split.
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.controller, required this.focused, required this.onFocus, this.onClose});

  static const double height = 30;

  final EditorController controller;
  final bool focused;
  final VoidCallback onFocus;

  /// Closes the split screen (right pane only).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final foreground = focused ? Colors.white : Colors.white54;
      return Semantics(
        selected: focused,
        label: focused ? 'Focused pane: ${controller.title}' : 'Pane: ${controller.title}',
        child: Material(
          color: focused ? const Color(0xFF2D2D30) : const Color(0xFF232325),
          child: InkWell(
            onTap: onFocus,
            child: Container(
              height: height,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: focused ? _accent : Colors.transparent, width: 2)),
              ),
              padding: const EdgeInsets.only(left: 10, right: 2),
              child: Row(
                children: [
                  Icon(controller.entry.meta.kind.icon, size: 14, color: focused ? _accent : Colors.white38),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      controller.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12.5,
                        fontWeight: focused ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (onClose != null)
                    IconButton(
                      tooltip: 'Close split view',
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                      iconSize: 16,
                      color: foreground,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 26),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The bar between the two panes: drag it sideways to share the width differently,
/// double-click (or double-tap) it to go back to 50 / 50.
class SplitDivider extends StatelessWidget {
  const SplitDivider({super.key, required this.onDrag, required this.onReset});

  static const double width = 7;

  /// Horizontal movement in logical pixels.
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Drag to resize the panes · double-click for 50 / 50',
    waitDuration: const Duration(milliseconds: 900),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onDoubleTap: onReset,
        child: Container(
          width: width,
          color: const Color(0xFF141414),
          alignment: Alignment.center,
          child: Container(width: 1, color: Colors.white12),
        ),
      ),
    ),
  );
}

/// Drop targets over the canvas area for a tab dragged down out of the tab strip: the
/// right half opens it in the right pane (splitting the screen), the left half in the left
/// pane. They only light up under a dragged tab; otherwise pointers pass through.
class TabDropZones extends StatelessWidget {
  const TabDropZones({super.key, required this.split, required this.onDropLeft, required this.onDropRight});

  /// Whether the screen is split already (changes the labels).
  final bool split;
  final ValueChanged<EditorController> onDropLeft;
  final ValueChanged<EditorController> onDropRight;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _Zone(label: split ? 'Open in the left pane' : 'Open here', icon: Icons.tab, onDrop: onDropLeft),
      ),
      Expanded(
        child: _Zone(
          label: split ? 'Open in the right pane' : 'Split right',
          icon: Icons.vertical_split_outlined,
          onDrop: onDropRight,
        ),
      ),
    ],
  );
}

class _Zone extends StatelessWidget {
  const _Zone({required this.label, required this.icon, required this.onDrop});

  final String label;
  final IconData icon;
  final ValueChanged<EditorController> onDrop;

  @override
  Widget build(BuildContext context) => DragTarget<EditorController>(
    onAcceptWithDetails: (d) => onDrop(d.data),
    builder: (context, candidates, _) {
      if (candidates.isEmpty) return const SizedBox.expand();
      return Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.16),
          border: Border.all(color: _accent.withValues(alpha: 0.7), width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _accent, size: 32),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(color: _accent, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    },
  );
}
