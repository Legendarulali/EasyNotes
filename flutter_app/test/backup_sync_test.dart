import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/backup_engine.dart';
import 'package:flutter_app/src/sync/drive_remote.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/session_store.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------- fakes

class FakeNode {
  FakeNode(this.id, this.name, {required this.parents, this.folder = false, this.props = const {}});
  final String id;
  String name;
  List<String> parents;
  final bool folder;
  final Map<String, String> props;
  bool trashed = false;
  Uint8List? bytes;
}

/// In-memory Google Drive with Drive's trash semantics (children of a trashed folder
/// are trashed too) and an "offline" switch.
class FakeDrive implements DriveRemote {
  final Map<String, FakeNode> nodes = {};
  int _next = 0;
  int calls = 0;
  int uploads = 0;

  /// Throw a [SocketException] once this many calls have been made (`null` = online).
  int? offlineAfterCalls;

  void _call() {
    calls++;
    final limit = offlineAfterCalls;
    if (limit != null && calls > limit) throw const SocketException('Network is unreachable');
  }

  bool _trashed(FakeNode n) => n.trashed || n.parents.any((p) => nodes[p] != null && _trashed(nodes[p]!));

  Iterable<FakeNode> get _alive => nodes.values.where((n) => !_trashed(n));

  FakeNode _add(String name, List<String> parents, {bool folder = false, Map<String, String> props = const {}}) {
    final n = FakeNode('id${_next++}', name, parents: parents, folder: folder, props: props);
    nodes[n.id] = n;
    return n;
  }

  @override
  Future<String?> findRoot() async {
    _call();
    return _alive.where((n) => n.folder && n.props['easynotesRoot'] == '1').map((n) => n.id).firstOrNull;
  }

  @override
  Future<String> createRoot(String name) async {
    _call();
    return _add(name, ['root'], folder: true, props: {'easynotesRoot': '1'}).id;
  }

  @override
  Future<String?> findFolder(String name, String parentId) async {
    _call();
    return _alive.where((n) => n.folder && n.name == name && n.parents.contains(parentId)).map((n) => n.id).firstOrNull;
  }

  @override
  Future<String> createFolder(String name, String parentId, {Map<String, String> properties = const {}}) async {
    _call();
    return _add(name, [parentId], folder: true, props: properties).id;
  }

  @override
  Future<String?> findNotebookFolder(String key) async {
    _call();
    return _alive.where((n) => n.folder && n.props['easynotesId'] == key).map((n) => n.id).firstOrNull;
  }

  @override
  Future<List<RemoteEntry>> listChildren(String folderId) async {
    _call();
    return [
      for (final n in _alive)
        if (n.parents.contains(folderId))
          RemoteEntry(n.id, n.name, md5: n.bytes == null ? null : md5.convert(n.bytes!).toString()),
    ];
  }

  @override
  Future<bool> isAlive(String id) async {
    _call();
    final n = nodes[id];
    return n != null && !_trashed(n);
  }

  @override
  Future<RemoteEntry> upload({
    required String name,
    required String parentId,
    required Uint8List bytes,
    required String mimeType,
    String? fileId,
  }) async {
    _call();
    uploads++;
    final FakeNode n;
    if (fileId != null) {
      n = nodes[fileId] ?? (throw RemoteNotFoundException(fileId));
    } else {
      n = _add(name, [parentId]);
    }
    n.bytes = Uint8List.fromList(bytes);
    return RemoteEntry(n.id, name, md5: md5.convert(bytes).toString());
  }

  @override
  Future<void> move(String id, {required String parentId, required String name}) async {
    _call();
    final n = nodes[id] ?? (throw RemoteNotFoundException(id));
    n
      ..parents = [parentId]
      ..name = name;
  }

  @override
  Future<void> trash(String id) async {
    _call();
    (nodes[id] ?? (throw RemoteNotFoundException(id))).trashed = true;
  }

  String _path(FakeNode n) {
    final parent = n.parents.isEmpty ? null : nodes[n.parents.first];
    return parent == null ? n.name : '${_path(parent)}/${n.name}';
  }

  /// Live (not trashed) files as `EasyNotes/folder/Name.enote/file` → content.
  Map<String, String> get files => {
    for (final n in _alive)
      if (!n.folder) _path(n): utf8.decode(n.bytes ?? Uint8List(0), allowMalformed: true),
  };

  /// Live folder paths.
  Set<String> get folders => {for (final n in _alive.where((n) => n.folder)) _path(n)};
}

class FakeAuth implements GoogleAuth {
  FakeAuth({this.configured = true, this.stored});

  final bool configured;
  GoogleAccount? stored;
  Object? clientError;
  static const account = GoogleAccount(email: 'ana@example.com', name: 'Ana Pop');

  @override
  bool get isConfigured => configured;

  @override
  String get setupHint => 'not configured';

  @override
  Future<GoogleAccount?> restore() async => stored;

  @override
  Future<GoogleAccount> signIn() async => stored = account;

  @override
  void cancelSignIn() {}

  @override
  Future<void> signOut() async => stored = null;

  @override
  Future<http.Client> client() async {
    final e = clientError;
    if (e != null) throw e;
    return http.Client();
  }
}

// ---------------------------------------------------------------------------- helpers

Future<NotebookEntry> _notebook(LibraryService lib, Directory parent, String name, {String content = 'ink'}) async {
  final nb = await lib.createNotebook(parent, name, NotebookTemplate.ruled);
  await nb.documentFile.writeAsString(content);
  return nb;
}

Future<void> _touch(File f, String content) async {
  await f.writeAsString(content);
  // Make sure the modification time moves even on coarse file systems.
  await f.setLastModified(DateTime.now().add(const Duration(seconds: 3)));
}

void main() {
  late Directory tmp;
  late LibraryService lib;
  late FakeDrive drive;

  BackupEngine engine([String account = 'ana@example.com']) =>
      BackupEngine(library: lib, remote: drive, account: account);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easynotes_backup');
    lib = LibraryService(tmp);
    drive = FakeDrive();
  });
  tearDown(() => tmp.delete(recursive: true));

  group('BackupEngine', () {
    test('first run mirrors folders and notebooks into My Drive/EasyNotes', () async {
      final school = await lib.createFolder(tmp, 'Școală');
      final mate = await _notebook(lib, school.dir, 'Matematică', content: 'v1');
      await mate.thumbnailFile.writeAsString('png');
      await lib.createNotebook(tmp, 'Board', NotebookTemplate.whiteboard);
      await lib.createFolder(tmp, 'Empty');

      expect(await engine().hasPendingChanges(), isTrue);
      final report = await engine().run();

      expect(drive.files.keys, {
        'EasyNotes/Școală/Matematică.enote/content.ezn',
        'EasyNotes/Școală/Matematică.enote/meta.json',
        'EasyNotes/Școală/Matematică.enote/thumb.png',
        'EasyNotes/Board.enote/meta.json',
      });
      expect(drive.files['EasyNotes/Școală/Matematică.enote/content.ezn'], 'v1');
      expect(drive.folders, contains('EasyNotes/Empty'));
      expect(report.uploadedFiles, 4);
      expect(await engine().hasPendingChanges(), isFalse);
    });

    test('a run without local changes makes no network requests', () async {
      await _notebook(lib, tmp, 'A');
      await engine().run();
      drive.calls = 0;
      final report = await engine().run();
      expect(drive.calls, 0);
      expect(report.changedAnything, isFalse);
    });

    test('only changed files are uploaded; identical rewrites are skipped', () async {
      final a = await _notebook(lib, tmp, 'A', content: 'v1');
      await a.thumbnailFile.writeAsString('thumb');
      await engine().run();
      final uploads = drive.uploads;

      await _touch(a.documentFile, 'v2');
      final r1 = await engine().run();
      expect(r1.uploadedFiles, 1);
      expect(drive.files['EasyNotes/A.enote/content.ezn'], 'v2');

      // Thumbnail re-rendered with identical pixels: new mtime, same bytes → no upload.
      await _touch(a.thumbnailFile, 'thumb');
      expect(await engine().hasPendingChanges(), isTrue);
      final r2 = await engine().run();
      expect(r2.uploadedFiles, 0);
      expect(drive.uploads, uploads + 1);
      expect(await engine().hasPendingChanges(), isFalse);
    });

    test('renames and moves become Drive moves, not re-uploads', () async {
      final school = await lib.createFolder(tmp, 'School');
      final nb = await _notebook(lib, school.dir, 'Lecture');
      await engine().run();
      final uploads = drive.uploads;

      final renamed = await lib.rename(nb, 'Algebra');
      var r = await engine().run();
      expect(r.movedNotebooks, 1);
      expect(drive.files.keys, contains('EasyNotes/School/Algebra.enote/content.ezn'));

      await lib.move(renamed, tmp);
      r = await engine().run();
      expect(r.movedNotebooks, 1);
      expect(drive.files.keys, contains('EasyNotes/Algebra.enote/content.ezn'));
      expect(drive.uploads, uploads, reason: 'nothing re-uploaded');

      // Renaming a folder moves its notebooks and trashes the emptied old folder.
      final uni = await lib.createFolder(tmp, 'Uni');
      final inside = await _notebook(lib, uni.dir, 'Physics');
      await engine().run();
      await lib.rename(FolderEntry(uni.dir, itemCount: 1), 'University');
      await engine().run();
      expect(drive.files.keys, contains('EasyNotes/University/Physics.enote/content.ezn'));
      expect(drive.folders, isNot(contains('EasyNotes/Uni')));
      expect(inside.meta.id, isNotEmpty);
    });

    test('deleting a notebook moves its backup to the Drive trash', () async {
      final keep = await _notebook(lib, tmp, 'Keep');
      final gone = await _notebook(lib, tmp, 'Gone');
      await engine().run();
      await lib.delete(gone);
      final r = await engine().run();
      expect(r.removedNotebooks, 1);
      expect(drive.files.keys.where((k) => k.contains('Gone')), isEmpty);
      expect(drive.nodes.values.where((n) => n.name == 'Gone.enote').single.trashed, isTrue, reason: 'recoverable');
      expect(drive.files.keys, contains('EasyNotes/${keep.name}.enote/content.ezn'));
    });

    test('after a reinstall the existing backup is adopted, not duplicated', () async {
      final school = await lib.createFolder(tmp, 'School');
      await _notebook(lib, school.dir, 'A');
      await _notebook(lib, tmp, 'B');
      await engine().run();
      final nodes = drive.nodes.length;
      final uploads = drive.uploads;

      await engine().stateFile.delete(); // local backup state lost
      final r = await engine().run();
      expect(r.uploadedFiles, 0, reason: 'identical files are recognised by their MD5');
      expect(drive.nodes.length, nodes, reason: 'no second root / folder / file');
      expect(drive.uploads, uploads);
      expect(await engine().hasPendingChanges(), isFalse);
    });

    test('a backup deleted in Drive is uploaded again on the next change', () async {
      final a = await _notebook(lib, tmp, 'A', content: 'v1');
      await engine().run();
      final root = drive.nodes.values.firstWhere((n) => n.props['easynotesRoot'] == '1');
      root.trashed = true; // user deleted the EasyNotes folder on drive.google.com
      await _touch(a.documentFile, 'v2');
      await engine().run();
      expect(drive.files['EasyNotes/A.enote/content.ezn'], 'v2');
      expect(drive.files.keys, contains('EasyNotes/A.enote/meta.json'));
    });

    test('going offline mid-run keeps the progress; the next run finishes the job', () async {
      for (final n in ['A', 'B', 'C']) {
        await _notebook(lib, tmp, n);
      }
      drive.offlineAfterCalls = 6;
      await expectLater(engine().run(), throwsA(isA<SocketException>()));
      final partial = drive.uploads;
      expect(partial, greaterThan(0));

      drive.offlineAfterCalls = null;
      await engine().run();
      expect(drive.files.keys.where((k) => k.endsWith('content.ezn')), hasLength(3));
      // Every file exists exactly once, nothing uploaded twice.
      expect(drive.nodes.values.where((n) => !n.folder), hasLength(6));
      expect(drive.uploads, 6);
      expect(await engine().hasPendingChanges(), isFalse);
    });

    test('another account starts its own backup', () async {
      await _notebook(lib, tmp, 'A');
      await engine('ana@example.com').run();
      expect(await engine('ion@example.com').hasPendingChanges(), isTrue);
    });

    test('library notebooks get stable ids (also older ones without)', () async {
      final nb = await _notebook(lib, tmp, 'Old');
      final json = jsonDecode(await nb.metaFile.readAsString()) as Map<String, Object?>;
      expect(json['id'], isA<String>());
      json.remove('id');
      await nb.metaFile.writeAsString(jsonEncode(json));
      final read1 = await lib.readNotebook(nb.dir);
      final read2 = await lib.readNotebook(nb.dir);
      expect(read1.meta.id, hasLength(32));
      expect(read2.meta.id, read1.meta.id, reason: 'assigned once and persisted');
    });
  });

  group('Desktop Google session', () {
    test('session file round-trips and is not stored in plain text', () async {
      final store = FileSessionStore(File('${tmp.path}/session.bin'));
      expect(await store.read(), isNull);
      const secret = '{"refresh":"1//0g-very-secret-token"}';
      await store.write(secret);
      expect(await store.read(), secret);
      final raw = await store.file.readAsBytes();
      if (Platform.isWindows) {
        expect(latin1.decode(raw), isNot(contains('very-secret')), reason: 'DPAPI-encrypted');
        // Tampering is detected instead of yielding garbage.
        raw[raw.length ~/ 2] ^= 0xFF;
        await store.file.writeAsBytes(raw);
        await expectLater(store.read(), throwsStateError);
      }
      await store.delete();
      expect(await store.read(), isNull);
    });

    test('a stored session is restored without signing in again', () async {
      final store = _MemoryStore();
      final auth = DesktopGoogleAuth(clientId: 'id.apps.googleusercontent.com', clientSecret: 's', store: () async => store);
      expect(auth.isConfigured, isTrue);
      expect(await auth.restore(), isNull);
      store.value = jsonEncode({
        'account': FakeAuth.account.toJson(),
        'credentials': {
          'accessToken': {'type': 'Bearer', 'data': 'ya29.x', 'expiry': '2026-01-01T00:00:00.000Z'},
          'refreshToken': '1//refresh',
          'scopes': GoogleAuth.scopes,
        },
      });
      final account = await auth.restore();
      expect(account, FakeAuth.account);
      expect(await auth.client(), isNotNull);
      // A corrupt session is discarded rather than crashing the app.
      store.value = '{broken';
      expect(await DesktopGoogleAuth(clientId: 'id', clientSecret: 's', store: () async => store).restore(), isNull);
      expect(store.value, isNull);
    });

    test('without client ids the desktop flow reports how to set it up', () {
      final auth = DesktopGoogleAuth(clientId: '', clientSecret: '', store: () async => _MemoryStore());
      expect(auth.isConfigured, isFalse);
      expect(auth.setupHint, contains('google_oauth.json'));
    });

    test('auth vs. offline errors are told apart', () {
      expect(GoogleAuth.isAuthError(const AuthRequiredException('x')), isTrue);
      expect(GoogleAuth.isAuthError(const SocketException('x')), isFalse);
      expect(SyncService.isOfflineError(const SocketException('x')), isTrue);
      expect(SyncService.isOfflineError(StateError('x')), isFalse);
    });
  });

  group('SyncService', () {
    late FakeAuth auth;
    late int engines;

    SyncService service({Duration interval = const Duration(minutes: 3)}) => SyncService(
      library: lib,
      auth: auth,
      interval: interval,
      remoteFactory: (_) {
        engines++;
        return drive;
      },
    );

    setUp(() {
      auth = FakeAuth();
      engines = 0;
    });

    test('without OAuth ids the backup is unavailable', () async {
      auth = FakeAuth(configured: false);
      final s = service();
      await s.start();
      expect(s.phase, SyncPhase.unavailable);
      expect(s.message, 'not configured');
      s.dispose();
    });

    test('signed out → sign in → synced', () async {
      await _notebook(lib, tmp, 'A');
      final s = service();
      await s.start();
      expect(s.phase, SyncPhase.signedOut);
      expect(await s.signIn(), isTrue);
      expect(s.account?.email, 'ana@example.com');
      await s.syncNow();
      expect(s.phase, SyncPhase.synced);
      expect(s.lastSynced, isNotNull);
      expect(drive.files.keys, contains('EasyNotes/A.enote/content.ezn'));
      s.dispose();
    });

    test('a stored session is restored silently and backed up at start', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      await _notebook(lib, tmp, 'A');
      final s = service();
      await s.start();
      expect(s.isSignedIn, isTrue);
      await s.syncNow();
      expect(s.phase, SyncPhase.synced);
      s.dispose();
    });

    test('offline → "Offline", then synced once the connection is back', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      final a = await _notebook(lib, tmp, 'A');
      final s = service();
      await s.start();
      await s.syncNow();
      s.markPending();
      expect(s.phase, SyncPhase.pending);

      drive.offlineAfterCalls = drive.calls;
      await _touch(a.documentFile, 'v2');
      await s.syncNow();
      expect(s.phase, SyncPhase.offline);

      drive.offlineAfterCalls = null;
      await s.syncNow();
      expect(s.phase, SyncPhase.synced);
      expect(drive.files['EasyNotes/A.enote/content.ezn'], 'v2');
      s.dispose();
    });

    test('a revoked session signs out instead of retrying forever', () async {
      auth = FakeAuth(stored: FakeAuth.account)..clientError = const AuthRequiredException('revoked');
      final s = service();
      await s.start();
      await s.syncNow();
      expect(s.phase, SyncPhase.signedOut);
      expect(s.isSignedIn, isFalse);
      expect(s.message, contains('Sign in again'));
      s.dispose();
    });

    test('requests during a run are coalesced into one follow-up run', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      await _notebook(lib, tmp, 'A');
      final s = service();
      await s.start(); // starts run 1
      await Future.wait([s.syncNow(), s.syncNow(), s.syncNow()]);
      expect(engines, 2);
      s.dispose();
    });

    test('flush lets open editors save first, then uploads', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      final a = await _notebook(lib, tmp, 'A', content: 'v1');
      final s = service();
      await s.start();
      await s.syncNow();
      final owner = Object();
      s.registerSaver(owner, () => _touch(a.documentFile, 'saved on exit'));
      await s.flush();
      expect(drive.files['EasyNotes/A.enote/content.ezn'], 'saved on exit');
      s.unregisterSaver(owner);
      s.dispose();
    });

    test('the periodic timer pushes changes in the background', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      final a = await _notebook(lib, tmp, 'A', content: 'v1');
      final s = service(interval: const Duration(milliseconds: 100));
      await s.start();
      await s.syncNow();
      await _touch(a.documentFile, 'v2');
      final done = Completer<void>();
      void check() {
        if (drive.files['EasyNotes/A.enote/content.ezn'] == 'v2' && s.phase == SyncPhase.synced && !done.isCompleted) {
          done.complete();
        }
      }

      s.addListener(check);
      await done.future.timeout(const Duration(seconds: 5));
      s.dispose();
    });

    test('signing out stops the backup', () async {
      auth = FakeAuth(stored: FakeAuth.account);
      final s = service();
      await s.start();
      await s.signOut();
      expect(s.phase, SyncPhase.signedOut);
      expect(auth.stored, isNull);
      final before = engines;
      await s.syncNow();
      expect(engines, before);
      s.dispose();
    });
  });
}

class _MemoryStore implements SessionStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;

  @override
  Future<void> delete() async => value = null;
}
