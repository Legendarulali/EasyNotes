import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/editor/editor_controller.dart';
import '../src/editor/tools.dart';

/// Bottom status bar: zoom, pan coordinates (`offset_x`, `offset_y` = world point at the
/// canvas' top-left corner), current page and a hint for the active tool.
///
/// Tapping it **only** resets the zoom to 100 %: the pan offsets are kept as they are
/// ([Viewport.resetZoom]), so the view never jumps back to (0, 0).
class CanvasStatusBar extends StatelessWidget {
  const CanvasStatusBar({super.key, required this.controller});

  static const double height = 30;

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Colors.white70,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dim = text?.copyWith(color: Colors.white38);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.viewport]),
      builder: (context, _) {
        final vp = controller.viewport;
        final zoom = (vp.scale * 100).round();
        final x = math.max(0, vp.scroll.dx.round());
        final y = math.max(0, vp.scroll.dy.round());
        final centerY = vp.scroll.dy + (vp.size.height / 2) / vp.scale;
        final page = controller.pageIndexAt(centerY);
        return Material(
          color: const Color(0xFF252526),
          child: InkWell(
            onTap: vp.resetZoom,
            child: Tooltip(
              message: 'Tap to reset the zoom to 100 % (keeps your position)',
              waitDuration: const Duration(milliseconds: 600),
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(zoom == 100 ? Icons.zoom_in : Icons.youtube_searched_for, size: 15, color: Colors.white54),
                      const SizedBox(width: 6),
                      Text('$zoom%', style: text),
                      const _Dot(),
                      Text('X $x  Y $y', style: text),
                      if (page != null) ...[
                        const _Dot(),
                        Text('Page ${page + 1} / ${controller.pages.length}', style: text),
                      ],
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          toolHint(controller.tool, controller.eraserMode),
                          style: dim,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 10),
    child: Text('·', style: TextStyle(color: Colors.white38)),
  );
}
