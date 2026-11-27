import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../editor/tools.dart';
import '../rust/geometry/sticky_note.dart';
import '../rust/geometry/stroke.dart';

/// Floating actions shown above (or below) the selection box. When strokes or shapes
/// are selected, a row of colour swatches below the actions recolours them.
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({super.key, required this.controller, required this.onEditNote, this.onPin});

  final EditorController controller;
  final void Function(StickyNote note) onEditNote;

  /// Pins a picture of the selection over the screen (shown only when set).
  final VoidCallback? onPin;

  /// Height of the actions row (the whole bar without swatches).
  static const double height = 48;
  static const double _swatchRowHeight = 34;
  static const double _approxWidth = 310;

  /// Height of the bar for the current selection of [controller].
  static double heightFor(EditorController controller) =>
      height + (controller.selectedStrokes.isEmpty ? 0 : _swatchRowHeight);

  /// Swatches offered for [strokes]: the highlighter colours when only highlighter ink is
  /// selected, the ink colours otherwise.
  static List<Color> swatchesFor(List<StrokeRender> strokes) =>
      strokes.isNotEmpty && strokes.every((s) => s.tool == ToolType.highlighter) ? kHighlighterSwatches : kInkSwatches;

  /// Positions the bar next to [selectionScreenRect], keeping it inside the canvas.
  static Widget positioned({
    required EditorController controller,
    required Rect selectionScreenRect,
    required Size canvasSize,
    required void Function(StickyNote note) onEditNote,
    VoidCallback? onPin,
  }) {
    final barHeight = heightFor(controller);
    final above = selectionScreenRect.top - barHeight - 10;
    final top = above >= 4
        ? above
        : (selectionScreenRect.bottom + 10).clamp(4.0, (canvasSize.height - barHeight - 4).clamp(4.0, double.infinity));
    final left = (selectionScreenRect.center.dx - _approxWidth / 2).clamp(
      4.0,
      (canvasSize.width - _approxWidth - 4).clamp(4.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top.toDouble(),
      child: SelectionActionBar(controller: controller, onEditNote: onEditNote, onPin: onPin),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = controller.singleSelectedNote;
    final count = controller.selectedIds.length;
    final strokes = controller.selectedStrokes;
    // The colour all selected strokes share, if they do (marked in the swatch row).
    final shared = strokes.isEmpty || strokes.any((s) => s.color != strokes.first.color) ? null : strokes.first.color;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
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
                  if (onPin != null)
                    IconButton(
                      tooltip: 'Pin to screen (stays in view while you scroll)',
                      icon: const Icon(Icons.push_pin_outlined),
                      onPressed: onPin,
                    ),
                  IconButton(
                    tooltip: 'Delete (Del)',
                    icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                    onPressed: controller.deleteSelection,
                  ),
                ],
              ),
            ),
            if (strokes.isNotEmpty)
              SizedBox(
                height: _swatchRowHeight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final color in swatchesFor(strokes))
                      _RecolorSwatch(
                        color: color,
                        selected: shared == color.toARGB32(),
                        onTap: () => controller.recolorSelection(color),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One colour of the selection bar's swatch row.
class _RecolorSwatch extends StatelessWidget {
  const _RecolorSwatch({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hex = color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();
    final ring = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Recolour selection #$hex',
      child: InkResponse(
        key: ValueKey('recolor-$hex'),
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: selected ? ring : const Color(0x55FFFFFF), width: selected ? 2.5 : 1),
            ),
          ),
        ),
      ),
    );
  }
}
