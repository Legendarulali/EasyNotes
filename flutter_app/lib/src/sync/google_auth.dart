import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'session_store.dart';

/// OAuth client ids, supplied at build time (never committed):
///
/// ```text
/// flutter run --dart-define-from-file=google_oauth.json
/// ```
///
/// See `google_oauth.example.json` and the README for how to create them.
abstract final class GoogleOAuthConfig {
  /// "Desktop app" OAuth client (Windows / Linux loopback sign-in).
  static const String desktopClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');

  /// Secret of the desktop client. Google issues one for installed apps but does not
  /// treat it as confidential; PKCE protects the flow.
  static const String desktopClientSecret = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

  /// iOS / macOS OAuth client (also needs the reversed id as URL scheme in Info.plist).
  static const String appleClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// "Web application" client id, used by Android's Credential Manager.
  static const String serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
}

/// The signed-in Google user.
@immutable
class GoogleAccount {
  const GoogleAccount({required this.email, this.name, this.photoUrl});

  final String email;
  final String? name;
  final String? photoUrl;

  String get displayName => (name?.trim().isNotEmpty ?? false) ? name!.trim() : email;

  String get initials {
    final parts = displayName.split(RegExp(r'[\s@.]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.length == 1 ? parts.first.substring(0, 1) : '${parts[0][0]}${parts[1][0]}').toUpperCase();
  }

  Map<String, Object?> toJson() => {'email': email, 'name': name, 'photo': photoUrl};

  static GoogleAccount? fromJson(Object? j) {
    if (j is! Map || j['email'] is! String) return null;
    return GoogleAccount(email: j['email'] as String, name: j['name'] as String?, photoUrl: j['photo'] as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is GoogleAccount && other.email == email && other.name == name && other.photoUrl == photoUrl;

  @override
  int get hashCode => Object.hash(email, name, photoUrl);
}

/// The user has to sign in (again): signed out elsewhere, access revoked, token expired.
class AuthRequiredException implements Exception {
  const AuthRequiredException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The user closed the sign-in prompt.
class SignInCancelledException implements Exception {
  const SignInCancelledException();

  @override
  String toString() => 'Sign-in was cancelled.';
}

/// Google sign-in with access to the app's own files on Drive (`drive.file` scope:
/// EasyNotes can only see the files it created, nothing else in the user's Drive).
abstract class GoogleAuth {
  static const List<String> scopes = [drive.DriveApi.driveFileScope];

  /// `google_sign_in` on Android / iOS / macOS; a browser + loopback flow on Windows and
  /// Linux, which `google_sign_in` does not support.
  factory GoogleAuth.forPlatform() =>
      Platform.isWindows || Platform.isLinux ? DesktopGoogleAuth() : MobileGoogleAuth();

  /// Whether OAuth client ids were compiled in for this platform.
  bool get isConfigured;

  /// Developer-facing explanation shown when [isConfigured] is false.
  String get setupHint;

  /// Restores the previous session without any UI (`null` = not signed in).
  Future<GoogleAccount?> restore();

  /// Interactive sign-in. Throws [SignInCancelledException] if the user backs out.
  Future<GoogleAccount> signIn();

  Future<void> signOut();

  /// HTTP client authorised for [scopes]; tokens are refreshed automatically.
  Future<http.Client> client();

  /// Errors that mean "sign in again" rather than "try again later".
  static bool isAuthError(Object e) {
    if (e is AuthRequiredException || e is gauth.AccessDeniedException) return true;
    if (e is! gauth.ServerRequestFailedException) return false;
    // Token refresh rejected: the grant was revoked or the refresh token expired.
    final content = e.responseContent;
    return e.message.contains('invalid_grant') || (content is Map && content['error'] == 'invalid_grant');
  }
}

// ---------------------------------------------------------------------------- desktop

/// Windows / Linux: OAuth 2.0 for installed apps. The system browser opens Google's
/// consent page and redirects to a one-shot HTTP server on `localhost` (random port,
/// `state` check, PKCE S256). The refresh token is kept by a [SessionStore]
/// ([FileSessionStore]: DPAPI-encrypted on Windows, owner-only file on Linux) and
/// access tokens are refreshed automatically.
class DesktopGoogleAuth implements GoogleAuth {
  DesktopGoogleAuth({
    String clientId = GoogleOAuthConfig.desktopClientId,
    String clientSecret = GoogleOAuthConfig.desktopClientSecret,
    Future<SessionStore> Function()? store,
  }) : _clientId = gauth.ClientId(clientId, clientSecret.isEmpty ? null : clientSecret),
       _openStore = store ?? FileSessionStore.standard;

  static const Duration _consentTimeout = Duration(minutes: 5);

  final gauth.ClientId _clientId;
  final Future<SessionStore> Function() _openStore;
  Future<SessionStore>? _store;
  Future<SessionStore> get _storage => _store ??= _openStore();
  final http.Client _base = http.Client();
  gauth.AutoRefreshingAuthClient? _client;
  StreamSubscription<gauth.AccessCredentials>? _updates;
  GoogleAccount? _account;

  @override
  bool get isConfigured => _clientId.identifier.isNotEmpty && (_clientId.secret?.isNotEmpty ?? false);

  @override
  String get setupHint =>
      'Google sign-in is not set up in this build. Create a "Desktop app" OAuth client '
      'in Google Cloud (Drive API enabled) and run with '
      '--dart-define-from-file=google_oauth.json (see the README).';

  @override
  Future<GoogleAccount?> restore() async {
    final String? raw;
    try {
      raw = await (await _storage).read();
    } catch (e) {
      debugPrint('Google session could not be read: $e');
      return null;
    }
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final account = GoogleAccount.fromJson(json['account']);
      final creds = gauth.AccessCredentials.fromJson(json['credentials'] as Map<String, dynamic>);
      if (account == null || creds.refreshToken == null) return null;
      _account = account;
      _attach(creds);
      return account;
    } catch (e) {
      debugPrint('Stored Google session is unreadable, signing out: $e');
      await (await _storage).delete();
      return null;
    }
  }

  @override
  Future<GoogleAccount> signIn() async {
    if (!isConfigured) throw StateError(setupHint);
    final gauth.AccessCredentials creds;
    try {
      creds = await gauth
          .obtainAccessCredentialsViaUserConsent(
            _clientId,
            GoogleAuth.scopes,
            _base,
            _openBrowser,
            customPostAuthPage: _donePage,
          )
          .timeout(_consentTimeout);
    } on TimeoutException {
      throw const SignInCancelledException();
    } on gauth.UserConsentException {
      throw const SignInCancelledException();
    }
    if (creds.refreshToken == null) {
      throw StateError('Google did not grant offline access; please try signing in again.');
    }
    _attach(creds);
    final about = await drive.DriveApi(_client!).about.get($fields: 'user(displayName,emailAddress,photoLink)');
    final user = about.user;
    _account = GoogleAccount(
      email: user?.emailAddress ?? 'Google account',
      name: user?.displayName,
      photoUrl: user?.photoLink,
    );
    await _persist(creds);
    return _account!;
  }

  @override
  Future<void> signOut() async {
    final refresh = _client?.credentials.refreshToken;
    await _updates?.cancel();
    _updates = null;
    _client?.close();
    _client = null;
    _account = null;
    await (await _storage).delete();
    if (refresh != null) {
      // Revoke the grant too, best effort (the local session is gone either way).
      try {
        await _base
            .post(Uri.parse('https://oauth2.googleapis.com/revoke'), body: {'token': refresh})
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  @override
  Future<http.Client> client() async {
    final c = _client;
    if (c == null) throw const AuthRequiredException('Not signed in to Google.');
    return c;
  }

  void _attach(gauth.AccessCredentials creds) {
    _updates?.cancel();
    _client?.close();
    final client = gauth.autoRefreshingClient(_clientId, creds, _base);
    _client = client;
    _updates = client.credentialUpdates.listen(_persist);
  }

  Future<void> _persist(gauth.AccessCredentials creds) async {
    final account = _account;
    if (account == null) return;
    try {
      await (await _storage).write(jsonEncode({'account': account.toJson(), 'credentials': creds.toJson()}));
    } catch (e) {
      debugPrint('Google session could not be stored: $e');
    }
  }

  static void _openBrowser(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).then((ok) {
      if (!ok) debugPrint('Could not open the browser for Google sign-in: $url');
    });
  }

  static const String _donePage = '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>EasyNotes</title></head>
<body style="background:#1E1E1E;color:#eee;font-family:sans-serif;text-align:center;padding-top:15vh">
<h2>You're signed in to EasyNotes</h2><p>You can close this tab and return to the app.</p>
</body></html>''';
}

// ---------------------------------------------------------------------------- mobile

/// Android / iOS / macOS via `google_sign_in`: the platform keeps the session (silent
/// restore with `attemptLightweightAuthentication`) and mints fresh access tokens.
class MobileGoogleAuth implements GoogleAuth {
  MobileGoogleAuth({
    this._appleClientId = GoogleOAuthConfig.appleClientId,
    this._serverClientId = GoogleOAuthConfig.serverClientId,
  });

  /// Access tokens live one hour; refresh a little earlier.
  static const Duration _tokenLifetime = Duration(minutes: 45);

  final String _appleClientId;
  final String _serverClientId;
  final GoogleSignIn _signIn = GoogleSignIn.instance;
  Future<void>? _initialized;
  GoogleSignInAccount? _user;
  String? _token;
  DateTime _tokenTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isApple => Platform.isIOS || Platform.isMacOS;

  @override
  bool get isConfigured => _isApple ? _appleClientId.isNotEmpty : _serverClientId.isNotEmpty;

  @override
  String get setupHint => _isApple
      ? 'Google sign-in is not set up in this build: pass GOOGLE_IOS_CLIENT_ID and add the '
            'reversed client id as a URL scheme in Info.plist (see the README).'
      : 'Google sign-in is not set up in this build: register the app (package name + SHA-1) '
            'in Google Cloud and pass the web client id as GOOGLE_SERVER_CLIENT_ID (see the README).';

  Future<void> _init() => _initialized ??= _signIn.initialize(
    clientId: _isApple && _appleClientId.isNotEmpty ? _appleClientId : null,
    serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
  );

  GoogleAccount _accountOf(GoogleSignInAccount u) =>
      GoogleAccount(email: u.email, name: u.displayName, photoUrl: u.photoUrl);

  @override
  Future<GoogleAccount?> restore() async {
    if (!isConfigured) return null;
    await _init();
    final user = await (_signIn.attemptLightweightAuthentication() ?? Future<GoogleSignInAccount?>.value());
    _user = user;
    return user == null ? null : _accountOf(user);
  }

  @override
  Future<GoogleAccount> signIn() async {
    if (!isConfigured) throw StateError(setupHint);
    await _init();
    try {
      final user = await _signIn.authenticate(scopeHint: GoogleAuth.scopes);
      final authz = await user.authorizationClient.authorizeScopes(GoogleAuth.scopes);
      _user = user;
      _token = authz.accessToken;
      _tokenTime = DateTime.now();
      return _accountOf(user);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled || e.code == GoogleSignInExceptionCode.interrupted) {
        throw const SignInCancelledException();
      }
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    await _init();
    _user = null;
    _token = null;
    await _signIn.signOut();
  }

  @override
  Future<http.Client> client() async {
    if (_user == null) throw const AuthRequiredException('Not signed in to Google.');
    return _BearerClient(_accessToken, _rejected);
  }

  Future<String> _accessToken() async {
    final cached = _token;
    if (cached != null && DateTime.now().difference(_tokenTime) < _tokenLifetime) return cached;
    final user = _user;
    if (user == null) throw const AuthRequiredException('Not signed in to Google.');
    final authz = await user.authorizationClient.authorizationForScopes(GoogleAuth.scopes);
    if (authz == null) throw const AuthRequiredException('Google needs you to allow Drive access again.');
    _token = authz.accessToken;
    _tokenTime = DateTime.now();
    return authz.accessToken;
  }

  /// A 401 means the cached token is stale: drop it so the next request gets a new one.
  void _rejected(String token) {
    if (_token == token) _token = null;
    _user?.authorizationClient.clearAuthorizationToken(accessToken: token).catchError((Object _) {});
  }
}

/// Adds `Authorization: Bearer …` to every request.
class _BearerClient extends http.BaseClient {
  _BearerClient(this._token, this._onRejected);

  final Future<String> Function() _token;
  final void Function(String token) _onRejected;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await _token();
    request.headers['Authorization'] = 'Bearer $token';
    final response = await _inner.send(request);
    if (response.statusCode == 401) _onRejected(token);
    return response;
  }

  @override
  void close() => _inner.close();
}
