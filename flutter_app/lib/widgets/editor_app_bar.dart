import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../src/editor/editor_controller.dart';
import '../src/editor/open_notebooks.dart';
import '../src/editor/tools.dart';
import '../src/rust/document/paper.dart';
import '../src/services/library_service.dart';

const Color _chrome = Color(0xFF252526);
const Color _activeTab = Color(0xFF37373C);
const Color _otherPaneTab = Color(0xFF2E2E32);
const Color _accent = Color(0xFF8AB4F8);

/// Slim dark top bar of the editor: Home, the tabs of the open notebooks (+ quick open),
/// the split-screen toggle, then the focused notebook's paper style, input options and
/// export. Drawing tools live in the floating [DraggableToolbar].
class EditorAppBar extends StatelessWidget {
  const EditorAppBar({
    super.key,
    required this.tabs,
    required this.onHome,
    required this.onCloseTab,
    required this.onPaste,
    required this.onClear,
    required this.onExport,
    required this.exporting,
  });

  final OpenNotebooks tabs;

  /// Back to the library; the tabs stay open.
  final VoidCallback onHome;
  final ValueChanged<EditorController> onCloseTab;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final VoidCallback onExport;
  final bool exporting;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 640;
    // Phones in portrait: with Android's 48 dp buttons every action would leave the
    // tabs no room at all, so paper, paste and export move into "More".
    final narrow = width < 600;
    final controller = tabs.focused;
    return Material(
      color: _chrome,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(tooltip: 'Home', icon: const Icon(Icons.home_outlined), onPressed: onHome),
              Expanded(
                child: NotebookTabBar(tabs: tabs, compact: compact, onClose: onCloseTab, onBrowse: onHome),
              ),
              if (controller != null)
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => _actions(context, controller, compact: compact, narrow: narrow),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String get splitShortcut => _isApple ? '⌘\\' : 'Ctrl+\\';

  static bool get _isApple =>
      defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;

  void _toggleSplit() => tabs.isSplit ? tabs.closeSplit() : tabs.splitRight();

  Widget _actions(BuildContext context, EditorController controller, {required bool compact, required bool narrow}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!compact)
        IconButton(
          tooltip: tabs.isSplit ? 'Close split view ($splitShortcut)' : 'Split view ($splitShortcut)',
          isSelected: tabs.isSplit,
          icon: const Icon(Icons.vertical_split_outlined),
          selectedIcon: const Icon(Icons.vertical_split),
          onPressed: _toggleSplit,
        ),
      if (!narrow && controller.isOpen && controller.isPaged)
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
      if (!narrow)
        IconButton(
          tooltip: 'Paste (Ctrl+V)',
          icon: const Icon(Icons.content_paste),
          onPressed: controller.hasClipboard ? onPaste : null,
        ),
      const SizedBox(width: 4),
      if (narrow)
        // Export is in "More" here; still show that one is running.
        ...[
          if (exporting)
            const Tooltip(
              message: 'Exporting PDF…',
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ]
      else if (compact)
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
      PopupMenuButton<Object>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert),
        onSelected: (v) {
          switch (v) {
            case final PaperStyle style:
              controller.setPaperStyle(style);
            case _MoreAction.paste:
              onPaste();
            case _MoreAction.export:
              onExport();
            case _MoreAction.split:
              _toggleSplit();
            case _MoreAction.clear:
              onClear();
          }
        },
        itemBuilder: (context) => [
          if (narrow && controller.isOpen && controller.isPaged) ...[
            PopupMenuItem<Object>(
              enabled: false,
              height: 32,
              child: Text('Paper', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white54)),
            ),
            for (final s in const [PaperStyle.dictando, PaperStyle.matematica, PaperStyle.whiteboard])
              CheckedPopupMenuItem<Object>(value: s, checked: s == controller.paperStyle, child: Text(s.label)),
            const PopupMenuDivider(),
          ],
          if (narrow) ...[
            PopupMenuItem<Object>(
              value: _MoreAction.paste,
              enabled: controller.hasClipboard,
              child: const ListTile(
                leading: Icon(Icons.content_paste),
                title: Text('Paste'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem<Object>(
              value: _MoreAction.export,
              enabled: !exporting && controller.isOpen,
              child: const ListTile(
                leading: Icon(Icons.picture_as_pdf_outlined),
                title: Text('Export PDF'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
          if (compact)
            PopupMenuItem<Object>(
              value: _MoreAction.split,
              child: ListTile(
                leading: const Icon(Icons.vertical_split_outlined),
                title: Text(tabs.isSplit ? 'Close split view' : 'Split view'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          const PopupMenuItem<Object>(
            value: _MoreAction.clear,
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
  );
}

/// Entries of the editor's "More" menu (besides the paper styles on phones).
enum _MoreAction { paste, export, split, clear }

/// The open notebooks as a horizontal strip of tabs: tap one to show it (in the focused
/// pane of a split screen), × (or a middle click) to close it, `+` to open another
/// notebook from the library or jump to an open one. Right-click / long-press a tab for
/// "Split right"; dragging a tab down onto the right half of the canvas does the same.
/// Scrolls sideways (also with the mouse wheel) when the tabs do not fit, and keeps the
/// focused tab in view.
class NotebookTabBar extends StatefulWidget {
  const NotebookTabBar({
    super.key,
    required this.tabs,
    required this.onClose,
    required this.onBrowse,
    this.compact = false,
  });

  final OpenNotebooks tabs;
  final ValueChanged<EditorController> onClose;

  /// "Browse the library…" in the `+` menu.
  final VoidCallback onBrowse;
  final bool compact;

  @override
  State<NotebookTabBar> createState() => _NotebookTabBarState();
}

class _NotebookTabBarState extends State<NotebookTabBar> {
  final ScrollController _scroll = ScrollController();
  final Map<EditorController, GlobalKey> _keys = {};
  EditorController? _revealed;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the newly focused tab into view (as little as possible).
  void _revealActive() {
    final active = widget.tabs.focused;
    if (active == null || identical(active, _revealed)) return;
    _revealed = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = _keys[active]?.currentContext;
      if (!mounted || tab == null) return;
      Scrollable.ensureVisible(tab, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(tab, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

  /// A vertical mouse wheel scrolls the strip sideways.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients || e.scrollDelta.dy == 0) return;
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + e.scrollDelta.dy).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.tabs,
    builder: (context, _) {
      final open = widget.tabs;
      final tabs = open.tabs;
      final focused = open.focused;
      _keys.removeWhere((c, _) => !tabs.contains(c));
      _revealActive();
      return Row(
        children: [
          Flexible(
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final c in tabs)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: _draggable(
                          c,
                          NotebookTab(
                            key: _keys.putIfAbsent(c, () => GlobalKey()),
                            controller: c,
                            active: identical(c, focused),
                            shownInOtherPane: !identical(c, focused) && open.isShown(c),
                            maxTitleWidth: widget.compact ? 110 : 190,
                            onSelect: () => open.activate(open.tabs.indexOf(c)),
                            onClose: () => widget.onClose(c),
                            onContextMenu: () => _showTabMenu(c),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          _QuickOpenButton(tabs: widget.tabs, onBrowse: widget.onBrowse),
        ],
      );
    },
  );

  /// A tab pulled *down* out of the strip can be dropped on a pane (sideways drags still
  /// scroll the strip).
  Widget _draggable(EditorController c, Widget tab) => Draggable<EditorController>(
    data: c,
    affinity: Axis.vertical,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: _TabDragFeedback(controller: c),
    childWhenDragging: Opacity(opacity: 0.45, child: tab),
    child: tab,
  );

  Future<void> _showTabMenu(EditorController c) async {
    final tabContext = _keys[c]?.currentContext;
    if (tabContext == null) return;
    final open = widget.tabs;
    final box = tabContext.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final below = Offset(0, box.size.height);
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(below, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero) + below, ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final inRight = identical(c, open.split);
    final choice = await showMenu<_TabAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: _TabAction.splitRight,
          enabled: !inRight,
          child: const ListTile(
            leading: Icon(Icons.vertical_split_outlined),
            title: Text('Split right'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
        if (open.isSplit && !identical(c, open.active))
          const PopupMenuItem(
            value: _TabAction.openLeft,
            child: ListTile(
              leading: Icon(Icons.tab),
              title: Text('Open in the left pane'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _TabAction.close,
          child: ListTile(
            leading: Icon(Icons.close),
            title: Text('Close tab'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      ],
    );
    if (!mounted || !open.tabs.contains(c)) return;
    switch (choice) {
      case _TabAction.splitRight:
        open.splitRight(c);
      case _TabAction.openLeft:
        open
          ..focusPane(EditorPane.primary)
          ..activate(open.tabs.indexOf(c));
      case _TabAction.close:
        widget.onClose(c);
      case null:
        break;
    }
  }
}

enum _TabAction { splitRight, openLeft, close }

/// What follows the pointer while a tab is dragged onto a pane.
class _TabDragFeedback extends StatelessWidget {
  const _TabDragFeedback({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) => Material(
    color: _activeTab,
    elevation: 8,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(controller.entry.meta.kind.icon, size: 16, color: _accent),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              controller.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
            ),
          ),
        ],
      ),
    ),
  );
}

/// One tab: notebook kind (a spinner while it loads), title and a close button.
class NotebookTab extends StatelessWidget {
  const NotebookTab({
    super.key,
    required this.controller,
    required this.active,
    required this.onSelect,
    required this.onClose,
    this.shownInOtherPane = false,
    this.onContextMenu,
    this.maxTitleWidth = 190,
  });

  final EditorController controller;

  /// Shown in the focused pane.
  final bool active;

  /// Shown in the other pane of the split screen (dimmer underline).
  final bool shownInOtherPane;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  /// Right click or long press.
  final VoidCallback? onContextMenu;
  final double maxTitleWidth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final title = controller.title;
      final foreground = active ? Colors.white : Colors.white60;
      final Widget leading = controller.openError != null
          ? const Icon(Icons.error_outline, size: 16, color: Colors.redAccent)
          : !controller.isOpen
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
          : Icon(controller.entry.meta.kind.icon, size: 16, color: active ? _accent : Colors.white54);
      return Listener(
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton) onClose();
        },
        child: Semantics(
          selected: active,
          child: Material(
            color: active
                ? _activeTab
                : shownInOtherPane
                ? _otherPaneTab
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onSelect,
              onSecondaryTap: onContextMenu,
              onLongPress: onContextMenu,
              child: Container(
                height: 36,
                padding: const EdgeInsets.only(left: 10, right: 2),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active
                          ? _accent
                          : shownInOtherPane
                          ? _accent.withValues(alpha: 0.35)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: title,
                      waitDuration: const Duration(milliseconds: 700),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          leading,
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxTitleWidth),
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 13.5,
                                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      tooltip: 'Close tab',
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                      iconSize: 16,
                      color: foreground,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
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

enum _QuickOpenAction { browse }

/// `+` next to the tabs: the most recently edited notebooks of the whole library (open
/// ones are marked; picking one switches to its tab) and a way back to the library.
class _QuickOpenButton extends StatelessWidget {
  const _QuickOpenButton({required this.tabs, required this.onBrowse});

  final OpenNotebooks tabs;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Open a notebook in a new tab',
    icon: const Icon(Icons.add),
    onPressed: () => _show(context),
  );

  Future<void> _show(BuildContext context) async {
    final library = tabs.library;
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final below = Offset(0, button.size.height);
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(below, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero) + below, ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final recent = await library.recentNotebooks(limit: 10);
    if (!context.mounted) return;
    final label = Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white54);
    final choice = await showMenu<Object>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<Object>(enabled: false, height: 32, child: Text('Recent notebooks', style: label)),
        if (recent.isEmpty)
          const PopupMenuItem<Object>(enabled: false, child: Text('No other notebooks yet')),
        for (final e in recent)
          PopupMenuItem<Object>(
            value: e,
            child: _RecentNotebook(entry: e, folder: _folderLabel(library, e), open: tabs.tabOf(e) != null),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: _QuickOpenAction.browse,
          child: ListTile(
            leading: Icon(Icons.home_outlined),
            title: Text('Browse the library…'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      ],
    );
    switch (choice) {
      case NotebookEntry():
        tabs.open(choice);
      case _QuickOpenAction.browse:
        onBrowse();
    }
  }

  static String _folderLabel(LibraryService library, NotebookEntry e) {
    final crumbs = library.breadcrumbs(e.dir.parent);
    return crumbs.isEmpty ? 'Library' : crumbs.join(' › ');
  }
}

class _RecentNotebook extends StatelessWidget {
  const _RecentNotebook({required this.entry, required this.folder, required this.open});

  final NotebookEntry entry;
  final String folder;
  final bool open;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(entry.meta.kind.icon),
    title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: open ? const Text('open', style: TextStyle(color: _accent, fontSize: 12)) : null,
    contentPadding: EdgeInsets.zero,
    dense: true,
  );
}
