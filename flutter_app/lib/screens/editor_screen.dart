import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/canvas/note_canvas.dart';
import '../src/canvas/painters.dart';
import '../src/canvas/scene_cache.dart';
import '../src/canvas/viewport.dart' as canvas;
import '../src/editor/editor_controller.dart';
import '../src/editor/open_notebooks.dart';
import '../src/rust/geometry/sticky_note.dart';
import '../src/services/library_service.dart';
import '../src/services/pdf_export_service.dart';
import '../src/sync/sync_service.dart';
import '../src/ui/sticky_note_dialog.dart';
import '../widgets/canvas_status_bar.dart';
import '../widgets/draggable_toolbar.dart';
import '../widgets/editor_app_bar.dart';

/// The editor: dark chrome with the tabs of the open notebooks, then the active
/// notebook's page canvas, floating toolbar and status bar. Edits autosave. Home (or the
/// back button / gesture) saves every tab and returns to the library, where the tabs stay
/// open; closing the last tab returns there too.
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

  late final AppLifecycleListener _lifecycle;
  ToolbarPlacement _placement = ToolbarPlacement.initial;

  /// Canvas band behind the docked toolbar; every tab's viewport keeps clear of it.
  EdgeInsets? _toolbarBand;
  EditorController? _shown;
  bool _exporting = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // Hiding / exiting the app runs SyncService.flush(), which awaits every tab's saver
    // before uploading; pause / detach (mobile) save directly.
    _lifecycle = AppLifecycleListener(onPause: _saveQuietly, onDetach: _saveQuietly);
    tabs.onMessage = _toast;
    tabs.addListener(_onTabsChanged);
    _shown = tabs.active?..resume();
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
    final c = tabs.active;
    if (c != null && !identical(c, _shown)) {
      _shown = c;
      final band = _toolbarBand;
      if (band != null) c.viewport.setInsets(canvas.Viewport.insetsFor(band));
    }
    setState(() {});
  }

  /// Back to the library, keeping every tab open (their edits are written first).
  Future<void> _goHome() async {
    if (_leaving) return;
    _leaving = true;
    try {
      await tabs.active?.suspend(thumbnail: true);
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
    tabs.active?.viewport.setInsets(canvas.Viewport.insetsFor(band));
  }

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action, behavior: SnackBarBehavior.floating));
  }

  /// World coordinate at the centre of the visible canvas (paste target).
  Offset _viewportCenterWorld(EditorController c) {
    final size = c.viewport.size;
    return c.viewport.screenToWorld(size.center(Offset.zero));
  }

  void _paste(EditorController c) => c.pasteAt(_viewportCenterWorld(c));

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

  Map<ShortcutActivator, VoidCallback> _shortcuts(EditorController c) => {
    // Tabs: Ctrl+Tab / Ctrl+Shift+Tab cycle through the open notebooks.
    const SingleActivator(LogicalKeyboardKey.tab, control: true): () => tabs.cycle(1),
    const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => tabs.cycle(-1),
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
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => _paste(c),
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () => _paste(c),
    const SingleActivator(LogicalKeyboardKey.keyD, control: true): c.duplicateSelection,
    const SingleActivator(LogicalKeyboardKey.keyD, meta: true): c.duplicateSelection,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => c.save(),
    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => c.save(),
    const SingleActivator(LogicalKeyboardKey.digit0, control: true): c.viewport.resetZoom,
    const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.escape): () => c.clearSelection(),
  };

  @override
  Widget build(BuildContext context) {
    final c = tabs.active;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goHome();
      },
      child: CallbackShortcuts(
        bindings: c == null ? const {} : _shortcuts(c),
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
                  // The document actions are only shown while a tab is active.
                  onPaste: () {
                    if (c != null) _paste(c);
                  },
                  onClear: () {
                    if (c != null) _confirmClear(c);
                  },
                  onExport: () {
                    if (c != null) _export(c);
                  },
                  exporting: _exporting,
                ),
                Expanded(
                  // No tab: the last one is closing, the library comes back in a moment.
                  child: c == null
                      ? const SizedBox.expand()
                      : ListenableBuilder(
                          listenable: c,
                          builder: (context, _) => _body(c),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(EditorController c) {
    if (c.openError != null) {
      return Center(
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
      );
    }
    if (!c.isOpen) return const Center(child: CircularProgressIndicator());
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvas = Size(constraints.maxWidth, constraints.maxHeight - CanvasStatusBar.height);
          return Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                bottom: CanvasStatusBar.height,
                child: ClipRect(
                  // A tab switch starts a fresh canvas: no gesture carries over.
                  child: NoteCanvas(
                    key: ObjectKey(c),
                    controller: c,
                    onEditNote: (note, {isNew = false}) => _editNote(c, note, isNew: isNew),
                    onMessage: _toast,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                width: canvas.width,
                height: canvas.height,
                child: Stack(
                  children: [
                    DraggableToolbar(
                      controller: c,
                      bounds: canvas,
                      placement: _placement,
                      onPlacementChanged: _onPlacementChanged,
                      onObstructionChanged: _onToolbarObstruction,
                    ),
                  ],
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 0, child: CanvasStatusBar(controller: c, sync: sync)),
            ],
          );
        },
      ),
    );
  }
}
