import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/editor/editor_controller.dart';
import '../src/editor/tools.dart';
import '../src/rust/document/eraser.dart';
import '../src/ui/color_picker_dialog.dart';

/// Where the floating toolbar is parked.
enum ToolbarDock {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,

  /// Free position wherever the user dropped it.
  floating;

  /// Docked on a side edge → laid out vertically; everywhere else horizontally.
  Axis get axis => this == left || this == right ? Axis.vertical : Axis.horizontal;
}

/// Saved toolbar placement (floating offsets are fractions of the canvas size so they
/// survive window resizes and rotation).
@immutable
class ToolbarPlacement {
  const ToolbarPlacement(this.dock, [this.fraction = Offset.zero]);

  final ToolbarDock dock;
  final Offset fraction;

  static const ToolbarPlacement initial = ToolbarPlacement(ToolbarDock.top);

  @override
  bool operator ==(Object other) => other is ToolbarPlacement && other.dock == dock && other.fraction == fraction;

  @override
  int get hashCode => Object.hash(dock, fraction);

  Map<String, Object?> toJson() => {'toolbarDock': dock.name, 'toolbarX': fraction.dx, 'toolbarY': fraction.dy};

  static ToolbarPlacement fromJson(Map<String, Object?> j) {
    final dock = ToolbarDock.values.where((d) => d.name == j['toolbarDock']).firstOrNull;
    if (dock == null) return initial;
    final x = (j['toolbarX'] as num?)?.toDouble() ?? 0;
    final y = (j['toolbarY'] as num?)?.toDouble() ?? 0;
    return ToolbarPlacement(dock, Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)));
  }
}

/// Snapping rule: a toolbar dropped within [threshold] of the canvas edges docks there
/// (corners win over edges); anywhere else it stays floating.
ToolbarDock snapDock(Rect toolbar, Size bounds, {double threshold = 56}) {
  final nearLeft = toolbar.left <= threshold;
  final nearRight = bounds.width - toolbar.right <= threshold;
  final nearTop = toolbar.top <= threshold;
  final nearBottom = bounds.height - toolbar.bottom <= threshold;
  if (nearTop && nearLeft) return ToolbarDock.topLeft;
  if (nearTop && nearRight) return ToolbarDock.topRight;
  if (nearBottom && nearLeft) return ToolbarDock.bottomLeft;
  if (nearBottom && nearRight) return ToolbarDock.bottomRight;
  if (nearTop) return ToolbarDock.top;
  if (nearBottom) return ToolbarDock.bottom;
  if (nearLeft) return ToolbarDock.left;
  if (nearRight) return ToolbarDock.right;
  return ToolbarDock.floating;
}

/// Top-left corner of a toolbar of [size] placed at [placement] inside [bounds].
Offset dockOffset(ToolbarPlacement placement, Size size, Size bounds, {double margin = 12}) {
  final maxX = math.max(margin, bounds.width - size.width - margin);
  final maxY = math.max(margin, bounds.height - size.height - margin);
  final cx = math.max(margin, (bounds.width - size.width) / 2);
  final cy = math.max(margin, (bounds.height - size.height) / 2);
  return switch (placement.dock) {
    ToolbarDock.top => Offset(cx, margin),
    ToolbarDock.bottom => Offset(cx, maxY),
    ToolbarDock.left => Offset(margin, cy),
    ToolbarDock.right => Offset(maxX, cy),
    ToolbarDock.topLeft => Offset(margin, margin),
    ToolbarDock.topRight => Offset(maxX, margin),
    ToolbarDock.bottomLeft => Offset(margin, maxY),
    ToolbarDock.bottomRight => Offset(maxX, maxY),
    ToolbarDock.floating => Offset(
      (placement.fraction.dx * (bounds.width - size.width)).clamp(0.0, math.max(0.0, bounds.width - size.width)),
      (placement.fraction.dy * (bounds.height - size.height)).clamp(0.0, math.max(0.0, bounds.height - size.height)),
    ),
  };
}

/// Band of the canvas covered by a toolbar of [size] at [dock], as insets from the canvas
/// edges (dock margin + toolbar + [gap]). The canvas keeps its content out of this band at
/// the scroll limits, so e.g. the top of page 1 rests below a top-docked toolbar.
/// A floating toolbar can be anywhere and reserves nothing.
EdgeInsets toolbarObstruction(ToolbarDock dock, Size size, {double margin = 12, double gap = 12}) {
  final h = margin + size.height + gap;
  final w = margin + size.width + gap;
  return switch (dock) {
    ToolbarDock.top || ToolbarDock.topLeft || ToolbarDock.topRight => EdgeInsets.only(top: h),
    ToolbarDock.bottom || ToolbarDock.bottomLeft || ToolbarDock.bottomRight => EdgeInsets.only(bottom: h),
    ToolbarDock.left => EdgeInsets.only(left: w),
    ToolbarDock.right => EdgeInsets.only(right: w),
    ToolbarDock.floating => EdgeInsets.zero,
  };
}

/// Detachable floating toolbar: tool picker, colour palette (+ custom hex colour),
/// thickness slider and eraser mode. Drag it by its grip anywhere over the canvas;
/// released near an edge or corner it snaps there (vertical layout on the left / right
/// edges), otherwise it stays where it was dropped.
///
/// Must be placed directly inside a [Stack] covering the canvas ([bounds] = its size).
class DraggableToolbar extends StatefulWidget {
  const DraggableToolbar({
    super.key,
    required this.controller,
    required this.bounds,
    this.placement = ToolbarPlacement.initial,
    this.onPlacementChanged,
    this.onObstructionChanged,
  });

  final EditorController controller;
  final Size bounds;
  final ToolbarPlacement placement;
  final ValueChanged<ToolbarPlacement>? onPlacementChanged;

  /// Reports the canvas band hidden behind the docked toolbar ([toolbarObstruction])
  /// whenever it changes (after layout, never mid-drag).
  final ValueChanged<EdgeInsets>? onObstructionChanged;

  @override
  State<DraggableToolbar> createState() => _DraggableToolbarState();
}

class _DraggableToolbarState extends State<DraggableToolbar> {
  final GlobalKey _panelKey = GlobalKey();
  late ToolbarPlacement _placement = widget.placement;
  Size _size = const Size(320, 56);
  Offset? _drag; // top-left while dragging
  Axis? _dragAxis;
  bool _collapsed = false;

  @override
  void didUpdateWidget(DraggableToolbar old) {
    super.didUpdateWidget(old);
    if (old.placement != widget.placement && _drag == null) _placement = widget.placement;
  }

  EdgeInsets? _reported;

  void _measure() {
    if (!mounted) return;
    final size = _panelKey.currentContext?.size;
    if (size != null && size != _size) setState(() => _size = size);
    if (_drag == null && size != null) {
      final band = toolbarObstruction(_placement.dock, size);
      if (band != _reported) {
        _reported = band;
        widget.onObstructionChanged?.call(band);
      }
    }
  }

  void _onDragStart(DragStartDetails d) {
    setState(() {
      _drag = dockOffset(_placement, _size, widget.bounds);
      _dragAxis = _placement.dock.axis;
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final b = widget.bounds;
    final next = (_drag ?? Offset.zero) + d.delta;
    setState(
      () => _drag = Offset(
        next.dx.clamp(0.0, math.max(0.0, b.width - _size.width)),
        next.dy.clamp(0.0, math.max(0.0, b.height - _size.height)),
      ),
    );
  }

  void _onDragEnd([DragEndDetails? _]) {
    final pos = _drag;
    if (pos == null) return;
    final b = widget.bounds;
    final dock = snapDock(pos & _size, b);
    final free = Offset(
      b.width > _size.width ? pos.dx / (b.width - _size.width) : 0,
      b.height > _size.height ? pos.dy / (b.height - _size.height) : 0,
    );
    final placement = ToolbarPlacement(dock, dock == ToolbarDock.floating ? free : Offset.zero);
    setState(() {
      _placement = placement;
      _drag = null;
      _dragAxis = null;
    });
    widget.onPlacementChanged?.call(placement);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final b = widget.bounds;
    final dragging = _drag != null;
    final axis = _dragAxis ?? _placement.dock.axis;
    final pos = _drag ?? dockOffset(_placement, _size, b);
    final target = dragging ? snapDock(_drag! & _size, b) : null;
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (target != null && target != ToolbarDock.floating) _SnapHint(dock: target, bounds: b),
          AnimatedPositioned(
            duration: dragging ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: pos.dx,
            top: pos.dy,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(120, b.width - 24),
                maxHeight: math.max(120, b.height - 24),
              ),
              child: _ToolbarPanel(
                key: _panelKey,
                controller: widget.controller,
                axis: axis,
                collapsed: _collapsed,
                lifted: dragging,
                onToggleCollapsed: () => setState(() => _collapsed = !_collapsed),
                onDragStart: _onDragStart,
                onDragUpdate: _onDragUpdate,
                onDragEnd: _onDragEnd,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glow along the edge / corner the toolbar will snap to.
class _SnapHint extends StatelessWidget {
  const _SnapHint({required this.dock, required this.bounds});

  final ToolbarDock dock;
  final Size bounds;

  @override
  Widget build(BuildContext context) {
    const t = 6.0;
    const corner = 72.0;
    final accent = Theme.of(context).colorScheme.primary.withValues(alpha: 0.45);
    final rect = switch (dock) {
      ToolbarDock.top => Rect.fromLTWH(0, 0, bounds.width, t),
      ToolbarDock.bottom => Rect.fromLTWH(0, bounds.height - t, bounds.width, t),
      ToolbarDock.left => Rect.fromLTWH(0, 0, t, bounds.height),
      ToolbarDock.right => Rect.fromLTWH(bounds.width - t, 0, t, bounds.height),
      ToolbarDock.topLeft => const Rect.fromLTWH(0, 0, corner, corner),
      ToolbarDock.topRight => Rect.fromLTWH(bounds.width - corner, 0, corner, corner),
      ToolbarDock.bottomLeft => Rect.fromLTWH(0, bounds.height - corner, corner, corner),
      ToolbarDock.bottomRight => Rect.fromLTWH(bounds.width - corner, bounds.height - corner, corner, corner),
      ToolbarDock.floating => Rect.zero,
    };
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(t)),
        ),
      ),
    );
  }
}

class _ToolbarPanel extends StatelessWidget {
  const _ToolbarPanel({
    super.key,
    required this.controller,
    required this.axis,
    required this.collapsed,
    required this.lifted,
    required this.onToggleCollapsed,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final EditorController controller;
  final Axis axis;
  final bool collapsed;
  final bool lifted;
  final VoidCallback onToggleCollapsed;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    return Material(
      color: const Color(0xFF2B2B2D),
      elevation: lifted ? 14 : 6,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: onDragStart,
                onPanUpdate: onDragUpdate,
                onPanEnd: onDragEnd,
                onPanCancel: () => onDragEnd(DragEndDetails()),
                child: MouseRegion(
                  cursor: lifted ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
                  child: Tooltip(
                    message: 'Drag to move the toolbar',
                    child: SizedBox(
                      width: vertical ? 44 : 22,
                      height: vertical ? 22 : 44,
                      child: Icon(
                        vertical ? Icons.drag_handle : Icons.drag_indicator,
                        size: 18,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                ),
              ),
              if (collapsed)
                _ToolButton(
                  tool: controller.tool,
                  selected: true,
                  color: controller.tool.isInk ? controller.brushFor(controller.tool).color : null,
                  onTap: onToggleCollapsed,
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: axis,
                    child: Flex(
                      direction: axis,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final tool in EditorTool.values)
                          _ToolButton(
                            tool: tool,
                            selected: controller.tool == tool,
                            color: tool.isInk ? controller.brushFor(tool).color : null,
                            onTap: () => controller.selectTool(tool),
                          ),
                        ..._optionsFor(context, vertical),
                      ],
                    ),
                  ),
                ),
              _IconChip(
                icon: collapsed
                    ? (vertical ? Icons.expand_more : Icons.chevron_right)
                    : (vertical ? Icons.expand_less : Icons.chevron_left),
                tooltip: collapsed ? 'Expand toolbar' : 'Collapse toolbar',
                onTap: onToggleCollapsed,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _optionsFor(BuildContext context, bool vertical) {
    final tool = controller.tool;
    final out = <Widget>[];
    if (tool.isInk || tool == EditorTool.stickyNote) {
      final swatches = switch (tool) {
        EditorTool.highlighter => kHighlighterSwatches,
        EditorTool.stickyNote => kStickySwatches,
        _ => kInkSwatches,
      };
      final active = controller.activeColor;
      final colors = [
        for (final c in swatches)
          _Swatch(color: c, selected: c.toARGB32() == active.toARGB32(), onTap: () => controller.setColor(c)),
        _CustomColorButton(
          color: active,
          isCustom: !swatches.any((c) => c.toARGB32() == active.toARGB32()),
          onPicked: controller.setColor,
        ),
      ];
      out.add(_Separator(axis: axis));
      if (vertical) {
        // Two columns keep the vertical toolbar short enough for laptop screens.
        out.add(SizedBox(width: 72, child: Wrap(alignment: WrapAlignment.center, children: colors)));
      } else {
        out.addAll(colors);
      }
    }
    if (tool == EditorTool.eraser) {
      out.add(_Separator(axis: axis));
      for (final mode in EraserMode.values) {
        out.add(
          _IconChip(
            icon: mode.icon,
            tooltip: '${mode.label}: ${mode.hint}',
            selected: controller.eraserMode == mode,
            onTap: () => controller.setEraserMode(mode),
          ),
        );
      }
    }
    if (tool.isInk || tool == EditorTool.eraser) {
      out
        ..add(_Separator(axis: axis))
        ..add(_WidthControl(controller: controller, tool: tool, vertical: vertical));
    }
    return out;
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.tool, required this.selected, required this.onTap, this.color});

  final EditorTool tool;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: tool.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: selected ? scheme.primary.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(tool.icon, size: 22, color: selected ? scheme.primary : Colors.white70),
                if (color != null)
                  Positioned(
                    bottom: 5,
                    child: Container(
                      width: 16,
                      height: 4,
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.tooltip, required this.onTap, this.selected = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: selected ? scheme.primary.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: selected ? scheme.primary : Colors.white60),
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator({required this.axis});

  final Axis axis;

  @override
  Widget build(BuildContext context) => Container(
    width: axis == Axis.horizontal ? 1 : 28,
    height: axis == Axis.horizontal ? 28 : 1,
    margin: const EdgeInsets.all(6),
    color: Colors.white12,
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 34,
      height: 34,
      child: Center(
        child: InkResponse(
          onTap: onTap,
          radius: 18,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: selected ? 28 : 22,
            height: selected ? 28 : 22,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: selected ? scheme.primary : Colors.white24, width: selected ? 3 : 1),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomColorButton extends StatelessWidget {
  const _CustomColorButton({required this.color, required this.isCustom, required this.onPicked});

  final Color color;
  final bool isCustom;
  final ValueChanged<Color> onPicked;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Center(
        child: Tooltip(
          message: 'Custom colour (hex)',
          child: InkResponse(
            radius: 18,
            onTap: () async {
              final picked = await showColorPickerDialog(context, initial: color);
              if (picked != null) onPicked(picked);
            },
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isCustom
                    ? null
                    : const SweepGradient(
                        colors: [
                          Colors.red,
                          Colors.yellow,
                          Colors.green,
                          Colors.cyan,
                          Colors.blue,
                          Colors.purple,
                          Colors.red,
                        ],
                      ),
                color: isCustom ? color : null,
                border: Border.all(color: Colors.white54, width: isCustom ? 3 : 1),
              ),
              child: const Icon(Icons.add, size: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thickness slider (rotated when the toolbar is vertical) with a live size preview.
class _WidthControl extends StatelessWidget {
  const _WidthControl({required this.controller, required this.tool, required this.vertical});

  final EditorController controller;
  final EditorTool tool;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final brush = controller.brushFor(tool);
    final range = widthRangeFor(tool);
    final previewSize = brush.width.clamp(2.0, 24.0);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
      // Slider fills any bounded height it is given, so pin both dimensions.
      child: SizedBox(
        width: 132,
        height: 36,
        child: Slider(
          value: brush.width.clamp(range.min, range.max),
          min: range.min,
          max: range.max,
          onChanged: controller.setWidth,
        ),
      ),
    );
    final preview = Tooltip(
      message: '${brush.width.toStringAsFixed(1)} px',
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Container(
            width: previewSize,
            height: previewSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tool == EditorTool.eraser ? null : brush.color.withValues(alpha: brush.opacity),
              border: tool == EditorTool.eraser ? Border.all(color: Colors.white60) : Border.all(color: Colors.white24),
            ),
          ),
        ),
      ),
    );
    return Flex(
      direction: vertical ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: vertical ? RotatedBox(quarterTurns: 3, child: slider) : slider,
        ),
        preview,
      ],
    );
  }
}
