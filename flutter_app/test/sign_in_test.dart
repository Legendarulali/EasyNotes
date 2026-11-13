import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/session_store.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_app/widgets/sync_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---------------------------------------------------------------------------- desktop harness

/// Stands in for the system browser: records the consent URLs instead of opening them.
class _Browser {
  final _opened = <Uri>[];
  Completer<void> _signal = Completer<void>();
  bool canOpen = true;

  Future<bool> open(Uri url) async {
    _opened.add(url);
    if (!_signal.isCompleted) _signal.complete();
    return canOpen;
  }

  /// The [index]-th consent page opened (waits for it).
  Future<Uri> consentUrl([int index = 0]) async {
    while (_opened.length <= index) {
      _signal = Completer<void>();
      await _signal.future;
    }
    return _opened[index];
  }
}

/// Google's side of the code exchange and the profile request.
class _Google {
  final tokenRequests = <Map<String, String>>[];
  Object? tokenError;

  late final http.Client client = MockClient((request) async {
    if (request.url.host == 'oauth2.googleapis.com' && request.url.path == '/token') {
      tokenRequests.add(request.bodyFields);
      final error = tokenError;
      if (error != null) throw error;
      return _json({
        'access_token': 'ya29.access',
        'expires_in': 3599,
        'refresh_token': '1//refresh',
        'scope': GoogleAuth.scopes.join(' '),
        'token_type': 'Bearer',
      });
    }
    if (request.url.path == '/drive/v3/about') {
      return _json({
        'user': {'displayName': 'Ana Pop', 'emailAddress': 'ana@example.com'},
      });
    }
    return http.Response('unexpected ${request.url}', 404);
  });

  static http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
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

/// Plays the browser following Google's redirect. Raw socket on purpose: flutter_test
/// stubs out `HttpClient` once the widget binding is up.
Future<({int status, String body})> _visit(Uri redirect, Map<String, String> query, {String path = '/'}) async {
  final socket = await Socket.connect(redirect.host, redirect.port);
  final target = Uri(path: path, queryParameters: query.isEmpty ? null : query);
  socket.write('GET $target HTTP/1.1\r\nHost: ${redirect.authority}\r\nConnection: close\r\n\r\n');
  await socket.flush();
  final raw = await utf8.decodeStream(socket);
  socket.destroy();
  return (status: int.parse(raw.split(' ')[1]), body: raw.substring(raw.indexOf('\r\n\r\n') + 4));
}

Uri _redirectOf(Uri consentUrl) => Uri.parse(consentUrl.queryParameters['redirect_uri']!);

Future<bool> _isListening(Uri redirect) async {
  try {
    (await Socket.connect(redirect.host, redirect.port, timeout: const Duration(milliseconds: 500))).destroy();
    return true;
  } on SocketException {
    return false;
  }
}

// ---------------------------------------------------------------------------- service harness

/// Sign-in that waits until the test resolves it, like a browser tab left open.
class _PendingAuth implements GoogleAuth {
  Completer<GoogleAccount>? pending;
  int signIns = 0;

  @override
  bool get isConfigured => true;

  @override
  String get setupHint => 'not configured';

  @override
  Future<GoogleAccount?> restore() async => null;

  @override
  Future<GoogleAccount> signIn() {
    signIns++;
    return (pending = Completer<GoogleAccount>()).future;
  }

  @override
  void cancelSignIn() {
    final p = pending;
    if (p != null && !p.isCompleted) p.completeError(const SignInCancelledException());
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<http.Client> client() async => throw const AuthRequiredException('not signed in');

  void fail(Object error) => pending!.completeError(error);
}

void main() {
  group('Desktop loopback sign-in', () {
    late _Browser browser;
    late _Google google;
    late _MemoryStore store;

    DesktopGoogleAuth auth({Duration timeout = DesktopGoogleAuth.defaultConsentTimeout}) => DesktopGoogleAuth(
      clientId: 'id.apps.googleusercontent.com',
      clientSecret: 'secret',
      store: () async => store,
      httpClient: google.client,
      openBrowser: browser.open,
      consentTimeout: timeout,
    );

    setUp(() {
      browser = _Browser();
      google = _Google();
      store = _MemoryStore();
    });

    test('keeps the 5-minute window for passwords and two-step verification', () {
      expect(DesktopGoogleAuth.defaultConsentTimeout, const Duration(minutes: 5));
    });

    test('consent → redirect with a code → signed in; PKCE and state are checked', () async {
      final signIn = auth().signIn();
      final consent = await browser.consentUrl();
      final q = consent.queryParameters;
      expect(consent.host, 'accounts.google.com');
      expect(q['scope'], GoogleAuth.scopes.join(' '));
      expect(q['code_challenge_method'], 'S256');
      expect(q['access_type'], 'offline');
      final redirect = _redirectOf(consent);
      expect(redirect.host, '127.0.0.1');

      // Not the redirect: the favicon, and a forged/stale callback with the wrong state.
      expect((await _visit(redirect, {}, path: '/favicon.ico')).status, 404);
      expect((await _visit(redirect, {'state': 'forged', 'code': 'evil'})).status, 404);
      expect(google.tokenRequests, isEmpty);

      final page = await _visit(redirect, {'state': q['state']!, 'code': 'auth-code'});
      expect(page.status, 200);
      expect(page.body, contains('signed in'));
      final account = await signIn;
      expect(account.email, 'ana@example.com');
      expect(account.name, 'Ana Pop');

      final exchange = google.tokenRequests.single;
      expect(exchange['code'], 'auth-code');
      expect(exchange['redirect_uri'], redirect.toString());
      final challenge = base64UrlEncode(sha256.convert(ascii.encode(exchange['code_verifier']!)).bytes).replaceAll('=', '');
      expect(challenge, q['code_challenge']);
      expect(store.value, contains('1//refresh'), reason: 'session persisted for the next launch');
      expect(await _isListening(redirect), isFalse, reason: 'loopback server closed');
    });

    // Each test attaches its expectation as soon as the attempt starts: a failure that
    // lands while the test still awaits the fake browser must not count as uncaught.

    test('"Cancel" on Google\'s page (?error=access_denied) ends the sign-in at once', () async {
      final watch = Stopwatch()..start();
      final cancelled = expectLater(auth().signIn(), throwsA(isA<SignInCancelledException>()));
      final consent = await browser.consentUrl();
      final redirect = _redirectOf(consent);
      final page = await _visit(redirect, {'state': consent.queryParameters['state']!, 'error': 'access_denied'});
      expect(page.status, 200);
      expect(page.body, contains('Sign-in cancelled'));
      await cancelled;
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)), reason: 'no waiting for the 5-minute timeout');
      expect(await _isListening(redirect), isFalse);
      expect(google.tokenRequests, isEmpty);
      expect(store.value, isNull);
    });

    test('any other OAuth error fails with Google\'s reason', () async {
      final failed = expectLater(
        auth().signIn(),
        throwsA(isA<SignInFailedException>().having((e) => e.message, 'message', contains('invalid_scope'))),
      );
      final consent = await browser.consentUrl();
      final page = await _visit(_redirectOf(consent), {
        'state': consent.queryParameters['state']!,
        'error': 'invalid_scope',
        'error_description': 'Some requested scopes are invalid.',
      });
      expect(page.body, contains('Some requested scopes are invalid.'));
      await failed;
    });

    test('an error redirect without state still ends the wait', () async {
      final cancelled = expectLater(auth().signIn(), throwsA(isA<SignInCancelledException>()));
      final redirect = _redirectOf(await browser.consentUrl());
      await _visit(redirect, {'error': 'access_denied'});
      await cancelled;
      expect(await _isListening(redirect), isFalse);
    });

    test('browser tab closed: the wait times out and the loopback server is closed', () async {
      final timedOut = expectLater(
        auth(timeout: const Duration(milliseconds: 300)).signIn(),
        throwsA(isA<SignInFailedException>()),
      );
      final redirect = _redirectOf(await browser.consentUrl());
      await timedOut;
      expect(await _isListening(redirect), isFalse);
    });

    test('cancelSignIn abandons the wait immediately', () async {
      final a = auth();
      final cancelled = expectLater(a.signIn(), throwsA(isA<SignInCancelledException>()));
      final redirect = _redirectOf(await browser.consentUrl());
      expect(await _isListening(redirect), isTrue);
      a.cancelSignIn();
      await cancelled;
      expect(await _isListening(redirect), isFalse);
      a.cancelSignIn(); // nothing in progress: no-op
    });

    test('a new attempt supersedes one still waiting', () async {
      final a = auth();
      final first = expectLater(a.signIn(), throwsA(isA<SignInCancelledException>()));
      final firstRedirect = _redirectOf(await browser.consentUrl());
      final second = a.signIn();
      await first;
      expect(await _isListening(firstRedirect), isFalse);
      // The new attempt is unaffected and still answers its own redirect.
      final consent = await browser.consentUrl(1);
      await _visit(_redirectOf(consent), {'state': consent.queryParameters['state']!, 'code': 'auth-code'});
      expect((await second).email, 'ana@example.com');
    });

    test('a browser that cannot be opened fails right away', () async {
      browser.canOpen = false;
      final failed = expectLater(auth().signIn(), throwsA(isA<SignInFailedException>()));
      final redirect = _redirectOf(await browser.consentUrl());
      await failed;
      expect(await _isListening(redirect), isFalse);
    });

    test('no network during the code exchange fails instead of hanging', () async {
      google.tokenError = const SocketException('Network is unreachable');
      final error = auth().signIn().then<Object?>((_) => null, onError: (Object e) => e);
      final consent = await browser.consentUrl();
      final page = await _visit(_redirectOf(consent), {'state': consent.queryParameters['state']!, 'code': 'c'});
      expect(page.body, contains('did not complete'));
      final e = await error;
      expect(e, isA<SocketException>());
      expect(GoogleAuth.describeError(e!), contains('could not reach Google'));
      expect(store.value, isNull);
    });
  });

  group('SyncService sign-in state', () {
    late Directory tmp;
    late _PendingAuth auth;
    late SyncService sync;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('easynotes_signin');
      auth = _PendingAuth();
      sync = SyncService(library: LibraryService(tmp), auth: auth);
      await sync.start();
    });

    tearDown(() async {
      sync.dispose();
      await tmp.delete(recursive: true);
    });

    test('cancelled → signed out again, without an error', () async {
      final result = sync.signIn();
      expect(sync.phase, SyncPhase.signingIn);
      auth.fail(const SignInCancelledException());
      expect(await result, isFalse);
      expect(sync.phase, SyncPhase.signedOut);
      expect(sync.message, isNull);
      expect(sync.isSignedIn, isFalse);
    });

    test('failed → signed out with the reason; the error reaches the caller', () async {
      final result = sync.signIn();
      auth.fail(const SignInFailedException('Google reported "server_error".'));
      await expectLater(result, throwsA(isA<SignInFailedException>()));
      expect(sync.phase, SyncPhase.signedOut);
      expect(sync.message, 'Google sign-in failed: Google reported "server_error".');
    });

    test('unexpected errors reset the state too', () async {
      final result = sync.signIn();
      auth.fail(const SocketException('offline'));
      await expectLater(result, throwsA(isA<SocketException>()));
      expect(sync.phase, SyncPhase.signedOut);
      expect(sync.message, contains('could not reach Google'));
    });

    test('cancelSignIn ends a stuck attempt immediately', () async {
      final result = sync.signIn();
      sync.cancelSignIn();
      expect(await result, isFalse);
      expect(sync.phase, SyncPhase.signedOut);
    });

    test('a second click while waiting joins the same attempt', () async {
      final first = sync.signIn();
      final second = sync.signIn();
      expect(auth.signIns, 1);
      sync.cancelSignIn();
      expect(await first, isFalse);
      expect(await second, isFalse);
      // …and a fresh attempt is possible afterwards.
      final third = sync.signIn();
      expect(auth.signIns, 2);
      sync.cancelSignIn();
      expect(await third, isFalse);
    });
  });

  group('Sign-in button', () {
    late Directory tmp;
    late _PendingAuth auth;
    late SyncService sync;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('easynotes_signin_ui');
      auth = _PendingAuth();
      sync = SyncService(library: LibraryService(tmp), auth: auth);
    });

    tearDown(() {
      sync.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<void> pumpButton(WidgetTester tester, {bool compact = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(appBar: AppBar(actions: [AccountButton(sync: sync, compact: compact)])),
        ),
      );
      await tester.runAsync(sync.start);
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750)); // SnackBar entrance
    }

    testWidgets('failed sign-in: the spinner gives way to the button, with a SnackBar', (tester) async {
      await pumpButton(tester);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Cancel sign-in'), findsOneWidget);

      auth.fail(const SignInFailedException('Google reported "access_blocked".'));
      await settle(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Google sign-in failed: Google reported "access_blocked".'), findsOneWidget);
    });

    testWidgets('OAuth access_denied: back to "Sign in with Google" right away', (tester) async {
      await pumpButton(tester);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      auth.fail(const SignInCancelledException());
      await settle(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    });

    testWidgets('"Cancel sign-in" ends an attempt whose browser tab was closed', (tester) async {
      await pumpButton(tester);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      await tester.tap(find.text('Cancel sign-in'));
      await settle(tester);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
      expect(sync.phase, SyncPhase.signedOut);
    });

    testWidgets('compact layout: the spinner itself is the cancel button', (tester) async {
      await pumpButton(tester, compact: true);
      await tester.tap(find.byTooltip('Sign in with Google'));
      await tester.pump();
      final spinner = find.byKey(const ValueKey('cancel-sign-in'));
      expect(find.descendant(of: spinner, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      await tester.tap(spinner);
      await settle(tester);
      expect(find.byTooltip('Sign in with Google'), findsOneWidget);
      expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    });
  });
}
