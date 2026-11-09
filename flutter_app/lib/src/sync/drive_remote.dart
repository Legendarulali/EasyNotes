import 'dart:async';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

/// A file or folder in the backup.
class RemoteEntry {
  const RemoteEntry(this.id, this.name, {this.md5});
  final String id;
  final String name;

  /// MD5 of the content (files only).
  final String? md5;
}

/// The remote item does not exist (deleted permanently or never created).
class RemoteNotFoundException implements Exception {
  const RemoteNotFoundException(this.message);
  final String message;

  @override
  String toString() => 'Not found on Google Drive: $message';
}

/// The small slice of Google Drive the backup needs. [GoogleDriveRemote] talks to
/// Drive API v3; tests use an in-memory fake.
abstract interface class DriveRemote {
  /// The backup root folder created by an earlier run (any device), if it still exists.
  Future<String?> findRoot();

  /// Creates the backup root folder in "My Drive".
  Future<String> createRoot(String name);

  /// Folder named [name] directly inside [parentId] (not trashed), if any.
  Future<String?> findFolder(String name, String parentId);

  Future<String> createFolder(String name, String parentId, {Map<String, String> properties});

  /// Folder of the notebook with backup key [key] uploaded earlier (e.g. before the app
  /// was reinstalled), if it still exists.
  Future<String?> findNotebookFolder(String key);

  /// Items directly inside [folderId] (not trashed).
  Future<List<RemoteEntry>> listChildren(String folderId);

  /// `true` if [id] exists and is not in the trash.
  Future<bool> isAlive(String id);

  /// Creates a file in [parentId], or replaces the content of [fileId]. Throws
  /// [RemoteNotFoundException] if [fileId] no longer exists.
  Future<RemoteEntry> upload({
    required String name,
    required String parentId,
    required Uint8List bytes,
    required String mimeType,
    String? fileId,
  });

  /// Renames [id] and makes [parentId] its only parent.
  Future<void> move(String id, {required String parentId, required String name});

  /// Moves [id] to the Drive trash (recoverable there for 30 days).
  Future<void> trash(String id);
}

/// [DriveRemote] backed by the Drive API v3, with the `drive.file` scope: the app only
/// sees and changes files it created itself.
class GoogleDriveRemote implements DriveRemote {
  GoogleDriveRemote(http.Client client) : _api = drive.DriveApi(client);

  final drive.DriveApi _api;

  static const String folderMime = 'application/vnd.google-apps.folder';
  static const String rootProperty = 'easynotesRoot';
  static const String notebookProperty = 'easynotesId';

  /// Files above this size use a resumable upload (multipart uploads are limited to 5 MB).
  static const int _resumableThreshold = 4 * 1024 * 1024;

  /// Drive query string literal (`'` and `\` escaped).
  static String _quote(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) throw RemoteNotFoundException(e.message ?? 'item');
      rethrow;
    }
  }

  Future<String?> _first(String q) => _guard(() async {
    final list = await _api.files.list(q: q, spaces: 'drive', pageSize: 10, $fields: 'files(id)');
    return list.files?.map((f) => f.id).whereType<String>().firstOrNull;
  });

  @override
  Future<String?> findRoot() => _first(
    "appProperties has { key='$rootProperty' and value='1' } and mimeType='$folderMime' and trashed=false",
  );

  @override
  Future<String> createRoot(String name) => _create(
    drive.File(name: name, mimeType: folderMime, parents: ['root'], appProperties: {rootProperty: '1'}),
  );

  @override
  Future<String?> findFolder(String name, String parentId) =>
      _first('name=${_quote(name)} and ${_quote(parentId)} in parents and mimeType=\'$folderMime\' and trashed=false');

  @override
  Future<String> createFolder(String name, String parentId, {Map<String, String> properties = const {}}) => _create(
    drive.File(
      name: name,
      mimeType: folderMime,
      parents: [parentId],
      appProperties: properties.isEmpty ? null : properties,
    ),
  );

  @override
  Future<String?> findNotebookFolder(String key) => _first(
    "appProperties has { key='$notebookProperty' and value=${_quote(key)} } and mimeType='$folderMime' and trashed=false",
  );

  @override
  Future<List<RemoteEntry>> listChildren(String folderId) => _guard(() async {
    final out = <RemoteEntry>[];
    String? page;
    do {
      final list = await _api.files.list(
        q: '${_quote(folderId)} in parents and trashed=false',
        spaces: 'drive',
        pageSize: 100,
        pageToken: page,
        $fields: 'nextPageToken, files(id, name, md5Checksum)',
      );
      for (final f in list.files ?? const <drive.File>[]) {
        if (f.id != null && f.name != null) out.add(RemoteEntry(f.id!, f.name!, md5: f.md5Checksum));
      }
      page = list.nextPageToken;
    } while (page != null);
    return out;
  });

  @override
  Future<bool> isAlive(String id) async {
    try {
      final f = await _guard(() => _api.files.get(id, $fields: 'id, trashed')) as drive.File;
      return f.trashed != true;
    } on RemoteNotFoundException {
      return false;
    }
  }

  @override
  Future<RemoteEntry> upload({
    required String name,
    required String parentId,
    required Uint8List bytes,
    required String mimeType,
    String? fileId,
  }) => _guard(() async {
    final media = drive.Media(Stream.value(bytes), bytes.length, contentType: mimeType);
    final options = bytes.length > _resumableThreshold ? drive.ResumableUploadOptions() : drive.UploadOptions.defaultOptions;
    final f = fileId == null
        ? await _api.files.create(
            drive.File(name: name, parents: [parentId]),
            uploadMedia: media,
            uploadOptions: options,
            $fields: 'id, md5Checksum',
          )
        : await _api.files.update(
            drive.File(),
            fileId,
            uploadMedia: media,
            uploadOptions: options,
            $fields: 'id, md5Checksum',
          );
    return RemoteEntry(f.id ?? fileId!, name, md5: f.md5Checksum);
  });

  @override
  Future<void> move(String id, {required String parentId, required String name}) => _guard(() async {
    final current = await _api.files.get(id, $fields: 'parents') as drive.File;
    final old = (current.parents ?? const <String>[]).where((p) => p != parentId).toList();
    final hasParent = current.parents?.contains(parentId) ?? false;
    await _api.files.update(
      drive.File(name: name),
      id,
      addParents: hasParent ? null : parentId,
      removeParents: old.isEmpty ? null : old.join(','),
      $fields: 'id',
    );
  });

  @override
  Future<void> trash(String id) => _guard(() async {
    await _api.files.update(drive.File(trashed: true), id, $fields: 'id');
  });

  Future<String> _create(drive.File f) => _guard(() async {
    final created = await _api.files.create(f, $fields: 'id');
    final id = created.id;
    if (id == null) throw StateError('Google Drive did not return an id for "${f.name}".');
    return id;
  });
}
