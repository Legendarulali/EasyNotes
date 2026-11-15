import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/library_service.dart';
import '../sync/sync_service.dart';
import 'editor_controller.dart';

/// The notebooks open as editor tabs, in tab order, and which one is showing.
///
/// Owns their [EditorController]s, so a tab keeps its undo history, viewport, selection
/// and tools while another tab is shown, and while the library is on screen. The engine
/// edits one document at a time; switching tabs only re-points it, nothing is reloaded.
class OpenNotebooks extends ChangeNotifier {
  OpenNotebooks({required this.library, required this.sync});

  final LibraryService library;

  /// Every tab is saved by [SyncService.flush] (app hidden / closing) before the upload.
  final SyncService sync;

  /// Where the tabs' messages (e.g. a failed save) are shown; set by the editor screen.
  void Function(String message)? onMessage;

  final List<EditorController> _tabs = [];
  int _active = -1;

  List<EditorController> get tabs => List.unmodifiable(_tabs);
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;
  bool get isNotEmpty => _tabs.isNotEmpty;
  int get activeIndex => _active;
  EditorController? get active => _active < 0 ? null : _tabs[_active];

  /// The tab showing [entry], if it is open.
  EditorController? tabOf(NotebookEntry entry) =>
      _tabs.where((c) => LibraryService.samePath(c.entry.path, entry.path)).firstOrNull;

  /// The tabs of [entry] (a notebook) or of the notebooks somewhere inside it (a folder).
  List<EditorController> tabsWithin(LibraryEntry entry) =>
      _tabs.where((c) => LibraryService.isWithin(c.entry.path, entry.path)).toList();

  /// Shows [entry]: switches to its tab when it is open already, otherwise opens it in a
  /// new tab right after the current one.
  EditorController open(NotebookEntry entry) {
    final existing = tabOf(entry);
    if (existing != null) {
      activate(_tabs.indexOf(existing));
      return existing;
    }
    final previous = active;
    final c = EditorController(entry: entry, library: library)
      ..onMessage = _message
      ..onSaved = sync.markPending;
    if (previous != null) c.adoptInputMode(previous);
    sync.registerSaver(c, () => c.save(thumbnail: true));
    _tabs.insert(_active + 1, c);
    _active++;
    if (previous != null) unawaited(previous.suspend());
    unawaited(c.open());
    notifyListeners();
    return c;
  }

  /// Shows the tab at [index]. The tab that was showing writes its pending edits.
  void activate(int index) {
    if (index == _active || index < 0 || index >= _tabs.length) return;
    final previous = active;
    _active = index;
    if (previous != null) unawaited(previous.suspend());
    _tabs[index].resume();
    notifyListeners();
  }

  /// The next (`step` 1) or previous (`step` -1) tab, wrapping around (Ctrl+Tab).
  void cycle(int step) {
    if (_tabs.length > 1) activate((_active + step) % _tabs.length);
  }

  /// Closes the tab of [c]: blank trailing pages are trimmed, the notebook is saved (with
  /// its library thumbnail) and its document freed. The tab to the right (or, for the last
  /// tab, to the left) takes over.
  Future<void> close(EditorController c) async {
    final index = _tabs.indexOf(c);
    if (index < 0) return;
    final wasActive = index == _active;
    _tabs.removeAt(index);
    if (index < _active || (wasActive && _active >= _tabs.length)) _active--;
    if (wasActive) active?.resume();
    notifyListeners();
    try {
      await c.close();
    } finally {
      sync.unregisterSaver(c);
      c.dispose();
    }
    unawaited(sync.syncNow());
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
    _tabs.removeWhere(doomed.contains);
    _active = _tabs.isEmpty
        ? -1
        : current != null && _tabs.contains(current)
        ? _tabs.indexOf(current)
        : math.min(math.max(_active, 0), _tabs.length - 1);
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
    super.dispose();
  }
}
