import 'dart:async';
import 'dart:io' show Directory;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../canvas/painters.dart';
import '../canvas/scene_cache.dart';
import '../canvas/stroke_renderer.dart';
import '../canvas/viewport.dart';
import '../rust/api/stroke_api.dart' as engine;
import '../rust/document.dart';
import '../rust/document/eraser.dart';
import '../rust/document/page.dart';
import '../rust/document/paper.dart';
import '../rust/export/pdf_exporter.dart';
import '../rust/geometry/point.dart';
import '../rust/geometry/sticky_note.dart';
import '../rust/geometry/stroke.dart';
import '../services/library_service.dart';
import '../services/pdf_backgrounds.dart';
import 'tools.dart';

/// In-flight transform of the selection (preview only; committed on pointer-up).
@immutable
class SelectionPreview {
  const SelectionPreview({required this.from, required this.to});

  /// Selection bounds when the gesture started.
  final Rect from;

  /// Target bounds.
  final Rect to;

  double get scaleX => from.width > 0.5 ? to.width / from.width : 1;
  double get scaleY => from.height > 0.5 ? to.height / from.height : 1;
  double get dx => to.left - from.left;
  double get dy => to.top - from.top;

  /// Applies `p' = to.topLeft + (p - from.topLeft) * scale` to [canvas].
  void applyTo(ui.Canvas canvas) {
    canvas.translate(to.left, to.top);
    canvas.scale(scaleX, scaleY);
    canvas.translate(-from.left, -from.top);
  }
}

/// In-flight move / resize of a sticky note.
@immutable
class NotePreview {
  const NotePreview(this.id, this.rect);
  final String id;
  final Rect rect;
}

/// Transient drawing feedback rendered by the live layer (repaints at pointer rate
/// without touching the committed scene layer).
class LiveLayer extends ChangeNotifier {
  CachedStroke? preview;
  final List<Offset> lasso = [];
  Rect? box;
  Offset? eraserCursor;
  double eraserRadius = 12;

  void setPreview(StrokeRender? r) {
    preview = r == null ? null : CachedStroke(r);
    notifyListeners();
  }

  void addLassoPoint(Offset p) {
    lasso.add(p);
    notifyListeners();
  }

  void setBox(Rect? r) {
    box = r;
    notifyListeners();
  }

  void setEraser(Offset? p, double radius) {
    eraserCursor = p;
    eraserRadius = radius;
    notifyListeners();
  }

  void clear() {
    preview = null;
    lasso.clear();
    box = null;
    notifyListeners();
  }
}

/// UI state of one open notebook + the bridge to the Rust engine. Every document
/// mutation goes through the engine and comes back as a render / [SceneDelta] that
/// patches [scene]. Edits are autosaved (debounced) into the notebook bundle.
///
/// Several controllers can be open at once (editor tabs). Each owns an engine *slot*; the
/// engine edits one document at a time, so every engine call here first points it at this
/// notebook ([_bind]), and the async ones (load, save, export) name the slot explicitly.
class EditorController extends ChangeNotifier {
  EditorController({required this._entry, required this.library}) {
    PencilGrain.ensureLoaded().then((_) {
      if (!_disposed) scene.markDirty();
    });
    viewport.onReachEnd = _appendPageNear;
  }

  static const Duration autosaveDelay = Duration(seconds: 2);

  /// Slot 0 is the engine's scratch document; tabs count up from 1.
  static int _nextSlot = 1;

  final LibraryService library;
  NotebookEntry _entry;

  /// This notebook's document in the engine ([engine.activateDocument]).
  final int _slot = _nextSlot++;

  /// [open] put a document into the engine ([dispose] frees it).
  bool _started = false;

  final SceneCache scene = SceneCache();
  final Viewport viewport = Viewport();
  final LiveLayer live = LiveLayer();
  final ValueNotifier<SelectionPreview?> selectionPreview = ValueNotifier(null);
  final ValueNotifier<NotePreview?> notePreview = ValueNotifier(null);

  /// Device pixels per logical pixel (set by the canvas; drives PDF raster resolution).
  double devicePixelRatio = 1;

  /// Shows a transient message (wired to a snackbar by the screen).
  void Function(String message)? onMessage;

  /// Called after edits were written to disk (e.g. to mark the cloud backup as pending).
  VoidCallback? onSaved;

  // Document.
  DocumentKind _kind = DocumentKind.notebook;
  List<CanvasPage> _pages = const [];
  PdfBackgrounds? _pdf;
  int _pdfPageCount = 0;
  bool _opened = false;
  Object? _openError;
  bool _initialFitPending = false;
  int _savedRevision = -1;
  int _thumbnailRevision = -1;
  Future<void> _saveChain = Future.value();
  Timer? _autosave;
  bool _disposed = false;

  // Tools.
  EditorTool _tool = EditorTool.pen;
  final Map<EditorTool, BrushSettings> _brushes = Map.of(kDefaultBrushes);
  Color _stickyColor = kStickySwatches.first;
  EraserMode _eraserMode = EraserMode.partial;
  PaperStyle _paperStyle = PaperStyle.dictando;
  PaperSpec _paperSpec = const PaperSpec(
    kind: PaperKind.plain,
    background: 0xFFFFFFFF,
    lineColor: 0,
    spacing: 0,
    lineWidth: 0,
    firstLineY: 0,
    marginX: 0,
    marginColor: 0,
  );
  /// Shape snapping is opt-in: every notebook opens with it off (magic-wand toggle).
  bool _autoCorrect = false;
  bool _stylusOnly = false;
  bool _stylusDetected = false;

  List<String> _selectedIds = const [];
  Rect? _selectionBounds;
  bool _hasClipboard = false;
  bool _canUndo = false;
  bool _canRedo = false;

  // ------------------------------------------------------------------ getters

  NotebookEntry get entry => _entry;
  String get title => _entry.name;
  bool get isOpen => _opened;
  Object? get openError => _openError;
  DocumentKind get kind => _kind;
  bool get isPaged => _kind != DocumentKind.whiteboard;
  List<CanvasPage> get pages => _pages;
  PdfBackgrounds? get pdfBackgrounds => _pdf;

  EditorTool get tool => _tool;
  EraserMode get eraserMode => _eraserMode;
  PaperStyle get paperStyle => _paperStyle;
  PaperSpec get paperSpec => _paperSpec;
  bool get autoCorrect => _autoCorrect;
  bool get stylusOnly => _stylusOnly;
  bool get stylusDetected => _stylusDetected;
  List<String> get selectedIds => _selectedIds;
  Rect? get selectionBounds => _selectionBounds;
  bool get hasSelection => _selectedIds.isNotEmpty;
  bool get hasClipboard => _hasClipboard;
  Color get stickyColor => _stickyColor;

  /// Whether [undo] / [redo] would change the document (drives the toolbar buttons).
  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;

  /// Brush of the given tool (ink tools and eraser).
  BrushSettings brushFor(EditorTool t) => _brushes[t] ?? kDefaultBrushes[EditorTool.pen]!;

  /// Colour shown as "current" in the palette for the active tool.
  Color get activeColor => _tool == EditorTool.stickyNote ? _stickyColor : brushFor(_tool).color;

  /// The single selected sticky note, if the selection is exactly one note.
  StickyNote? get singleSelectedNote => _selectedIds.length == 1 ? scene.note(_selectedIds.first) : null;

  /// 0-based page under world Y (`null` for whiteboards).
  int? pageIndexAt(double y) {
    if (!isPaged || _pages.isEmpty) return null;
    return firstPageAt(_pages, y).clamp(0, _pages.length - 1);
  }

  // ------------------------------------------------------------------ lifecycle

  /// Loads the notebook into the engine (or creates / imports it the first time) and makes
  /// it the document the engine works on.
  Future<void> open() async {
    _started = true;
    try {
      final doc = _entry.documentFile;
      final pdfFile = _entry.isPdf ? _entry.pdfFile : null;
      final exists = await doc.exists();
      final DocumentInfo info;
      if (exists) {
        info = await engine.loadDocument(slot: _slot, path: doc.path, pdfPath: pdfFile?.path);
      } else if (pdfFile != null) {
        info = await engine.importPdf(slot: _slot, path: pdfFile.path);
      } else {
        info = engine.newDocument(slot: _slot, kind: _entry.meta.kind, paper: _entry.meta.paper);
      }
      if (_disposed) {
        // The tab was closed while loading: the load finished afterwards, free it again.
        engine.closeDocument(slot: _slot);
        return;
      }
      engine.activateDocument(slot: _slot);
      _applyInfo(info);
      _savedRevision = exists ? info.revision : -1;
      _loadScene();
      _hasClipboard = engine.hasClipboard();
      _pdfPageCount = info.pdfPageCount;
      if (pdfFile != null && _pdfPageCount > 0) {
        _pdf = PdfBackgrounds(pdfFile.path)..open();
      }
      _opened = true;
      _initialFitPending = true;
    } catch (e) {
      _openError = e;
    }
    if (!_disposed) notifyListeners();
  }

  /// Points the engine at this notebook. `false` until it is open (and after disposal).
  /// Every synchronous engine call is preceded by it: another tab may have used the engine
  /// in between (a background autosave, closing a tab).
  bool _bind() => _opened && !_disposed && engine.activateDocument(slot: _slot);

  /// The tab became visible: the engine works on this notebook again, and the clipboard
  /// (shared by all tabs) may have changed meanwhile.
  void resume() {
    if (!_bind()) return;
    _hasClipboard = engine.hasClipboard();
    _refreshHistory();
    notifyListeners();
  }

  /// The tab is being hidden (another tab or the library takes over): drops what an
  /// in-flight gesture was previewing, closes an open undo group and writes pending edits.
  /// Undo history, selection, viewport and tools stay as they are.
  Future<void> suspend({bool thumbnail = false}) {
    if (_bind()) {
      engine.cancelStroke();
      engine.endHistoryGroup();
      _refreshHistory();
    }
    live.clear();
    selectionPreview.value = null;
    notePreview.value = null;
    return save(thumbnail: thumbnail);
  }

  /// Before the library renames or moves this notebook (or a folder containing it): writes
  /// pending edits and lets go of the imported PDF (Windows cannot rename a folder while a
  /// file inside it is open). Follow up with [relocate].
  Future<void> releaseFiles() async {
    await save(thumbnail: true);
    _pdf?.dispose();
    _pdf = null;
  }

  /// The notebook now lives in [dir] (after a rename / move; pass the old folder if that
  /// failed). Reopens the PDF released by [releaseFiles].
  void relocate(Directory dir) {
    if (_disposed) return;
    _entry = NotebookEntry(dir, _entry.meta);
    if (_opened && _entry.isPdf && _pdfPageCount > 0 && _pdf == null) {
      _pdf = PdfBackgrounds(_entry.pdfFile.path)..open();
    }
    scene.markDirty();
    notifyListeners();
  }

  /// A new tab keeps the input mode the user already has: once a stylus was seen, fingers
  /// navigate in every notebook.
  void adoptInputMode(EditorController other) {
    _stylusDetected = other._stylusDetected;
    _stylusOnly = other._stylusOnly;
  }

  /// `true` exactly once after opening: the canvas then fits the page width.
  bool takeInitialFit() {
    final pending = _initialFitPending;
    _initialFitPending = false;
    return pending;
  }

  /// Saves pending edits (serialised: concurrent calls queue up). With [thumbnail], also
  /// refreshes the home-screen preview.
  Future<void> save({bool thumbnail = false}) {
    _autosave?.cancel();
    return _saveChain = _saveChain.then((_) => _save(thumbnail));
  }

  Future<void> _save(bool thumbnail) async {
    if (!_bind()) return;
    try {
      final revision = engine.documentRevision();
      if (revision != _savedRevision) {
        final report = await engine.saveDocument(slot: _slot, path: _entry.documentFile.path);
        _savedRevision = report.revision;
        final meta = _entry.meta.copyWith(paper: _paperStyle, pageCount: _pages.length, modified: DateTime.now());
        await library.writeMeta(_entry, meta);
        // Keep the current folder: the notebook may have been moved meanwhile ([relocate]).
        _entry = NotebookEntry(_entry.dir, meta);
        onSaved?.call();
      }
      // Unchanged since the last preview: skip it (every open tab is saved like this
      // whenever the library is shown).
      if (thumbnail && !_disposed && revision != _thumbnailRevision) {
        final png = await renderThumbnail(this);
        if (png != null) {
          await _entry.thumbnailFile.writeAsBytes(png, flush: true);
          _thumbnailRevision = revision;
        }
      }
    } catch (e) {
      onMessage?.call('Could not save "${_entry.name}": $e');
    }
  }

  /// Final save (with thumbnail) before the tab closes. Blank pages that were only created
  /// by scrolling down (nothing written on them) are dropped first, so browsing does not
  /// leave a trail of empty pages in the notebook and its PDF export. The document stays
  /// in the engine until [dispose].
  Future<void> close() {
    if (_bind()) {
      engine.endHistoryGroup();
      if (isPaged && engine.trimTrailingBlankPages() > 0) _setPages(engine.documentPages());
    }
    return save(thumbnail: true);
  }

  /// After every document change: schedule the autosave (which also marks the cloud
  /// backup as pending once written) and refresh the undo / redo state.
  void _edited() {
    _autosave?.cancel();
    _autosave = Timer(autosaveDelay, save);
    _refreshHistory();
  }

  void _refreshHistory() {
    final canUndo = engine.canUndo();
    final canRedo = engine.canRedo();
    if (canUndo == _canUndo && canRedo == _canRedo) return;
    _canUndo = canUndo;
    _canRedo = canRedo;
    notifyListeners();
  }

  // ------------------------------------------------------------------ undo / redo

  /// Reverts the last edit (stroke, erase, selection move / resize / duplicate / cut /
  /// paste / delete, sticky-note change, clear). No-op when there is nothing to undo.
  void undo() => _applyHistoryStep(_bind() ? engine.undo() : null);

  /// Re-applies the last undone edit.
  void redo() => _applyHistoryStep(_bind() ? engine.redo() : null);

  void _applyHistoryStep(SceneDelta? delta) {
    if (delta == null) return;
    selectionPreview.value = null;
    notePreview.value = null;
    scene.applyDelta(delta, restoreOrder: true);
    _syncPages(delta.pageCount);
    _applySelection(delta.selection);
    _edited();
  }

  /// Merges the following edits into one undo step until [endHistoryGroup] (gestures
  /// made of many engine calls).
  void beginHistoryGroup() {
    if (_bind()) engine.beginHistoryGroup();
  }

  void endHistoryGroup() {
    if (!_bind()) return;
    engine.endHistoryGroup();
    _refreshHistory();
  }

  void _applyInfo(DocumentInfo info) {
    _kind = info.kind;
    _paperStyle = info.paper;
    _paperSpec = engine.paperSpec(style: info.paper);
    _setPages(info.pages);
  }

  void _setPages(List<CanvasPage> pages) {
    _pages = pages;
    if (isPaged && pages.isNotEmpty) {
      final last = pages.last;
      viewport.setContentExtent(width: last.width, height: last.top + last.height);
    } else {
      viewport.setContentExtent();
    }
    scene.markDirty();
  }

  /// Refreshes the page list when an edit appended pages.
  void _syncPages(int count) {
    if (isPaged && count != _pages.length) _setPages(engine.documentPages());
  }

  /// Continuous scroll / writing: when [y] (bottom of the visible area, or the pen) gets
  /// within [Viewport.appendMargin] of the bottom of the last page, the engine appends
  /// page N + 1 directly beneath page N.
  void _appendPageNear(double y) {
    if (!isPaged || !_bind()) return;
    final page = engine.appendPageIfNearEnd(y: y, margin: Viewport.appendMargin);
    if (page == null) {
      if (!_pageLimitShown && _pages.length >= engine.maxPageCount()) {
        _pageLimitShown = true;
        onMessage?.call('Page limit reached.');
      }
      return;
    }
    _setPages([..._pages, page]);
    _edited();
    notifyListeners();
  }

  bool _pageLimitShown = false;

  // ------------------------------------------------------------------ settings

  void selectTool(EditorTool t) {
    if (t == _tool) return;
    _tool = t;
    if (!t.isSelection && hasSelection) clearSelection(notify: false);
    live.setEraser(null, live.eraserRadius);
    notifyListeners();
  }

  void setEraserMode(EraserMode m) {
    if (m == _eraserMode) return;
    _eraserMode = m;
    notifyListeners();
  }

  void setColor(Color c) {
    if (_tool == EditorTool.stickyNote) {
      _stickyColor = c;
    } else if (_brushes.containsKey(_tool)) {
      _brushes[_tool] = _brushes[_tool]!.copyWith(color: c);
    }
    notifyListeners();
  }

  void setWidth(double w) {
    if (_brushes.containsKey(_tool)) {
      _brushes[_tool] = _brushes[_tool]!.copyWith(width: w);
      notifyListeners();
    }
  }

  void setPaperStyle(PaperStyle s) {
    if (s == _paperStyle || !_bind()) return;
    _applyInfo(engine.setPaperStyle(style: s));
    _edited();
    notifyListeners();
  }

  void setAutoCorrect(bool v) {
    _autoCorrect = v;
    notifyListeners();
  }

  void setStylusOnly(bool v) {
    _stylusOnly = v;
    notifyListeners();
  }

  /// First stylus contact switches to "stylus draws, fingers navigate" (palm rejection).
  /// Returns `true` the first time a stylus is seen.
  bool registerStylus() {
    if (_stylusDetected) return false;
    _stylusDetected = true;
    _stylusOnly = true;
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------------ scene

  /// Reloads the whole scene from the engine.
  void loadScene() {
    if (_bind()) _loadScene();
  }

  void _loadScene() {
    final snapshot = engine.getScene();
    scene.load(snapshot);
    _applySelection(snapshot.selection);
  }

  /// Removes all strokes and notes (pages, paper and imported PDF stay).
  void clearPage() {
    if (!_bind()) return;
    engine.resetDocument();
    selectionPreview.value = null;
    notePreview.value = null;
    live.clear();
    _loadScene();
    _edited();
    notifyListeners();
  }

  // ------------------------------------------------------------------ drawing

  void beginStroke(EditorTool tool, Offset world, double pressure) {
    if (!_bind()) return;
    final t = tool.engineTool ?? ToolType.pen;
    engine.beginStroke(tool: t, brush: brushFor(tool).toEngine());
    addPoint(world, pressure);
  }

  void addPoint(Offset world, double pressure) {
    if (!_bind()) return;
    engine.addPoint(
      point: StrokePoint(x: world.dx, y: world.dy, pressure: pressure),
    );
    live.setPreview(engine.currentStrokePreview());
    // Writing into the last 50 units of the last page opens the next page under the pen.
    final end = viewport.contentHeight;
    if (isPaged && end != null && world.dy >= end - Viewport.appendMargin) _appendPageNear(world.dy);
  }

  /// Commits the stroke. With [autoCorrect] on, shape snapping happens inside this call,
  /// so the snapped shape is what the next frame shows.
  void finishStroke(EditorTool tool) {
    if (!_bind()) return;
    final t = tool.engineTool ?? ToolType.pen;
    final render = engine.finishStroke(tool: t, autoCorrect: _autoCorrect);
    live.setPreview(null);
    if (render == null) return;
    scene.addStroke(render);
    _syncPages(engine.pageCount());
    _edited();
  }

  void cancelStroke() {
    if (_bind()) engine.cancelStroke();
    live.setPreview(null);
  }

  double get eraserRadius => brushFor(EditorTool.eraser).width / 2;

  /// Erases along the eraser's movement from [from] to [to] with the current mode.
  void eraseAlong(Offset from, Offset to) {
    if (!_bind()) return;
    final delta = engine.eraseAlong(
      x0: from.dx,
      y0: from.dy,
      x1: to.dx,
      y1: to.dy,
      radius: eraserRadius,
      mode: _eraserMode,
    );
    live.setEraser(to, eraserRadius);
    if (delta.removedIds.isEmpty && delta.upsertedStrokes.isEmpty) return;
    scene.applyDelta(delta);
    final bounds = delta.selection.bounds?.toRect();
    if (!listEquals(delta.selection.ids, _selectedIds) || bounds != _selectionBounds) {
      _applySelection(delta.selection);
    }
    _edited();
  }

  // ------------------------------------------------------------------ selection

  void _applySelection(SelectionInfo info, {bool notify = true}) {
    _selectedIds = info.ids;
    _selectionBounds = info.bounds?.toRect();
    if (notify) notifyListeners();
  }

  void _applyDelta(SceneDelta delta) {
    scene.applyDelta(delta);
    _syncPages(delta.pageCount);
    _applySelection(delta.selection);
    _edited();
  }

  void selectLasso(List<Offset> polygon) {
    if (!_bind()) return;
    final flat = <double>[
      for (final p in polygon) ...[p.dx, p.dy],
    ];
    engine.selectInLasso(polygon: flat);
    _applySelection(engine.getSelection());
  }

  void selectBox(Rect r) {
    if (!_bind()) return;
    engine.selectInRegion(
      rect: ViewportRect(left: r.left, top: r.top, right: r.right, bottom: r.bottom),
    );
    _applySelection(engine.getSelection());
  }

  void selectAt(Offset world, double tolerance) {
    if (!_bind()) return;
    engine.selectAt(x: world.dx, y: world.dy, tolerance: tolerance);
    _applySelection(engine.getSelection());
  }

  void clearSelection({bool notify = true}) {
    if (_bind()) engine.clearSelection();
    _applySelection(const SelectionInfo(ids: []), notify: notify);
  }

  void commitTransform(SelectionPreview p) {
    selectionPreview.value = null;
    if (p.from == p.to || !_bind()) return;
    _applyDelta(engine.transformSelection(scaleX: p.scaleX, scaleY: p.scaleY, dx: p.dx, dy: p.dy));
  }

  void duplicateSelection() {
    if (hasSelection && _bind()) _applyDelta(engine.duplicateSelection());
  }

  void copySelection() {
    if (!_bind()) return;
    _hasClipboard = engine.copySelection() > 0;
    notifyListeners();
  }

  void cutSelection() {
    if (!hasSelection || !_bind()) return;
    _applyDelta(engine.cutSelection());
    _hasClipboard = engine.hasClipboard();
    notifyListeners();
  }

  void deleteSelection() {
    if (hasSelection && _bind()) _applyDelta(engine.deleteSelection());
  }

  void pasteAt(Offset worldCenter) {
    if (!_hasClipboard || !_bind()) return;
    _applyDelta(engine.pasteClipboard(centerX: worldCenter.dx, centerY: worldCenter.dy));
  }

  // ------------------------------------------------------------------ sticky notes

  StickyNote? noteAt(Offset world) => _bind() ? engine.stickyNoteAt(x: world.dx, y: world.dy) : null;

  /// Only called while the notebook is open (the canvas exists only then).
  StickyNote createNote(Offset world) {
    _bind();
    final note = engine.createStickyNote(
      x: world.dx,
      y: world.dy,
      width: 200,
      height: 150,
      color: _stickyColor.toARGB32(),
      text: '',
    );
    scene.upsertNote(note);
    _syncPages(engine.pageCount());
    _edited();
    return note;
  }

  void updateNote(StickyNote note) {
    if (!_bind()) return;
    final updated = engine.updateStickyNote(note: note);
    if (updated == null) return;
    scene.upsertNote(updated);
    _syncPages(engine.pageCount());
    if (_selectedIds.contains(updated.id)) _applySelection(engine.getSelection());
    _edited();
  }

  void deleteNote(String id) {
    if (_bind()) _applyDelta(engine.deleteItems(ids: [id]));
  }

  // ------------------------------------------------------------------ export

  Future<PdfExportReport> exportPdf(String path) => engine.exportToPdf(slot: _slot, path: path);

  @override
  void dispose() {
    _disposed = true;
    _autosave?.cancel();
    // Frees the engine document (with its undo history). Unsaved edits are gone: call
    // [close] first to keep them.
    if (_started) engine.closeDocument(slot: _slot);
    viewport.onReachEnd = null;
    _pdf?.dispose();
    scene.dispose();
    viewport.dispose();
    live.dispose();
    selectionPreview.dispose();
    notePreview.dispose();
    super.dispose();
  }
}
