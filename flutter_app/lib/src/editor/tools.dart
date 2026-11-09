import 'package:flutter/material.dart';

import '../rust/document/eraser.dart';
import '../rust/document/paper.dart';
import '../rust/geometry/stroke.dart';

/// Tools exposed in the toolbar. Ink tools map onto the Rust [ToolType]; the selection
/// tools are pure UI modes that call into the Rust selection engine.
enum EditorTool {
  pen('Pen', Icons.edit),
  pencil('Pencil', Icons.draw_outlined),
  highlighter('Highlighter', Icons.border_color),
  eraser('Eraser', Icons.cleaning_services_outlined),
  lasso('Lasso select', Icons.gesture),
  boxSelect('Box select', Icons.highlight_alt),
  stickyNote('Sticky note', Icons.sticky_note_2_outlined);

  const EditorTool(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get isInk => this == pen || this == pencil || this == highlighter;
  bool get isSelection => this == lasso || this == boxSelect;

  /// Engine tool for ink / eraser / sticky tools (`null` for selection modes).
  ToolType? get engineTool => switch (this) {
    pen => ToolType.pen,
    pencil => ToolType.pencil,
    highlighter => ToolType.highlighter,
    eraser => ToolType.eraser,
    stickyNote => ToolType.stickyNote,
    lasso || boxSelect => null,
  };
}

/// Colour + width remembered per tool.
@immutable
class BrushSettings {
  const BrushSettings({required this.color, required this.width, required this.opacity});

  final Color color;
  final double width;
  final double opacity;

  BrushSettings copyWith({Color? color, double? width, double? opacity}) =>
      BrushSettings(color: color ?? this.color, width: width ?? this.width, opacity: opacity ?? this.opacity);

  Brush toEngine() => Brush(color: color.toARGB32(), width: width, opacity: opacity);
}

/// Width slider range per tool (world units).
({double min, double max}) widthRangeFor(EditorTool tool) => switch (tool) {
  EditorTool.highlighter => (min: 8.0, max: 48.0),
  EditorTool.eraser => (min: 8.0, max: 80.0),
  _ => (min: 0.8, max: 16.0),
};

const Map<EditorTool, BrushSettings> kDefaultBrushes = {
  EditorTool.pen: BrushSettings(color: Color(0xFF1A1A1A), width: 2.6, opacity: 1.0),
  EditorTool.pencil: BrushSettings(color: Color(0xFF4A4A4A), width: 2.4, opacity: 0.9),
  EditorTool.highlighter: BrushSettings(color: Color(0xFFFFEB3B), width: 18, opacity: 0.4),
  EditorTool.eraser: BrushSettings(color: Color(0xFF000000), width: 24, opacity: 1.0),
};

/// Swatches shown in the palette bar.
const List<Color> kInkSwatches = [
  Color(0xFF1A1A1A),
  Color(0xFF1E40AF),
  Color(0xFFD32F2F),
  Color(0xFF2E7D32),
  Color(0xFF6A1B9A),
  Color(0xFFEF6C00),
  Color(0xFF00838F),
  Color(0xFF795548),
];

const List<Color> kHighlighterSwatches = [
  Color(0xFFFFEB3B),
  Color(0xFF76FF03),
  Color(0xFF40C4FF),
  Color(0xFFFF80AB),
  Color(0xFFFFAB40),
  Color(0xFFB388FF),
];

const List<Color> kStickySwatches = [
  Color(0xFFFFF59D),
  Color(0xFFFFCC80),
  Color(0xFFA5D6A7),
  Color(0xFF90CAF9),
  Color(0xFFF48FB1),
  Color(0xFFE1BEE7),
];

/// Display names of the paper patterns (English UI: Dictando → Ruled, Matematică → Grid).
extension PaperStyleLabel on PaperStyle {
  String get label => switch (this) {
    PaperStyle.whiteboard => 'Blank',
    PaperStyle.dictando => 'Ruled',
    PaperStyle.matematica => 'Grid',
  };

  IconData get icon => switch (this) {
    PaperStyle.whiteboard => Icons.crop_portrait,
    PaperStyle.dictando => Icons.format_align_justify,
    PaperStyle.matematica => Icons.grid_on,
  };
}

extension EraserModeLabel on EraserMode {
  String get label => switch (this) {
    EraserMode.stroke => 'Stroke eraser',
    EraserMode.partial => 'Classic eraser',
  };

  String get hint => switch (this) {
    EraserMode.stroke => 'Deletes whole strokes on contact',
    EraserMode.partial => 'Erases only what it passes over, splitting strokes',
  };

  IconData get icon => switch (this) {
    EraserMode.stroke => Icons.auto_delete_outlined,
    EraserMode.partial => Icons.content_cut,
  };
}

/// One-line usage hint for the status bar.
String toolHint(EditorTool tool, EraserMode eraser) => switch (tool) {
  EditorTool.pen || EditorTool.pencil || EditorTool.highlighter => 'Draw a closed box to snap it into a rectangle',
  EditorTool.eraser => eraser.hint,
  EditorTool.lasso || EditorTool.boxSelect => 'Drag to select · drag the box to move · corners resize (Shift keeps ratio)',
  EditorTool.stickyNote => 'Tap to add · drag to move · drag the corner to resize · tap to edit',
};
