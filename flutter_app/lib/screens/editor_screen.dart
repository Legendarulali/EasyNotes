import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/canvas/note_canvas.dart';
import '../src/canvas/painters.dart';
import '../src/canvas/scene_cache.dart';
import '../src/canvas/viewport.dart' as canvas;
import '../src/editor/editor_controller.dart';
import '../src/rust/geometry/sticky_note.dart';
import '../src/services/library_service.dart';
import '../src/services/pdf_export_service.dart';
import '../src/sync/sync_service.dart';
import '../src/ui/sticky_note_dialog.dart';
import '../widgets/canvas_status_bar.dart';
import '../widgets/draggable_toolbar.dart';
import '../widgets/editor_app_bar.dart';

/// One open notebook: dark chrome, page canvas, floating toolbar and status bar.
/// Edits autosave; leaving the screen (back button / gesture) saves and refreshes the
/// library thumbnail first.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.entry, required this.library, required this.sync});

  final NotebookEntry entry;
  final LibraryService library;

  /// Cloud backup: the notebook is uploaded when the editor closes.
  final SyncService sync;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController c = EditorController(entry: widget.entry, library: widget.library)
    ..onMessage = _toast
    ..onSaved = widget.sync.markPending;
  late final AppLifecycleListener _lifecycle;
  ToolbarPlacement _placement = ToolbarPlacement.initial;
  bool _exporting = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // Hiding / exiting the app runs SyncService.flush(), which awaits this saver before
    // uploading; pause / detach (mobile) save directly.
    _lifecycle = AppLifecycleListener(onPause: _saveQuietly, onDetach: _saveQuietly);
    widget.sync.registerSaver(this, () => c.save(thumbnail: true));
    c.open();
    widget.library.readSettings().then((s) {
      if (mounted) setState(() => _placement = ToolbarPlacement.fromJson(s));
    });
  }

  @override
  void dispose() {
    widget.sync.unregisterSaver(this);
    _lifecycle.dispose();
    c.dispose();
    super.dispose();
  }

  void _saveQuietly() => c.save(thumbnail: true);

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    await c.close();
    // Notebook closed: push it to Google Drive in the background.
    unawaited(widget.sync.syncNow());
    if (mounted) Navigator.of(context).pop(true);
  }

  /// The docked toolbar covers part of the canvas: keep page 1 (and the page edges) out
  /// from under it.
  void _onToolbarObstruction(EdgeInsets band) => c.viewport.setInsets(canvas.Viewport.insetsFor(band));

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action, behavior: SnackBarBehavior.floating));
  }

  /// World coordinate at the centre of the visible canvas (paste target).
  Offset _viewportCenterWorld() {
    final size = c.viewport.size;
    return c.viewport.screenToWorld(size.center(Offset.zero));
  }

  void _paste() => c.pasteAt(_viewportCenterWorld());

  Future<void> _editNote(StickyNote note, {bool isNew = false}) async {
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

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this notebook?'),
        content: const Text('All strokes and sticky notes will be removed. Pages and imported PDF pages stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) c.clearPage();
  }

  Future<void> _export() async {
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
    widget.library.updateSettings(p.toJson());
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): c.copySelection,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true): c.copySelection,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true): c.cutSelection,
    const SingleActivator(LogicalKeyboardKey.keyX, meta: true): c.cutSelection,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: kDeskColor,
            body: Column(
              children: [
                EditorAppBar(
                  controller: c,
                  onBack: _leave,
                  onPaste: _paste,
                  onClear: _confirmClear,
                  onExport: _export,
                  exporting: _exporting,
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) => _body(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
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
              FilledButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Back')),
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
                  child: NoteCanvas(controller: c, onEditNote: _editNote, onMessage: _toast),
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
              Positioned(left: 0, right: 0, bottom: 0, child: CanvasStatusBar(controller: c, sync: widget.sync)),
            ],
          );
        },
      ),
    );
  }
}
