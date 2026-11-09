import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../services/library_service.dart';
import 'drive_remote.dart';

/// What one backup run did.
class BackupReport {
  int uploadedFiles = 0;
  int uploadedBytes = 0;
  int unchangedFiles = 0;
  int movedNotebooks = 0;
  int removedNotebooks = 0;

  bool get changedAnything => uploadedFiles + movedNotebooks + removedNotebooks > 0;

  @override
  String toString() =>
      'uploaded $uploadedFiles file(s) ($uploadedBytes B), moved $movedNotebooks, removed $removedNotebooks, '
      'unchanged $unchangedFiles';
}

/// MD5 of [bytes] as lowercase hex (Drive's `md5Checksum` format). Large inputs are
/// hashed on a background isolate so the UI never stalls.
Future<String> md5Hex(Uint8List bytes) async {
  if (bytes.length < 256 * 1024) return md5.convert(bytes).toString();
  return Isolate.run(() => md5.convert(bytes).toString());
}

/// Push-only mirror of the local library into `My Drive/EasyNotes/`.
///
/// Folders become Drive folders and each notebook bundle a Drive folder holding its files
/// (`content.ezn`, `background.pdf`, `meta.json`, `thumb.png`), so the backup can be
/// browsed and downloaded from drive.google.com and dropped back into the library.
///
/// * **Incremental.** A local state file remembers, per uploaded file, its Drive id,
///   size, modification time and MD5. A run with no local changes makes no network
///   requests at all; a changed file is hashed first and only uploaded if its content
///   really differs (a re-rendered but identical thumbnail is skipped).
/// * **Renames / moves** of notebooks (tracked by their stable id in `meta.json`) move
///   the Drive folder instead of uploading the bundle again.
/// * **Deletes** move the notebook's Drive folder to the Drive trash (recoverable for 30
///   days). Only items this device uploaded are ever touched; a folder is only trashed
///   once it no longer holds anything.
/// * **Resumable.** The state is saved after every operation; a failure (e.g. going
///   offline) aborts the run and the next run continues where it stopped. After a
///   reinstall the existing backup is found again and adopted instead of duplicated.
class BackupEngine {
  BackupEngine({required this.library, required this.remote, required this.account});

  final LibraryService library;
  final DriveRemote remote;

  /// Google account the backup belongs to (switching accounts starts a fresh state).
  final String account;

  /// Name of the backup root in "My Drive".
  static const String rootName = 'EasyNotes';

  /// Bundle files that are backed up, with their MIME types.
  static const Map<String, String> syncedFiles = {
    'content.ezn': 'application/octet-stream',
    'background.pdf': 'application/pdf',
    'meta.json': 'application/json',
    'thumb.png': 'image/png',
  };

  File get stateFile => File('${library.root.path}${Platform.pathSeparator}.backup-state.json');

  final Set<String> _verified = {};

  // ------------------------------------------------------------------ public

  /// `true` if anything changed locally since the last completed upload (no network).
  Future<bool> hasPendingChanges() async => _hasWork(await _loadState(), await _scan());

  /// Uploads everything that changed. Throws on the first failure; work done before it
  /// is kept and not repeated by the next run.
  Future<BackupReport> run() async {
    final report = BackupReport();
    final state = await _loadState();
    final scan = await _scan();
    if (!_hasWork(state, scan)) return report;
    _verified.clear();

    await _ensureRoot(state);

    final localFolders = scan.folders.toSet();
    for (final path in scan.folders) {
      if (!state.folders.containsKey(path)) await _folderId(state, path);
    }

    for (final nb in scan.notebooks) {
      await _pushNotebook(state, nb, report);
    }

    final localKeys = {for (final nb in scan.notebooks) nb.key};
    for (final key in state.notebooks.keys.where((k) => !localKeys.contains(k)).toList()) {
      await _ignoreMissing(() => remote.trash(state.notebooks[key]!.folderId));
      state.notebooks.remove(key);
      report.removedNotebooks++;
      await _saveState(state);
    }

    // Folders that disappeared locally (deleted or renamed): deepest first, and only
    // once nothing is left in them (another device may still keep notebooks there).
    final stale = state.folders.keys.where((p) => !localFolders.contains(p)).toList()
      ..sort((a, b) => b.split('/').length.compareTo(a.split('/').length));
    for (final path in stale) {
      final id = state.folders.remove(path)!;
      await _ignoreMissing(() async {
        if ((await remote.listChildren(id)).isEmpty) await remote.trash(id);
      });
      await _saveState(state);
    }
    return report;
  }

  // ------------------------------------------------------------------ steps

  Future<void> _ensureRoot(_State state) async {
    final known = state.rootId;
    if (known != null && await remote.isAlive(known)) {
      _verified.add(known);
      return;
    }
    // First run, or the backup folder was deleted in Drive: find an existing backup
    // (earlier install / other device) or start a new one. Everything recorded for the
    // old root is void.
    final root = await remote.findRoot() ?? await remote.createRoot(rootName);
    state
      ..rootId = root
      ..folders.clear()
      ..notebooks.clear();
    _verified.add(root);
    await _saveState(state);
  }

  /// Drive folder for the library folder at relative [path] (`a/b`), created if needed.
  Future<String> _folderId(_State state, String path) async {
    if (path.isEmpty) return state.rootId!;
    final known = state.folders[path];
    if (known != null && (_verified.contains(known) || await remote.isAlive(known))) {
      _verified.add(known);
      return known;
    }
    final slash = path.lastIndexOf('/');
    final parent = await _folderId(state, slash < 0 ? '' : path.substring(0, slash));
    final name = path.substring(slash + 1);
    final id = await remote.findFolder(name, parent) ?? await remote.createFolder(name, parent);
    state.folders[path] = id;
    _verified.add(id);
    await _saveState(state);
    return id;
  }

  Future<void> _pushNotebook(_State state, _LocalNotebook nb, BackupReport report) async {
    var rec = state.notebooks[nb.key];
    if (rec != null && !rec.differsFrom(nb)) {
      report.unchangedFiles += nb.files.length;
      return;
    }
    if (rec != null && !await remote.isAlive(rec.folderId)) rec = null; // deleted in Drive

    if (rec == null) {
      final parentId = await _folderId(state, nb.parent);
      final files = <String, _FileRecord>{};
      final existing = await remote.findNotebookFolder(nb.key);
      final String folderId;
      if (existing != null) {
        // Backup from an earlier install: adopt it (identical files are not re-uploaded).
        folderId = existing;
        await remote.move(folderId, parentId: parentId, name: nb.dirName);
        for (final child in await remote.listChildren(folderId)) {
          if (syncedFiles.containsKey(child.name)) {
            files[child.name] = _FileRecord(child.id, size: -1, modified: -1, md5: child.md5 ?? '');
          }
        }
      } else {
        folderId = await remote.createFolder(nb.dirName, parentId, properties: {GoogleDriveRemote.notebookProperty: nb.key});
      }
      rec = _NotebookRecord(folderId, parent: nb.parent, name: nb.dirName, files: files);
      state.notebooks[nb.key] = rec;
      await _saveState(state);
    } else if (rec.parent != nb.parent || rec.name != nb.dirName) {
      await remote.move(rec.folderId, parentId: await _folderId(state, nb.parent), name: nb.dirName);
      rec
        ..parent = nb.parent
        ..name = nb.dirName;
      report.movedNotebooks++;
      await _saveState(state);
    }

    for (final MapEntry(key: name, value: local) in nb.files.entries) {
      final known = rec.files[name];
      if (known != null && known.size == local.size && known.modified == local.modified) {
        report.unchangedFiles++;
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await local.file.readAsBytes();
      } on FileSystemException {
        continue; // removed / replaced while scanning: picked up by the next run
      }
      final digest = await md5Hex(bytes);
      if (known != null && known.md5 == digest) {
        rec.files[name] = _FileRecord(known.id, size: local.size, modified: local.modified, md5: digest);
        report.unchangedFiles++;
        await _saveState(state);
        continue;
      }
      final mime = syncedFiles[name]!;
      RemoteEntry uploaded;
      try {
        uploaded = await remote.upload(name: name, parentId: rec.folderId, bytes: bytes, mimeType: mime, fileId: known?.id);
      } on RemoteNotFoundException {
        uploaded = await remote.upload(name: name, parentId: rec.folderId, bytes: bytes, mimeType: mime);
      }
      rec.files[name] = _FileRecord(uploaded.id, size: local.size, modified: local.modified, md5: digest);
      report.uploadedFiles++;
      report.uploadedBytes += bytes.length;
      await _saveState(state);
    }

    for (final name in rec.files.keys.where((n) => !nb.files.containsKey(n)).toList()) {
      await _ignoreMissing(() => remote.trash(rec!.files[name]!.id));
      rec.files.remove(name);
      await _saveState(state);
    }
  }

  static Future<void> _ignoreMissing(Future<void> Function() op) async {
    try {
      await op();
    } on RemoteNotFoundException {
      // Already gone: nothing to do.
    }
  }

  // ------------------------------------------------------------------ local scan

  bool _hasWork(_State state, _LocalScan scan) {
    if (state.rootId == null) return scan.notebooks.isNotEmpty || scan.folders.isNotEmpty;
    final keys = <String>{};
    for (final nb in scan.notebooks) {
      keys.add(nb.key);
      final rec = state.notebooks[nb.key];
      if (rec == null || rec.differsFrom(nb)) return true;
    }
    if (state.notebooks.keys.any((k) => !keys.contains(k))) return true;
    final folders = scan.folders.toSet();
    return folders.any((f) => !state.folders.containsKey(f)) || state.folders.keys.any((f) => !folders.contains(f));
  }

  Future<_LocalScan> _scan() async {
    final scan = _LocalScan();
    final seen = <String>{};
    Future<void> walk(Directory dir, String rel) async {
      final children = <Directory>[];
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is Directory) children.add(e);
        }
      } on FileSystemException {
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final d in children) {
        final name = d.path.split(RegExp(r'[\\/]')).lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name.isEmpty) continue;
        if (name.startsWith('.')) continue;
        final childRel = rel.isEmpty ? name : '$rel/$name';
        if (name.endsWith(kNotebookExtension)) {
          final entry = await library.readNotebook(d);
          // Missing metadata (no id) or a bundle copied by hand (duplicate id): key by path.
          var key = entry.meta.id.isEmpty ? 'path:$childRel' : entry.meta.id;
          if (!seen.add(key)) key = '$key@$childRel';
          final files = <String, _LocalFile>{};
          for (final f in syncedFiles.keys) {
            final file = File('${d.path}${Platform.pathSeparator}$f');
            final stat = await file.stat();
            if (stat.type == FileSystemEntityType.file) {
              files[f] = _LocalFile(file, stat.size, stat.modified.millisecondsSinceEpoch);
            }
          }
          scan.notebooks.add(_LocalNotebook(key, parent: rel, dirName: name, files: files));
        } else {
          scan.folders.add(childRel);
          await walk(d, childRel);
        }
      }
    }

    await walk(library.root, '');
    return scan;
  }

  // ------------------------------------------------------------------ state file

  Future<_State> _loadState() async {
    try {
      final json = jsonDecode(await stateFile.readAsString());
      if (json is Map<String, Object?> && json['account'] == account) return _State.fromJson(json);
    } catch (_) {
      // First run or unreadable: start over (existing backups are adopted, not duplicated).
    }
    return _State(account);
  }

  Future<void> _saveState(_State state) async {
    final tmp = File('${stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(stateFile.path);
  }
}

class _LocalScan {
  final List<String> folders = [];
  final List<_LocalNotebook> notebooks = [];
}

class _LocalNotebook {
  _LocalNotebook(this.key, {required this.parent, required this.dirName, required this.files});
  final String key;
  final String parent;
  final String dirName;
  final Map<String, _LocalFile> files;
}

class _LocalFile {
  _LocalFile(this.file, this.size, this.modified);
  final File file;
  final int size;
  final int modified;
}

class _State {
  _State(this.account);

  final String account;
  String? rootId;
  final Map<String, String> folders = {};
  final Map<String, _NotebookRecord> notebooks = {};

  Map<String, Object?> toJson() => {
    'version': 1,
    'account': account,
    'root': rootId,
    'folders': folders,
    'notebooks': {for (final e in notebooks.entries) e.key: e.value.toJson()},
  };

  static _State fromJson(Map<String, Object?> j) {
    final s = _State(j['account'] as String)..rootId = j['root'] as String?;
    final folders = j['folders'];
    if (folders is Map) {
      for (final e in folders.entries) {
        if (e.key is String && e.value is String) s.folders[e.key as String] = e.value as String;
      }
    }
    final notebooks = j['notebooks'];
    if (notebooks is Map) {
      for (final e in notebooks.entries) {
        final rec = _NotebookRecord.fromJson(e.value);
        if (e.key is String && rec != null) s.notebooks[e.key as String] = rec;
      }
    }
    return s;
  }
}

class _NotebookRecord {
  _NotebookRecord(this.folderId, {required this.parent, required this.name, required this.files});

  final String folderId;
  String parent;
  String name;
  final Map<String, _FileRecord> files;

  /// Moved, renamed, or any file added / changed / removed since the last upload.
  bool differsFrom(_LocalNotebook nb) {
    if (parent != nb.parent || name != nb.dirName || files.length != nb.files.length) return true;
    for (final MapEntry(:key, :value) in nb.files.entries) {
      final f = files[key];
      if (f == null || f.size != value.size || f.modified != value.modified) return true;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'folder': folderId,
    'parent': parent,
    'name': name,
    'files': {for (final e in files.entries) e.key: e.value.toJson()},
  };

  static _NotebookRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final folder = j['folder'], parent = j['parent'], name = j['name'];
    if (folder is! String || parent is! String || name is! String) return null;
    final files = <String, _FileRecord>{};
    final raw = j['files'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final f = _FileRecord.fromJson(e.value);
        if (e.key is String && f != null) files[e.key as String] = f;
      }
    }
    return _NotebookRecord(folder, parent: parent, name: name, files: files);
  }
}

class _FileRecord {
  const _FileRecord(this.id, {required this.size, required this.modified, required this.md5});

  final String id;
  final int size;
  final int modified;
  final String md5;

  Map<String, Object?> toJson() => {'id': id, 'size': size, 'modified': modified, 'md5': md5};

  static _FileRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], size = j['size'], modified = j['modified'], md5 = j['md5'];
    if (id is! String || size is! int || modified is! int || md5 is! String) return null;
    return _FileRecord(id, size: size, modified: modified, md5: md5);
  }
}
