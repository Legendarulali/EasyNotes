import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/src/app_version.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/services/update_service.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_app/widgets/home_banners.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'backup_sync_test.dart' show FakeAuth, FakeDrive;

/// GitHub's answer for a latest release tagged [tag].
http.Response _release(String tag) => http.Response(
  jsonEncode({
    'tag_name': tag,
    'html_url': 'https://github.com/Legendarulali/EasyNotes/releases/tag/$tag',
    'draft': false,
    'prerelease': false,
  }),
  200,
);

void main() {
  late Directory tmp;
  late LibraryService lib;
  late List<http.Request> requests;
  late http.Response Function() answer;
  late DateTime now;

  UpdateService service({String current = '1.0.1'}) => UpdateService(
    library: lib,
    client: MockClient((request) async {
      requests.add(request);
      return answer();
    }),
    currentVersion: current,
    clock: () => now,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easynotes_updates');
    lib = LibraryService(tmp);
    requests = [];
    answer = () => _release('v1.0.2');
    now = DateTime.utc(2026, 11, 27, 9);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('the app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([\d.]+)\+(\d+)', multiLine: true).firstMatch(pubspec)!;
    expect(version.group(1), appVersion);
    expect(version.group(1), '1.0.1');
    expect(version.group(2), '2');
  });

  test('versions compare numerically', () {
    expect(UpdateService.compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0', '1.0.0'), 0);
    expect(UpdateService.compareVersions('1.0.1+2', '1.0.1'), 0);
    expect(UpdateService.compareVersions('2.0.0-beta', '1.9.9'), greaterThan(0));
    expect(UpdateService.compareVersions('0.9', '1.0.1'), lessThan(0));
    expect(UpdateService.releaseFor('v1.2.3', url: UpdateService.releasesPage)?.version, '1.2.3');
    expect(UpdateService.releaseFor('nightly', url: UpdateService.releasesPage), isNull);
  });

  test('a newer release is announced; the request carries no personal data', () async {
    final s = service();
    await s.check();
    expect(s.available?.version, '1.0.2');
    expect(s.available?.url.toString(), 'https://github.com/Legendarulali/EasyNotes/releases/tag/v1.0.2');
    final r = requests.single;
    expect(r.url, UpdateService.latestReleaseApi);
    expect(r.method, 'GET');
    expect(r.headers['User-Agent'], 'EasyNotes-update-check');
    expect(r.body, isEmpty);
    expect(r.url.query, isEmpty);
  });

  test('the same or an older release is not announced', () async {
    answer = () => _release('v1.0.1');
    final s = service();
    await s.check();
    expect(s.available, isNull);
    answer = () => _release('v0.9.0');
    now = now.add(const Duration(days: 2));
    await s.check();
    expect(s.available, isNull);
  });

  test('GitHub is asked at most once a day; what it said is remembered meanwhile', () async {
    await service().check();
    expect(requests, hasLength(1));

    now = now.add(const Duration(hours: 23));
    final later = service();
    await later.check();
    expect(requests, hasLength(1), reason: 'throttled');
    expect(later.available?.version, '1.0.2', reason: 'still announced from the saved answer');

    now = now.add(const Duration(hours: 2));
    answer = () => _release('v1.1.0');
    final nextDay = service();
    await nextDay.check();
    expect(requests, hasLength(2));
    expect(nextDay.available?.version, '1.1.0');
  });

  test('offline: silently nothing, and GitHub is asked again on the next start', () async {
    answer = () => throw const SocketException('Network is unreachable');
    final s = service();
    await s.check();
    expect(s.available, isNull);
    expect((await lib.readSettings())[UpdateService.settingsKey], isNull, reason: 'nothing remembered');

    answer = () => _release('v1.0.2');
    final online = service();
    await online.check();
    expect(online.available?.version, '1.0.2');
    expect(requests, hasLength(2));
  });

  test('no release yet (404) or a broken answer: nothing announced, asked again tomorrow', () async {
    answer = () => http.Response('{"message":"Not Found"}', 404);
    final s = service();
    await s.check();
    expect(s.available, isNull);
    answer = () => http.Response('<html>', 200);
    await service().check();
    expect(requests, hasLength(1), reason: 'the 404 counted as a check');
    now = now.add(const Duration(days: 1, minutes: 1));
    await service().check();
    expect(requests, hasLength(2));
  });

  test('dismissing hides that version for good; a newer one shows again', () async {
    final s = service();
    await s.check();
    await s.dismiss();
    expect(s.available, isNull);
    final restarted = service();
    await restarted.check();
    expect(restarted.available, isNull);

    now = now.add(const Duration(days: 2));
    answer = () => _release('v1.0.3');
    await restarted.check();
    expect(restarted.available?.version, '1.0.3');
  });

  group('Update banner', () {
    late SyncService sync;

    setUp(() {
      sync = SyncService(library: lib, auth: FakeAuth(stored: FakeAuth.account), remoteFactory: (_) => FakeDrive());
    });
    tearDown(() => sync.dispose());

    Future<UpdateService> available(WidgetTester tester) async {
      final s = service();
      await tester.runAsync(s.check);
      return s;
    }

    Widget host(UpdateService updates, {required bool windows}) => MaterialApp(
      home: Scaffold(
        body: UpdateBanner(updates: updates, sync: sync, libraryPath: r'C:\Users\Ana\Documents\EasyNotes', windows: windows),
      ),
    );

    testWidgets('Windows: warns to back up before replacing the app folder, with Sync now', (tester) async {
      final updates = await available(tester);
      await tester.runAsync(sync.start);
      // Let the start-up run (an empty library: nothing to restore) finish first.
      await tester.runAsync(sync.syncNow);
      await tester.pumpWidget(host(updates, windows: true));
      expect(find.text('EasyNotes 1.0.2 is available'), findsOneWidget);
      expect(find.textContaining('replace the EasyNotes app folder'), findsOneWidget);
      expect(find.textContaining(r'C:\Users\Ana\Documents\EasyNotes'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('View release'), findsOneWidget);

      // Tapped outside the fake clock: the dismissal is saved in the settings file.
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Dismiss'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('update-banner')), findsNothing);
      expect((await tester.runAsync(lib.readSettings))?[UpdateService.settingsKey], containsPair('dismissed', 'v1.0.2'));
      updates.dispose();
    });

    testWidgets('signed out on Windows: the warning asks to sign in, no Sync now', (tester) async {
      final updates = await available(tester);
      await tester.pumpWidget(host(updates, windows: true));
      expect(find.textContaining('sign in with Google'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
      updates.dispose();
    });

    testWidgets('other platforms: just the notice', (tester) async {
      final updates = await available(tester);
      await tester.runAsync(sync.start);
      // Let the start-up run (an empty library: nothing to restore) finish first.
      await tester.runAsync(sync.syncNow);
      await tester.pumpWidget(host(updates, windows: false));
      expect(find.text('EasyNotes 1.0.2 is available'), findsOneWidget);
      expect(find.textContaining('app folder'), findsNothing);
      expect(find.text('Sync now'), findsNothing);
      updates.dispose();
    });

    testWidgets('nothing is shown without a newer version', (tester) async {
      answer = () => _release('v$appVersion');
      final updates = await available(tester);
      await tester.pumpWidget(host(updates, windows: true));
      expect(find.byKey(const ValueKey('update-banner')), findsNothing);
      updates.dispose();
    });
  });
}
