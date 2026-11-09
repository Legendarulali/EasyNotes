import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../rust/document/page.dart';
import '../rust/document/paper.dart';

/// Extension of notebook bundle directories.
const String kNotebookExtension = '.enote';

/// What the "New" menu can create.
enum NotebookTemplate {
  ruled('Ruled Notebook', DocumentKind.notebook, PaperStyle.dictando),
  grid('Grid Notebook', DocumentKind.notebook, PaperStyle.matematica),
  whiteboard('Blank Whiteboard', DocumentKind.whiteboard, PaperStyle.whiteboard);

  const NotebookTemplate(this.label, this.kind, this.paper);
  final String label;
  final DocumentKind kind;
  final PaperStyle paper;
}

/// Home-screen metadata of a notebook (cached in `meta.json` so listing the library
/// never has to open documents).
class NotebookMeta {
  const NotebookMeta({
    this.id = '',
    required this.kind,
    required this.paper,
    required this.pageCount,
    required this.created,
    required this.modified,
  });

  /// Stable random identifier that survives renames and moves (the Drive backup uses it
  /// to move the cloud copy instead of uploading it again). Empty if `meta.json` is
  /// missing or unreadable.
  final String id;
  final DocumentKind kind;
  final PaperStyle paper;
  final int pageCount;
  final DateTime created;
  final DateTime modified;

  NotebookMeta copyWith({String? id, PaperStyle? paper, int? pageCount, DateTime? modified}) => NotebookMeta(
    id: id ?? this.id,
    kind: kind,
    paper: paper ?? this.paper,
    pageCount: pageCount ?? this.pageCount,
    created: created,
    modified: modified ?? this.modified,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    if (id.isNotEmpty) 'id': id,
    'kind': kind.name,
    'paper': paper.name,
    'pages': pageCount,
    'created': created.toUtc().toIso8601String(),
    'modified': modified.toUtc().toIso8601String(),
  };

  static NotebookMeta fromJson(Map<String, Object?> j, {required DateTime fallbackTime}) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    DateTime time(Object? v) => (v is String ? DateTime.tryParse(v)?.toLocal() : null) ?? fallbackTime;
    final id = j['id'];
    return NotebookMeta(
      id: id is String ? id : '',
      kind: byName(DocumentKind.values, j['kind'], DocumentKind.notebook),
      paper: byName(PaperStyle.values, j['paper'], PaperStyle.dictando),
      pageCount: (j['pages'] as num?)?.toInt() ?? 1,
      created: time(j['created']),
      modified: time(j['modified']),
    );
  }
}

/// 128-bit random notebook identifier (hex).
String newNotebookId() {
  final r = Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// A folder or a notebook in the library.
sealed class LibraryEntry {
  const LibraryEntry(this.dir);
  final Directory dir;

  String get name;
  String get path => dir.path;
}

class FolderEntry extends LibraryEntry {
  const FolderEntry(super.dir, {required this.itemCount});
  final int itemCount;

  @override
  String get name => _basename(dir.path);
}

/// A notebook bundle directory:
///
/// ```text
/// Lecture notes.enote/
///   content.ezn      document (Rust engine format)
///   background.pdf   imported PDF (PDF documents only)
///   meta.json        kind, paper, page count, timestamps
///   thumb.png        first-page preview
/// ```
class NotebookEntry extends LibraryEntry {
  const NotebookEntry(super.dir, this.meta);
  final NotebookMeta meta;

  @override
  String get name {
    final base = _basename(dir.path);
    return base.endsWith(kNotebookExtension) ? base.substring(0, base.length - kNotebookExtension.length) : base;
  }

  File get documentFile => File(_join(dir.path, 'content.ezn'));
  File get pdfFile => File(_join(dir.path, 'background.pdf'));
  File get metaFile => File(_join(dir.path, 'meta.json'));
  File get thumbnailFile => File(_join(dir.path, 'thumb.png'));
  bool get isPdf => meta.kind == DocumentKind.pdfAnnotation;
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

/// Folders and notebooks stored as plain directories under one library root.
class LibraryService {
  LibraryService(this.root);

  final Directory root;

  /// The library inside the app documents directory (`Documents/EasyNotes` on desktop).
  static Future<LibraryService> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(_join(docs.path, 'EasyNotes'));
    await root.create(recursive: true);
    return LibraryService(root);
  }

  // ------------------------------------------------------------------ listing

  bool isRoot(Directory folder) => _same(folder.path, root.path);

  /// Folders first (A–Z), then notebooks (most recently modified first).
  Future<List<LibraryEntry>> list(Directory folder) async {
    final folders = <FolderEntry>[];
    final notebooks = <NotebookEntry>[];
    if (!await folder.exists()) return const [];
    await for (final e in folder.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = _basename(e.path);
      if (name.startsWith('.')) continue;
      if (name.endsWith(kNotebookExtension)) {
        notebooks.add(await readNotebook(e));
      } else {
        final count = await e.list(followLinks: false).where((c) => c is Directory).length;
        folders.add(FolderEntry(e, itemCount: count));
      }
    }
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notebooks.sort((a, b) => b.meta.modified.compareTo(a.meta.modified));
    return [...folders, ...notebooks];
  }

  Future<NotebookEntry> readNotebook(Directory dir) async {
    final entry = NotebookEntry(dir, _defaultMeta(DateTime.now()));
    DateTime fallback;
    try {
      fallback = (await dir.stat()).modified;
    } catch (_) {
      fallback = DateTime.now();
    }
    Object? json;
    try {
      json = jsonDecode(await entry.metaFile.readAsString());
    } catch (_) {
      // Missing / corrupt metadata: fall back to defaults, the document itself is intact.
    }
    if (json is! Map<String, Object?>) return NotebookEntry(dir, _defaultMeta(fallback));
    final meta = NotebookMeta.fromJson(json, fallbackTime: fallback);
    if (meta.id.isNotEmpty) return NotebookEntry(dir, meta);
    // Notebooks from before stable ids: assign one once.
    final withId = meta.copyWith(id: newNotebookId());
    try {
      return await writeMeta(NotebookEntry(dir, meta), withId);
    } catch (_) {
      return NotebookEntry(dir, meta);
    }
  }

  static NotebookMeta _defaultMeta(DateTime t) =>
      NotebookMeta(kind: DocumentKind.notebook, paper: PaperStyle.dictando, pageCount: 1, created: t, modified: t);

  /// All folders (depth-first) for the "Move to…" picker, root first.
  Future<List<Directory>> allFolders() async {
    final out = <Directory>[root];
    Future<void> walk(Directory d) async {
      final children = <Directory>[];
      await for (final e in d.list(followLinks: false)) {
        final name = _basename(e.path);
        if (e is Directory && !name.endsWith(kNotebookExtension) && !name.startsWith('.')) children.add(e);
      }
      children.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final c in children) {
        out.add(c);
        await walk(c);
      }
    }

    await walk(root);
    return out;
  }

  /// Folder names from the root down to [folder] (empty for the root itself).
  List<String> breadcrumbs(Directory folder) {
    final rel = relativePath(folder);
    return rel.isEmpty ? const [] : rel.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  }

  String relativePath(Directory folder) {
    final r = root.absolute.path;
    final f = folder.absolute.path;
    if (_same(f, r)) return '';
    return f.length > r.length && _fold(f).startsWith(_fold(r)) ? f.substring(r.length + 1) : f;
  }

  // ------------------------------------------------------------------ creation

  Future<FolderEntry> createFolder(Directory parent, String name) async {
    final dir = Directory(_join(parent.path, uniqueName(parent, sanitizeName(name, fallback: 'New folder'))));
    await dir.create(recursive: true);
    return FolderEntry(dir, itemCount: 0);
  }

  Future<NotebookEntry> createNotebook(Directory parent, String name, NotebookTemplate template) =>
      _createBundle(parent, name, template.kind, template.paper);

  /// Copies [pdfBytes] into a new PDF annotation notebook.
  Future<NotebookEntry> importPdf(Directory parent, String name, Uint8List pdfBytes) async {
    if (pdfBytes.length < 5 || String.fromCharCodes(pdfBytes.take(5)) != '%PDF-') {
      throw const FormatException('The selected file is not a PDF.');
    }
    final entry = await _createBundle(parent, name, DocumentKind.pdfAnnotation, PaperStyle.whiteboard);
    await entry.pdfFile.writeAsBytes(pdfBytes, flush: true);
    return entry;
  }

  Future<NotebookEntry> _createBundle(Directory parent, String name, DocumentKind kind, PaperStyle paper) async {
    final base = sanitizeName(name, fallback: 'Untitled');
    final dir = Directory(_join(parent.path, '${uniqueName(parent, base, notebook: true)}$kNotebookExtension'));
    await dir.create(recursive: true);
    final now = DateTime.now();
    final entry = NotebookEntry(
      dir,
      NotebookMeta(id: newNotebookId(), kind: kind, paper: paper, pageCount: 1, created: now, modified: now),
    );
    await writeMeta(entry, entry.meta);
    return entry;
  }

  Future<NotebookEntry> writeMeta(NotebookEntry entry, NotebookMeta meta) async {
    await entry.metaFile.writeAsString(jsonEncode(meta.toJson()), flush: true);
    return NotebookEntry(entry.dir, meta);
  }

  // ------------------------------------------------------------------ editing

  Future<LibraryEntry> rename(LibraryEntry entry, String newName) async {
    final parent = entry.dir.parent;
    final isNotebook = entry is NotebookEntry;
    final clean = sanitizeName(newName, fallback: entry.name);
    if (clean == entry.name) return entry;
    final unique = uniqueName(parent, clean, notebook: isNotebook);
    final target = _join(parent.path, isNotebook ? '$unique$kNotebookExtension' : unique);
    final dir = await entry.dir.rename(target);
    return switch (entry) {
      NotebookEntry(:final meta) => NotebookEntry(dir, meta),
      FolderEntry(:final itemCount) => FolderEntry(dir, itemCount: itemCount),
    };
  }

  Future<void> delete(LibraryEntry entry) => entry.dir.delete(recursive: true);

  /// Moves [entry] into [target]. Folders cannot be moved into themselves.
  Future<LibraryEntry> move(LibraryEntry entry, Directory target) async {
    final from = entry.dir.absolute.path;
    final to = target.absolute.path;
    if (_same(entry.dir.parent.path, to)) return entry;
    if (entry is FolderEntry && (_same(from, to) || _fold(to).startsWith(_fold('$from${Platform.pathSeparator}')))) {
      throw ArgumentError('A folder cannot be moved into itself.');
    }
    final isNotebook = entry is NotebookEntry;
    final unique = uniqueName(target, entry.name, notebook: isNotebook);
    final dir = await entry.dir.rename(_join(target.path, isNotebook ? '$unique$kNotebookExtension' : unique));
    return switch (entry) {
      NotebookEntry(:final meta) => NotebookEntry(dir, meta),
      FolderEntry(:final itemCount) => FolderEntry(dir, itemCount: itemCount),
    };
  }

  // ------------------------------------------------------------------ settings

  File get _settingsFile => File(_join(root.path, '.settings.json'));

  /// Small app-wide preferences (e.g. where the floating toolbar was docked).
  Future<Map<String, Object?>> readSettings() async {
    try {
      final json = jsonDecode(await _settingsFile.readAsString());
      if (json is Map<String, Object?>) return json;
    } catch (_) {
      // First run or unreadable: defaults.
    }
    return {};
  }

  Future<void> updateSettings(Map<String, Object?> changes) async {
    final current = await readSettings();
    current.addAll(changes);
    await _settingsFile.writeAsString(jsonEncode(current), flush: true);
  }

  // ------------------------------------------------------------------ names

  static final RegExp _forbidden = RegExp(r'[\\/:*?"<>|\x00-\x1F]');

  /// File-system safe display name (keeps Unicode such as ă î ș ț).
  static String sanitizeName(String name, {required String fallback}) {
    var s = name.replaceAll(_forbidden, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    if (s.length > 80) s = s.substring(0, 80).trimRight();
    return s.isEmpty ? fallback : s;
  }

  /// `name`, or `name (2)`, `name (3)`… if it is taken in [parent].
  String uniqueName(Directory parent, String name, {bool notebook = false}) {
    bool taken(String candidate) {
      final path = _join(parent.path, notebook ? '$candidate$kNotebookExtension' : candidate);
      return Directory(path).existsSync() || File(path).existsSync();
    }

    if (!taken(name)) return name;
    for (var i = 2; ; i++) {
      final candidate = '$name ($i)';
      if (!taken(candidate)) return candidate;
    }
  }

  /// Suggested default name for a new notebook of [template].
  String suggestName(Directory parent, NotebookTemplate template) => uniqueName(
    parent,
    switch (template) {
      NotebookTemplate.ruled => 'Ruled notebook',
      NotebookTemplate.grid => 'Grid notebook',
      NotebookTemplate.whiteboard => 'Whiteboard',
    },
    notebook: true,
  );

  /// Windows and macOS file systems are case-insensitive by default.
  static String _fold(String p) => Platform.isWindows || Platform.isMacOS ? p.toLowerCase() : p;

  static bool _same(String a, String b) {
    String norm(String p) => _fold(Directory(p).absolute.path.replaceAll(RegExp(r'[\\/]+$'), ''));
    return norm(a) == norm(b);
  }
}
