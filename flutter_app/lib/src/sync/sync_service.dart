import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import '../services/library_service.dart';
import 'backup_engine.dart';
import 'drive_remote.dart';
import 'google_auth.dart';

/// What the cloud backup is doing (shown in the status bar and on the account button).
enum SyncPhase {
  /// No OAuth client ids in this build.
  unavailable,
  signedOut,
  signingIn,

  /// Local edits not uploaded yet (the next run picks them up).
  pending,
  syncing,

  /// Everything on Drive matches the library.
  synced,

  /// The last run could not reach Google (it retries on the next tick).
  offline,
  error,
}

/// App-wide Google account + Drive backup.
///
/// Local saves stay instant (the editor autosaves to disk as before); this service
/// pushes the library to Drive in the background:
///
/// * every [interval] (3 min) while signed in,
/// * right after a notebook is closed ([syncNow]),
/// * when the app is hidden or about to exit ([flush], which first lets open editors
///   save), and right after signing in.
///
/// Runs never overlap: a request during a run schedules exactly one more run.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.library,
    required this.auth,
    DriveRemote Function(http.Client client)? remoteFactory,
    this.interval = const Duration(minutes: 3),
  }) : _remoteFactory = remoteFactory ?? GoogleDriveRemote.new;

  final LibraryService library;
  final GoogleAuth auth;
  final Duration interval;
  final DriveRemote Function(http.Client client) _remoteFactory;

  GoogleAccount? _account;
  SyncPhase _phase = SyncPhase.signedOut;
  DateTime? _lastSynced;
  String? _message;
  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;
  final Map<Object, Future<void> Function()> _savers = {};

  GoogleAccount? get account => _account;
  SyncPhase get phase => _phase;
  bool get isSignedIn => _account != null;

  /// When the library last finished uploading.
  DateTime? get lastSynced => _lastSynced;

  /// Detail for errors / offline / setup hints.
  String? get message => _message;

  /// Restores the previous Google session (no UI) and starts the periodic backup.
  Future<void> start() async {
    if (!auth.isConfigured) {
      _set(SyncPhase.unavailable, message: auth.setupHint);
      return;
    }
    GoogleAccount? account;
    try {
      account = await auth.restore();
    } catch (e) {
      debugPrint('Google session restore failed: $e');
    }
    if (_disposed) return;
    _account = account;
    if (account == null) {
      _set(SyncPhase.signedOut);
      return;
    }
    _set(SyncPhase.pending);
    _startTimer();
    unawaited(syncNow());
  }

  /// Interactive sign-in, then an immediate backup. Returns `false` if the user
  /// cancelled; throws on other failures.
  Future<bool> signIn() async {
    if (!auth.isConfigured) {
      _set(SyncPhase.unavailable, message: auth.setupHint);
      throw StateError(auth.setupHint);
    }
    _set(SyncPhase.signingIn);
    try {
      _account = await auth.signIn();
    } on SignInCancelledException {
      _set(SyncPhase.signedOut);
      return false;
    } catch (e) {
      _set(SyncPhase.signedOut, message: '$e');
      rethrow;
    }
    _set(SyncPhase.pending);
    _startTimer();
    unawaited(syncNow());
    return true;
  }

  /// Signs out (the Drive backup itself stays where it is).
  Future<void> signOut() async {
    _timer?.cancel();
    _timer = null;
    await _running;
    _account = null;
    try {
      await auth.signOut();
    } catch (e) {
      debugPrint('Google sign-out failed: $e');
    }
    _set(SyncPhase.signedOut);
  }

  /// Local edits were saved: show "pending" until the next run uploads them.
  void markPending() {
    if (_account != null && _phase == SyncPhase.synced) _set(SyncPhase.pending);
  }

  /// Uploads local changes now (no-op when signed out). Completes when the backup is up
  /// to date or the run failed (see [phase]); never throws.
  Future<void> syncNow() {
    if (_account == null || _disposed) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop();
  }

  /// Lets open editors save, then uploads — used when the app is hidden or exits.
  /// Gives up waiting after [timeout] (the upload continues if the app keeps running).
  Future<void> flush({Duration timeout = const Duration(seconds: 10)}) async {
    for (final save in List.of(_savers.values)) {
      try {
        await save().timeout(timeout);
      } catch (e) {
        debugPrint('Saving before backup failed: $e');
      }
    }
    try {
      await syncNow().timeout(timeout);
    } on TimeoutException {
      debugPrint('Backup still running after $timeout.');
    }
  }

  /// [save] is awaited by [flush] (an open editor's pending autosave).
  void registerSaver(Object owner, Future<void> Function() save) => _savers[owner] = save;
  void unregisterSaver(Object owner) => _savers.remove(owner);

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        await _runOnce();
      } while (_again && _account != null && !_disposed);
    } finally {
      // Cleared synchronously with the last check, so no request can slip in between.
      _running = null;
    }
  }

  Future<void> _runOnce() async {
    final account = _account;
    if (account == null) return;
    try {
      final engine = BackupEngine(library: library, remote: _remoteFactory(await auth.client()), account: account.email);
      if (await engine.hasPendingChanges()) {
        _set(SyncPhase.syncing);
        final report = await engine.run();
        debugPrint('Drive backup: $report');
      }
      _lastSynced = DateTime.now();
      if (_account != null) _set(SyncPhase.synced);
    } catch (e) {
      if (_account == null || _disposed) return;
      if (GoogleAuth.isAuthError(e)) {
        _timer?.cancel();
        _timer = null;
        _account = null;
        try {
          await auth.signOut();
        } catch (_) {}
        _set(SyncPhase.signedOut, message: 'Your Google session expired. Sign in again to keep backing up.');
      } else if (isOfflineError(e)) {
        _set(SyncPhase.offline, message: 'No connection to Google Drive. Retrying automatically.');
      } else {
        debugPrint('Drive backup failed: $e');
        _set(SyncPhase.error, message: describeError(e));
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
  }

  void _set(SyncPhase phase, {String? message}) {
    if (_disposed) return;
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  /// Network-level failures (no route, DNS, TLS, timeouts): "offline", not "broken".
  static bool isOfflineError(Object e) =>
      e is SocketException ||
      e is HandshakeException ||
      e is TimeoutException ||
      e is http.ClientException ||
      e is HttpException ||
      (e is drive.DetailedApiRequestError && (e.status == 503 || e.status == 504));

  static String describeError(Object e) {
    if (e is! drive.DetailedApiRequestError) return '$e';
    if (e.status == 403) return 'Google Drive refused the upload (quota or permissions): ${e.message}';
    return 'Google Drive error ${e.status}: ${e.message}';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
