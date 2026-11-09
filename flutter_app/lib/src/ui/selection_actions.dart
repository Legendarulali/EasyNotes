import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../rust/geometry/sticky_note.dart';

/// Floating actions shown above (or below) the selection box.
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({super.key, required this.controller, required this.onEditNote});

  final EditorController controller;
  final void Function(StickyNote note) onEditNote;

  static const double height = 48;
  static const double _approxWidth = 260;

  /// Positions the bar next to [selectionScreenRect], keeping it inside the canvas.
  static Widget positioned({
    required EditorController controller,
    required Rect selectionScreenRect,
    required Size canvasSize,
    required void Function(StickyNote note) onEditNote,
  }) {
    final above = selectionScreenRect.top - height - 10;
    final top = above >= 4 ? above : (selectionScreenRect.bottom + 10).clamp(4.0, canvasSize.height - height - 4);
    final left = (selectionScreenRect.center.dx - _approxWidth / 2).clamp(
      4.0,
      (canvasSize.width - _approxWidth - 4).clamp(4.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top.toDouble(),
      child: SelectionActionBar(controller: controller, onEditNote: onEditNote),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = controller.singleSelectedNote;
    final count = controller.selectedIds.length;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('$count', style: Theme.of(context).textTheme.labelLarge),
              ),
              if (note != null)
                IconButton(tooltip: 'Edit note', icon: const Icon(Icons.edit_note), onPressed: () => onEditNote(note)),
              IconButton(
                tooltip: 'Duplicate (Ctrl+D)',
                icon: const Icon(Icons.control_point_duplicate),
                onPressed: controller.duplicateSelection,
              ),
              IconButton(tooltip: 'Copy (Ctrl+C)', icon: const Icon(Icons.copy), onPressed: controller.copySelection),
              IconButton(
                tooltip: 'Cut (Ctrl+X)',
                icon: const Icon(Icons.content_cut),
                onPressed: controller.cutSelection,
              ),
              IconButton(
                tooltip: 'Delete (Del)',
                icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                onPressed: controller.deleteSelection,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
