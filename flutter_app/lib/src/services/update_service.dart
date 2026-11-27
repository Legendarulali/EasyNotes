import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';
import 'library_service.dart';

/// A newer EasyNotes release on GitHub.
@immutable
class AvailableUpdate {
  const AvailableUpdate({required this.version, required this.tag, required this.url});

  /// `1.0.2` (from the tag `v1.0.2`).
  final String version;
  final String tag;

  /// The release page (notes and downloads).
  final Uri url;

  Map<String, Object?> toJson() => {'tag': tag, 'url': url.toString()};
}

/// Looks for a newer release of the app on GitHub, without blocking anything:
///
/// * at most once every [interval] (24 h); the last answer is remembered in the library
///   settings, so a newer version found earlier is still announced on the next starts;
/// * offline or any failure: silently nothing (tried again on the next start);
/// * the request carries no personal data, just a generic client name.
///
/// [available] is set when the latest release is newer than [currentVersion] and the user
/// has not dismissed that version.
class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.library,
    this._client,
    this.currentVersion = appVersion,
    this.interval = const Duration(hours: 24),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LibraryService library;
  final String currentVersion;
  final Duration interval;
  final http.Client? _client;
  final DateTime Function() _clock;

  static final Uri latestReleaseApi = Uri.parse('https://api.github.com/repos/Legendarulali/EasyNotes/releases/latest');
  static final Uri releasesPage = Uri.parse('https://github.com/Legendarulali/EasyNotes/releases/latest');

  /// Settings key of the remembered check (`{checkedAt, tag, url, dismissed}`).
  static const String settingsKey = 'updateCheck';

  AvailableUpdate? _available;
  bool _disposed = false;

  AvailableUpdate? get available => _available;

  /// Announces a newer version found earlier, then asks GitHub if the last check is
  /// older than [interval]. Never throws.
  Future<void> check() async {
    try {
      final saved = await _saved();
      _announce(_parseSaved(saved), dismissed: saved['dismissed']);
      final checkedAt = DateTime.tryParse('${saved['checkedAt']}');
      final now = _clock();
      if (checkedAt != null && !checkedAt.isAfter(now) && now.difference(checkedAt) < interval) return;

      final (:reached, :latest) = await _fetchLatest();
      if (!reached) return;
      await library.updateSettings({
        settingsKey: {...saved, 'checkedAt': now.toUtc().toIso8601String(), 'tag': latest?.tag, 'url': latest?.url.toString()},
      });
      _announce(latest, dismissed: saved['dismissed']);
    } catch (e) {
      debugPrint('Update check failed: $e');
    }
  }

  /// Hides the banner for this version (a later one is announced again).
  Future<void> dismiss() async {
    final update = _available;
    if (update == null) return;
    _available = null;
    if (!_disposed) notifyListeners();
    try {
      final saved = await _saved();
      await library.updateSettings({
        settingsKey: {...saved, 'dismissed': update.tag},
      });
    } catch (e) {
      debugPrint('Could not remember the dismissed update: $e');
    }
  }

  // ------------------------------------------------------------------ internals

  /// The latest release (`null` if there is none, or it cannot be read). [reached] is
  /// `false` when GitHub could not be reached at all: then nothing is remembered.
  Future<({bool reached, AvailableUpdate? latest})> _fetchLatest() async {
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(
            latestReleaseApi,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'EasyNotes-update-check',
            },
          )
          .timeout(const Duration(seconds: 10));
      // 404: no release published yet; 403 / 429: rate limited. Either way, ask again
      // tomorrow rather than on every start.
      if (response.statusCode != 200) return (reached: true, latest: null);
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, Object?>) return (reached: true, latest: null);
      final tag = json['tag_name'];
      final url = Uri.tryParse('${json['html_url']}');
      if (tag is! String || json['draft'] == true || json['prerelease'] == true) return (reached: true, latest: null);
      return (reached: true, latest: releaseFor(tag, url: url != null && url.isScheme('https') ? url : releasesPage));
    } on FormatException {
      return (reached: true, latest: null);
    } catch (e) {
      debugPrint('Update check: GitHub not reachable ($e)');
      return (reached: false, latest: null);
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<Map<String, Object?>> _saved() async {
    final raw = (await library.readSettings())[settingsKey];
    return raw is Map<String, Object?> ? Map.of(raw) : <String, Object?>{};
  }

  static AvailableUpdate? _parseSaved(Map<String, Object?> saved) {
    final tag = saved['tag'];
    if (tag is! String) return null;
    final url = Uri.tryParse('${saved['url']}');
    return releaseFor(tag, url: url != null && url.isScheme('https') ? url : releasesPage);
  }

  void _announce(AvailableUpdate? latest, {Object? dismissed}) {
    final show = latest != null && latest.tag != dismissed && compareVersions(latest.version, currentVersion) > 0;
    final next = show ? latest : null;
    if (next?.tag == _available?.tag) return;
    _available = next;
    if (!_disposed) notifyListeners();
  }

  /// The release with git tag [tag] (`v1.2.3` or `1.2.3`), `null` if the tag is not a
  /// version number.
  static AvailableUpdate? releaseFor(String tag, {required Uri url}) {
    final version = tag.trim().replaceFirst(RegExp('^[vV]'), '');
    if (!RegExp(r'^\d+(\.\d+)*').hasMatch(version)) return null;
    return AvailableUpdate(version: version, tag: tag, url: url);
  }

  /// Compares dotted version numbers (`1.0.10` > `1.0.9`; missing parts count as 0;
  /// anything after the numbers, such as `-beta` or `+2`, is ignored).
  static int compareVersions(String a, String b) {
    List<int> parts(String v) =>
        (RegExp(r'^\d+(\.\d+)*').firstMatch(v.trim())?.group(0) ?? '0')
            .split('.')
            .map((p) => int.tryParse(p) ?? 0)
            .toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
