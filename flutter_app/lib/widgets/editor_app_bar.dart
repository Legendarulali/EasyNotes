import 'package:flutter/material.dart';

import '../src/editor/editor_controller.dart';
import '../src/editor/tools.dart';
import '../src/rust/document/paper.dart';

/// Slim dark top bar of the editor: back, title, paper style, input options, export.
/// Drawing tools live in the floating [DraggableToolbar].
class EditorAppBar extends StatelessWidget {
  const EditorAppBar({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onPaste,
    required this.onClear,
    required this.onExport,
    required this.exporting,
  });

  final EditorController controller;
  final VoidCallback onBack;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final VoidCallback onExport;
  final bool exporting;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return Material(
      color: const Color(0xFF252526),
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  tooltip: 'Back to library',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                ),
                Expanded(
                  child: Text(
                    controller.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                  ),
                ),
                if (controller.isOpen && controller.isPaged)
                  PopupMenuButton<PaperStyle>(
                    tooltip: 'Paper',
                    initialValue: controller.paperStyle,
                    onSelected: controller.setPaperStyle,
                    itemBuilder: (_) => [
                      for (final s in const [PaperStyle.dictando, PaperStyle.matematica, PaperStyle.whiteboard])
                        CheckedPopupMenuItem(value: s, checked: s == controller.paperStyle, child: Text(s.label)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Icon(controller.paperStyle.icon, size: 20, color: Colors.white70),
                          if (!compact) ...[
                            const SizedBox(width: 6),
                            Text(controller.paperStyle.label, style: const TextStyle(color: Colors.white70)),
                          ],
                          const Icon(Icons.arrow_drop_down, color: Colors.white54),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: controller.autoCorrect ? 'Shape auto-correct: ON' : 'Shape auto-correct: OFF',
                  isSelected: controller.autoCorrect,
                  icon: const Icon(Icons.crop_square),
                  selectedIcon: const Icon(Icons.auto_fix_high),
                  onPressed: () => controller.setAutoCorrect(!controller.autoCorrect),
                ),
                IconButton(
                  tooltip: controller.stylusOnly
                      ? 'Stylus only: fingers pan & zoom'
                      : 'Finger drawing: one finger draws, two fingers navigate',
                  isSelected: controller.stylusOnly,
                  icon: const Icon(Icons.touch_app_outlined),
                  selectedIcon: const Icon(Icons.do_not_touch_outlined),
                  onPressed: () => controller.setStylusOnly(!controller.stylusOnly),
                ),
                IconButton(
                  tooltip: 'Paste (Ctrl+V)',
                  icon: const Icon(Icons.content_paste),
                  onPressed: controller.hasClipboard ? onPaste : null,
                ),
                const SizedBox(width: 4),
                if (compact)
                  IconButton(
                    tooltip: 'Export PDF',
                    onPressed: exporting || !controller.isOpen ? null : onExport,
                    icon: exporting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_outlined),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: exporting || !controller.isOpen ? null : onExport,
                    icon: exporting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('Export PDF'),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'clear') onClear();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'clear',
                      child: ListTile(
                        leading: Icon(Icons.delete_sweep_outlined),
                        title: Text('Clear all ink & notes'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
