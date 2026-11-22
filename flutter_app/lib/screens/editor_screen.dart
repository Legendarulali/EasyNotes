import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/canvas/note_canvas.dart';
import '../src/canvas/painters.dart';
import '../src/canvas/scene_cache.dart';
import '../src/canvas/viewport.dart' as canvas;
import '../src/editor/editor_controller.dart';
import '../src/editor/open_notebooks.dart';
import '../src/editor/pin_board.dart';
import '../src/rust/geometry/sticky_note.dart';
import '../src/services/library_service.dart';
import '../src/services/pdf_export_service.dart';
import '../src/sync/sync_service.dart';
import '../src/ui/sticky_note_dialog.dart';
import '../widgets/canvas_status_bar.dart';
import '../widgets/draggable_toolbar.dart';
import '../widgets/editor_app_bar.dart';
import '../widgets/pinned_overlay.dart';
import '../widgets/split_view.dart';

/// The editor: dark chrome with the tabs of the open notebooks, then the canvas with the
/// floating toolbar and the status bar. Edits autosave. Home (or the back button /
/// gesture) saves every tab and returns to the library, where the tabs stay open; closing
/// the last tab returns there too.
///
/// The canvas can be split into two panes (the toolbar's split button, Ctrl+\, a tab's
/// "Split right", or dragging a tab onto the right half): two notebooks side by side, or
/// the same notebook twice, each pane with its own scroll position, zoom and page. The
/// toolbar is shared and works on the focused pane, the one last touched. Snapshots pinned
/// from a selection float above both panes.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.tabs});

  final OpenNotebooks tabs;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  OpenNotebooks get tabs => widget.tabs;
  LibraryService get library => tabs.library;

  /// Cloud backup: notebooks are uploaded when a tab closes and when the library is shown.
  SyncService get sync => tabs.sync;

  /// Narrowest a split pane gets, however the divider is dragged.
  static const double _minPaneWidth = 240;

  late final AppLifecycleListener _lifecycle;
  ToolbarPlacement _placement = ToolbarPlacement.initial;

  /// Canvas band behind the docked toolbar; the panes' views keep clear of it.
  EdgeInsets? _toolbarBand;

  /// One edit gesture at a time across the panes (palm rejection between them).
  final CanvasInputGate _gate = CanvasInputGate();

  /// Size of the canvas area (both panes), from the last layout.
  Size _canvasArea = Size.zero;
  bool _exporting = false;
  bool _leaving = false;
  bool _pinning = false;

  @override
  void initState() {
    super.initState();
    // Hiding / exiting the app runs SyncService.flush(), which awaits every tab's saver
    // before uploading; pause / detach (mobile) save directly.
    _lifecycle = AppLifecycleListener(onPause: _saveQuietly, onDetach: _saveQuietly);
    tabs.onMessage = _toast;
    tabs.addListener(_onTabsChanged);
    tabs.focused?.resume();
    library.readSettings().then((s) {
      if (mounted) setState(() => _placement = ToolbarPlacement.fromJson(s));
    });
  }

  @override
  void didUpdateWidget(EditorScreen old) {
    super.didUpdateWidget(old);
    if (old.tabs != widget.tabs) {
      old.tabs.removeListener(_onTabsChanged);
      if (old.tabs.onMessage == _toast) old.tabs.onMessage = null;
      widget.tabs
        ..addListener(_onTabsChanged)
        ..onMessage = _toast;
    }
  }

  @override
  void dispose() {
    tabs.removeListener(_onTabsChanged);
    if (tabs.onMessage == _toast) tabs.onMessage = null;
    _lifecycle.dispose();
    super.dispose();
  }

  void _saveQuietly() => unawaited(tabs.saveAll());

  void _onTabsChanged() {
    if (!mounted) return;
    _applyInsets();
    setState(() {});
  }

  /// The notebooks on screen (one, or two in the split screen; once if both panes show
  /// the same one).
  Set<EditorController> get _shown => {?tabs.active, ?tabs.split};

  /// Back to the library, keeping every tab open (their edits are written first).
  Future<void> _goHome() async {
    if (_leaving) return;
    _leaving = true;
    try {
      for (final c in _shown) {
        await c.suspend(thumbnail: true);
      }
      await tabs.saveAll();
      unawaited(sync.syncNow());
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop(true);
    } finally {
      _leaving = false;
    }
  }

  /// Closes a tab (saving it); closing the last one returns to the library.
  Future<void> _closeTab(EditorController c) async {
    final last = tabs.length == 1;
    if (last) {
      if (_leaving) return;
      _leaving = true;
    }
    try {
      await tabs.close(c);
      if (last && mounted && Navigator.of(context).canPop()) Navigator.of(context).pop(true);
    } finally {
      if (last) _leaving = false;
    }
  }

  /// The docked toolbar covers part of the canvas: keep page 1 (and the page edges) out
  /// from under it.
  void _onToolbarObstruction(EdgeInsets band) {
    _toolbarBand = band;
    _applyInsets();
  }

  /// Gives each pane's view the part of the toolbar band that covers it: a toolbar docked
  /// on the left edge only covers the left pane, one on the right edge the right pane, and
  /// one at the top or bottom both.
  void _applyInsets() {
    final band = _toolbarBand;
    if (band == null) return;
    final split = tabs.isSplit;
    for (final pane in EditorPane.values) {
      final c = tabs.notebookIn(pane);
      if (c == null) continue;
      final own = !split
          ? band
          : pane == EditorPane.primary
          ? band.copyWith(right: 0)
          : band.copyWith(left: 0);
      c.viewOf(pane).setInsets(canvas.Viewport.insetsFor(own));
    }
  }

  void _toggleSplit() => tabs.isSplit ? tabs.closeSplit() : tabs.splitRight();

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action, behavior: SnackBarBehavior.floating));
  }

  /// World coordinate at the centre of [pane]'s canvas (paste target).
  Offset _viewportCenterWorld(EditorController c, EditorPane pane) {
    final view = c.viewOf(pane);
    return view.screenToWorld(view.size.center(Offset.zero));
  }

  void _paste(EditorController c, EditorPane pane) => c.pasteAt(_viewportCenterWorld(c, pane));

  Future<void> _editNote(EditorController c, StickyNote note, {bool isNew = false}) async {
    final result = await showStickyNoteEditor(context, note);
    if (!mounted) return;
    final current = c.scene.note(note.id) ?? note;
    switch (result) {
      case NoteSaved(:final text, :final color):
        c.updateNote(current.copyWith(text: text, color: color.toARGB32()));
      case NoteDeleted():
        c.deleteNote(note.id);
      case null:
        // Tapping by accident creates an empty note – drop it if the editor is dismissed.
        if (isNew && current.text.isEmpty) c.deleteNote(note.id);
    }
  }

  /// "Pin" on the selection in [pane]: a sharp picture of it (on its page background)
  /// floats over the canvas, top right, at about the size it has on screen. The document
  /// itself does not change.
  Future<void> _pin(EditorController c, EditorPane pane) async {
    final bounds = c.selectionBounds;
    if (bounds == null || _pinning) return;
    _pinning = true;
    try {
      final area = pinAreaFor(c, bounds);
      final scale = pinRenderScale(area, MediaQuery.devicePixelRatioOf(context));
      final image = await renderArea(c, area, scale: scale, only: c.selectedIds.toSet());
      if (!mounted) {
        image.dispose();
        return;
      }
      final room = _canvasArea;
      final maxWidth = math.max(PinnedBox.minWidth, math.min(480.0, room.width * 0.45));
      final width = (area.width * c.viewOf(pane).scale).clamp(PinnedBox.minWidth, maxWidth);
      final size = Size(width, PinnedBox.headerHeight + width * area.height / area.width);
      final page = c.pageIndexAt(area.center.dy);
      tabs.pins.pin(
        image,
        label: page == null ? c.title : '${c.title} · page ${page + 1}',
        position: tabs.pins.placeNew(size, room, top: _toolbarBand?.top ?? 0),
        width: width,
      );
      // The pin is the reference now; the dashed box would only sit over the page.
      c.clearSelection();
    } catch (e) {
      _toast('Could not pin the selection: $e');
    } finally {
      _pinning = false;
    }
  }

  Future<void> _confirmClear(EditorController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this notebook?'),
        content: const Text(
          'All strokes and sticky notes will be removed. Pages and imported PDF pages stay. '
          'You can bring them back with Undo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) c.clearPage();
  }

  Future<void> _export(EditorController c) async {
    setState(() => _exporting = true);
    try {
      final path = await nextExportPath(baseName: c.title);
      final report = await c.exportPdf(path);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
      if (isMobile) {
        await openExportedPdf(report, shareOrigin: origin);
      } else {
        _toast(
          'Saved ${report.pageCount} page(s) · ${(report.byteSize / 1024).toStringAsFixed(0)} KB → ${report.path}',
          action: SnackBarAction(label: 'Open', onPressed: () => openExportedPdf(report)),
        );
      }
    } catch (e) {
      _toast('PDF export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _onPlacementChanged(ToolbarPlacement p) {
    _placement = p;
    library.updateSettings(p.toJson());
  }

  /// Shortcuts of the focused pane's notebook [c].
  Map<ShortcutActivator, VoidCallback> _shortcuts(EditorController c, EditorPane pane) => {
    // Tabs: Ctrl+Tab / Ctrl+Shift+Tab cycle through the open notebooks (focused pane).
    const SingleActivator(LogicalKeyboardKey.tab, control: true): () => tabs.cycle(1),
    const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => tabs.cycle(-1),
    // Split screen on / off.
    const SingleActivator(LogicalKeyboardKey.backslash, control: true): _toggleSplit,
    const SingleActivator(LogicalKeyboardKey.backslash, meta: true): _toggleSplit,
    // Undo / redo (holding the keys repeats them).
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): c.undo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): c.copySelection,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true): c.copySelection,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true): c.cutSelection,
    const SingleActivator(LogicalKeyboardKey.keyX, meta: true): c.cutSelection,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => _paste(c, pane),
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () => _paste(c, pane),
    const SingleActivator(LogicalKeyboardKey.keyD, control: true): c.duplicateSelection,
    const SingleActivator(LogicalKeyboardKey.keyD, meta: true): c.duplicateSelection,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => c.save(),
    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => c.save(),
    const SingleActivator(LogicalKeyboardKey.digit0, control: true): c.viewOf(pane).resetZoom,
    const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.escape): () => c.clearSelection(),
  };

  @override
  Widget build(BuildContext context) {
    final c = tabs.focused;
    final pane = tabs.focusedPane;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goHome();
      },
      child: CallbackShortcuts(
        bindings: c == null ? const {} : _shortcuts(c, pane),
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: kDeskColor,
            body: Column(
              children: [
                EditorAppBar(
                  tabs: tabs,
                  onHome: _goHome,
                  onCloseTab: _closeTab,
                  // The document actions work on the focused pane's notebook.
                  onPaste: () {
                    if (c != null) _paste(c, pane);
                  },
                  onClear: () {
                    if (c != null) _confirmClear(c);
                  },
                  onExport: () {
                    if (c != null) _export(c);
                  },
                  exporting: _exporting,
                ),
                // No tab: the last one is closing, the library comes back in a moment.
                Expanded(child: tabs.active == null ? const SizedBox.expand() : _workspace()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Width of the left pane for a split screen [width] wide.
  double _leftPaneWidth(double width) {
    final available = math.max(0.0, width - SplitDivider.width);
    final min = math.min(_minPaneWidth, available / 2);
    return (available * tabs.splitRatio).clamp(min, available - min);
  }

  /// The panes side by side, with the shared toolbar, the pinned boxes and (while a tab is
  /// dragged) the drop zones floating over their canvases.
  Widget _workspace() => SafeArea(
    top: false,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final left = tabs.active!;
        final right = tabs.split;
        final width = constraints.maxWidth;
        final header = right == null ? 0.0 : PaneHeader.height;
        final area = Size(width, math.max(0.0, constraints.maxHeight - header - CanvasStatusBar.height));
        _canvasArea = area;
        final focused = tabs.focused;
        final available = math.max(1.0, width - SplitDivider.width);
        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: right == null ? width : _leftPaneWidth(width), child: _pane(EditorPane.primary, left)),
                if (right != null) ...[
                  SplitDivider(
                    onDrag: (dx) => tabs.setSplitRatio(_leftPaneWidth(width) / available + dx / available),
                    onReset: () => tabs.setSplitRatio(0.5),
                  ),
                  Expanded(child: _pane(EditorPane.secondary, right)),
                ],
              ],
            ),
            Positioned(
              left: 0,
              top: header,
              width: area.width,
              height: area.height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: TabDropZones(
                      split: tabs.isSplit,
                      onDropLeft: (c) => tabs
                        ..focusPane(EditorPane.primary)
                        ..activate(tabs.tabs.indexOf(c)),
                      onDropRight: tabs.splitRight,
                    ),
                  ),
                  Positioned.fill(child: PinnedBoxesLayer(board: tabs.pins, bounds: area)),
                  if (focused != null && focused.isOpen)
                    DraggableToolbar(
                      controller: focused,
                      bounds: area,
                      placement: _placement,
                      onPlacementChanged: _onPlacementChanged,
                      onObstructionChanged: _onToolbarObstruction,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  /// One pane: (split screen only) its header, the notebook's canvas through the pane's
  /// own view, and its status bar.
  Widget _pane(EditorPane pane, EditorController c) {
    final split = tabs.isSplit;
    final focused = tabs.focusedPane == pane;
    final lastPane = !split || pane == EditorPane.secondary;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        children: [
          if (split)
            PaneHeader(
              controller: c,
              focused: focused,
              onFocus: () => tabs.focusPane(pane),
              onClose: pane == EditorPane.secondary ? tabs.closeSplit : null,
            ),
          Expanded(child: _paneBody(pane, c, focused: focused)),
          if (c.isOpen)
            CanvasStatusBar(controller: c, pane: pane, sync: lastPane ? sync : null)
          else
            const ColoredBox(color: Color(0xFF252526), child: SizedBox(height: CanvasStatusBar.height, width: double.infinity)),
        ],
      ),
    );
  }

  Widget _paneBody(EditorPane pane, EditorController c, {required bool focused}) {
    if (c.openError != null) {
      return Listener(
        onPointerDown: (_) => tabs.focusPane(pane),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                const SizedBox(height: 12),
                Text('"${c.title}" could not be opened', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('${c.openError}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => _closeTab(c), child: const Text('Close tab')),
              ],
            ),
          ),
        ),
      );
    }
    if (!c.isOpen) return const Center(child: CircularProgressIndicator());
    final other = tabs.notebookIn(pane == EditorPane.primary ? EditorPane.secondary : EditorPane.primary);
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          // A tab switch starts a fresh canvas: no gesture carries over.
          child: NoteCanvas(
            key: ObjectKey(c),
            controller: c,
            pane: pane,
            gate: _gate,
            onFocus: () => tabs.focusPane(pane),
            onPin: () => _pin(c, pane),
            // The same notebook in both panes: its selection bar only in the focused one.
            showSelectionActions: focused || !identical(other, c),
            onEditNote: (note, {isNew = false}) => _editNote(c, note, isNew: isNew),
            onMessage: _toast,
          ),
        ),
        if (tabs.isSplit && focused)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: const Color(0x668AB4F8), width: 1.5)),
            ),
          ),
      ],
    );
  }
}
