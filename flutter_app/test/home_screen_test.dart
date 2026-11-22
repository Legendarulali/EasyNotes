import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory tmp;
  late LibraryService lib;
  late SyncService sync;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easynotes_home');
    lib = LibraryService(tmp);
    sync = SyncService(library: lib, auth: _NoAuth());
  });

  tearDown(() async {
    sync.dispose();
    await tmp.delete(recursive: true);
  });

  /// Lets real file I/O (listing, creating) finish between frames.
  Future<void> io(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('the name dialog survives the keyboard closing while it fades out (phone)', (tester) async {
    tester.view
      ..physicalSize = const Size(1440, 3120)
      ..devicePixelRatio = 3.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(sync.start);
    await tester.pumpWidget(MaterialApp(theme: buildEasyNotesTheme(), home: HomeScreen(library: lib, sync: sync)));
    await io(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Folder'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // The soft keyboard is up while typing, and goes away as the dialog closes: the
    // closing dialog rebuilds for every inset change.
    tester.view.viewInsets = const FakeViewPadding(bottom: 1200);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  Physics  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    tester.view.resetViewInsets();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(tester.takeException(), isNull);
    await io(tester);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Physics'), findsOneWidget, reason: 'the folder was created with the trimmed name');
    expect(Directory('${tmp.path}${Platform.pathSeparator}Physics').existsSync(), isTrue);
  });
}

class _NoAuth implements GoogleAuth {
  @override
  bool get isConfigured => false;

  @override
  String get setupHint => 'not configured';

  @override
  Future<GoogleAccount?> restore() async => null;

  @override
  Future<GoogleAccount> signIn() => throw UnimplementedError();

  @override
  void cancelSignIn() {}

  @override
  Future<void> signOut() async {}

  @override
  Future<http.Client> client() => throw UnimplementedError();
}
