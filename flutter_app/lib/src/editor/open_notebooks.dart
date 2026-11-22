import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/library_service.dart';
import '../sync/sync_service.dart';
import 'editor_controller.dart';
import 'pin_board.dart';

/// The notebooks open as editor tabs, in tab order, and what is on screen: one notebook,
/// or two side by side in the split screen (two different tabs, or the same notebook
/// twice).
///
/// Owns their [EditorController]s, so a tab keeps its undo history, viewport, selection
/// and tools while another tab is shown, and while the library is on screen. The engine
/// edits one document at a time; switching tabs only re-points it, nothing is reloaded.
///
/// With a split screen, the *focused* pane (the one last touched) is the one the tab
/// strip, the toolbar and the keyboard work on: picking a tab shows it in that pane.
class OpenNotebooks extends ChangeNotifier {
  OpenNotebooks({required this.library, required this.sync});

  /// Narrowest share of the width either split pane can be dragged to.
  static const double minSplitRatio = 0.2;

  final LibraryService library;

  /// Every tab is saved by [SyncService.flush] (app hidden / closing) before the upload.
  final SyncService sync;

  /// Reference snapshots pinned over the canvas. They stay while tabs and panes change,
  /// and are never saved.
  final PinBoard pins = PinBoard();

  /// Where the tabs' messages (e.g. a failed save) are shown; set by the editor screen.
  void Function(String message)? onMessage;

  final List<EditorController> _tabs = [];
  int _active = -1;
  EditorController? _split;
  bool _splitFocused = false;
  double _splitRatio = 0.5;

  List<EditorController> get tabs => List.unmodifiable(_tabs);
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;
  bool get isNotEmpty => _tabs.isNotEmpty;
  int get activeIndex => _active;

  /// The notebook in the left pane (the whole editor without a split screen).
  EditorController? get active => _active < 0 ? null : _tabs[_active];

  /// The notebook in the right pane of the split screen; `null` with a single pane.
  EditorController? get split => _split;
  bool get isSplit => _split != null;

  /// The pane the tab strip, toolbar and keyboard shortcuts work on: the one last used.
  EditorPane get focusedPane => _split != null && _splitFocused ? EditorPane.secondary : EditorPane.primary;

  /// The notebook in the [focusedPane].
  EditorController? get focused => notebookIn(focusedPane);

  EditorController? notebookIn(EditorPane pane) => switch (pane) {
    EditorPane.primary => active,
    EditorPane.secondary => _split,
  };

  /// Whether [c] is on screen, in either pane.
  bool isShown(EditorController c) => identical(c, active) || identical(c, _split);

  /// Share of the width taken by the left pane.
  double get splitRatio => _splitRatio;

  void setSplitRatio(double ratio) {
    final r = ratio.clamp(minSplitRatio, 1 - minSplitRatio);
    if (r == _splitRatio) return;
    _splitRatio = r;
    notifyListeners();
  }

  /// The tab showing [entry], if it is open.
  EditorController? tabOf(NotebookEntry entry) =>
      _tabs.where((c) => LibraryService.samePath(c.entry.path, entry.path)).firstOrNull;

  /// The tabs of [entry] (a notebook) or of the notebooks somewhere inside it (a folder).
  List<EditorController> tabsWithin(LibraryEntry entry) =>
      _tabs.where((c) => LibraryService.isWithin(c.entry.path, entry.path)).toList();

  /// Shows [entry] in the focused pane: switches to its tab when it is open already,
  /// otherwise opens it in a new tab right after the focused one.
  EditorController open(NotebookEntry entry) {
    final existing = tabOf(entry);
    if (existing != null) {
      _show(existing);
      return existing;
    }
    final previous = focused;
    final c = EditorController(entry: entry, library: library)
      ..onMessage = _message
      ..onSaved = sync.markPending;
    if (previous != null) c.adoptInputMode(previous);
    sync.registerSaver(c, () => c.save(thumbnail: true));
    final at = previous == null ? _tabs.length : _tabs.indexOf(previous) + 1;
    _tabs.insert(at, c);
    if (_active >= at) _active++;
    unawaited(c.open());
    _show(c);
    return c;
  }

  /// Shows the tab at [index] in the focused pane. The notebook that was there writes
  /// its pending edits (unless the other pane still shows it).
  void activate(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _show(_tabs[index]);
  }

  void _show(EditorController c) {
    final pane = focusedPane;
    final previous = notebookIn(pane);
    if (identical(previous, c)) return;
    if (pane == EditorPane.secondary) {
      _split = c;
      // The same notebook twice: the new view starts on the page the left pane shows.
      if (identical(c, active)) c.alignSecondaryView();
    } else {
      _active = _tabs.indexOf(c);
    }
    _leave(previous);
    c.resume();
    notifyListeners();
  }

  /// [c] left a pane: if it is not on screen any more, its pending edits are written.
  void _leave(EditorController? c) {
    if (c != null && _tabs.contains(c) && !isShown(c)) unawaited(c.suspend());
  }

  /// The next (`step` 1) or previous (`step` -1) tab in the focused pane, wrapping around
  /// (Ctrl+Tab).
  void cycle(int step) {
    final current = focused;
    if (_tabs.length < 2 || current == null) return;
    activate((_tabs.indexOf(current) + step) % _tabs.length);
  }

  /// Split screen: shows [c] in the right pane and focuses it. Without [c], the right pane
  /// shows a second view of the left pane's notebook, starting on the same page. Each pane
  /// scrolls and zooms on its own.
  void splitRight([EditorController? c]) {
    final left = active;
    c ??= left;
    if (left == null || c == null || !_tabs.contains(c)) return;
    final wasSplit = _split != null;
    final previous = _split;
    _split = c;
    _splitFocused = true;
    if (identical(c, left)) c.alignSecondaryView();
    // The left pane is about to get narrower: fit its page into it (staying on the page).
    if (!wasSplit) left.viewport.fitWhenLaidOut(top: left.viewport.offset.dy);
    if (!identical(previous, c)) _leave(previous);
    c.resume();
    notifyListeners();
  }

  /// Back to one pane: the left pane's notebook stays, the right one remains open as a tab.
  void closeSplit() {
    final right = _split;
    if (right == null) return;
    _split = null;
    _splitFocused = false;
    final left = active;
    left?.viewport.fitWhenLaidOut(top: left.viewport.offset.dy);
    _leave(right);
    left?.resume();
    notifyListeners();
  }

  /// [pane] was touched: the tab strip, toolbar and keyboard now work on its notebook.
  void focusPane(EditorPane pane) {
    final secondary = pane == EditorPane.secondary && _split != null;
    if (secondary == _splitFocused) return;
    _splitFocused = secondary;
    // The engine works on that notebook again; the shared clipboard may have changed.
    focused?.resume();
    notifyListeners();
  }

  /// Closes the tab of [c]: blank trailing pages are trimmed, the notebook is saved (with
  /// its library thumbnail) and its document freed. The tab to the right (or, for the last
  /// tab, to the left) takes over its pane; a right pane that showed it closes.
  Future<void> close(EditorController c) async {
    final index = _tabs.indexOf(c);
    if (index < 0) return;
    final wasActive = index == _active;
    final wasSplit = identical(c, _split);
    _tabs.removeAt(index);
    if (wasSplit) _endSplit();
    if (index < _active || (wasActive && _active >= _tabs.length)) _active--;
    if (wasActive) _avoidShowingTwice(index);
    if (wasActive || wasSplit) focused?.resume();
    notifyListeners();
    try {
      await c.close();
    } finally {
      sync.unregisterSaver(c);
      c.dispose();
    }
    unawaited(sync.syncNow());
  }

  void _endSplit() {
    _split = null;
    _splitFocused = false;
  }

  /// The left pane lost its notebook and fell back on a neighbour: when that is the one
  /// the right pane shows, take another tab instead, or go back to one pane.
  void _avoidShowingTwice(int near) {
    final right = _split;
    if (right == null || !identical(active, right)) return;
    final others = [
      for (var i = near; i < _tabs.length; i++) _tabs[i],
      for (var i = math.min(near, _tabs.length) - 1; i >= 0; i--) _tabs[i],
    ].where((t) => !identical(t, right));
    final other = others.firstOrNull;
    if (other != null) {
      _active = _tabs.indexOf(other);
    } else {
      _endSplit();
    }
  }

  /// Writes every tab's pending edits and refreshes their thumbnails (before the library
  /// is shown, or the app goes to the background).
  Future<void> saveAll() async {
    for (final c in List.of(_tabs)) {
      await c.save(thumbnail: true);
    }
  }

  /// Before the library renames or moves [entry]: saves the tabs inside it and lets go of
  /// their files. Follow up with [relocated].
  Future<void> releaseFiles(LibraryEntry entry) async {
    for (final c in tabsWithin(entry)) {
      await c.releaseFiles();
    }
  }

  /// [from] (a notebook or a folder) is at [to] now: the tabs inside it follow. After a
  /// failed rename / move, pass the old path twice (reopens what [releaseFiles] closed).
  void relocated(String from, String to) {
    for (final c in List.of(_tabs)) {
      final path = LibraryService.rebase(c.entry.path, from, to);
      if (path != null) c.relocate(Directory(path));
    }
    notifyListeners();
  }

  /// Closes the tabs inside [entry] **without saving**: it is about to be deleted.
  void discard(LibraryEntry entry) {
    final doomed = tabsWithin(entry);
    if (doomed.isEmpty) return;
    final current = active;
    final at = _active;
    _tabs.removeWhere(doomed.contains);
    if (_split != null && doomed.contains(_split)) _endSplit();
    _active = _tabs.isEmpty
        ? -1
        : current != null && _tabs.contains(current)
        ? _tabs.indexOf(current)
        : math.min(math.max(_active, 0), _tabs.length - 1);
    if (current == null || !_tabs.contains(current)) _avoidShowingTwice(math.max(0, math.min(at, _tabs.length)));
    for (final c in doomed) {
      sync.unregisterSaver(c);
      c.dispose();
    }
    notifyListeners();
  }

  void _message(String message) => onMessage?.call(message);

  /// Frees every tab without saving (the app is shutting down; [SyncService.flush] already
  /// saved them).
  @override
  void dispose() {
    for (final c in _tabs) {
      sync.unregisterSaver(c);
      c.dispose();
    }
    _tabs.clear();
    _active = -1;
    _endSplit();
    pins.dispose();
    super.dispose();
  }
}
