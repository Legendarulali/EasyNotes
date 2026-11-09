import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'src/rust/api/stroke_api.dart' as engine;
import 'src/rust/frb_generated.dart';
import 'src/services/library_service.dart';
import 'src/sync/google_auth.dart';
import 'src/sync/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await _registerPdfFont();
  final library = await LibraryService.open();
  final sync = SyncService(library: library, auth: GoogleAuth.forPlatform());
  // Restoring the Google session must never delay the first frame.
  unawaited(sync.start());
  runApp(EasyNotesApp(library: library, sync: sync));
}

/// Hands the bundled Roboto font to the Rust PDF exporter so sticky-note text with
/// Romanian diacritics (ă â î ș ț) is embedded correctly. Falls back to Helvetica if
/// anything goes wrong.
Future<void> _registerPdfFont() async {
  try {
    final data = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    engine.setExportFont(fontBytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } catch (e) {
    debugPrint('PDF font registration failed, using Helvetica fallback: $e');
  }
}

/// Dark, smokey-grey theme shared by the library and the editor chrome.
ThemeData buildEasyNotesTheme() {
  const accent = Color(0xFF8AB4F8);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(primary: accent, surface: kSmokeyBackground, surfaceContainerHigh: const Color(0xFF2C2C2E));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kSmokeyBackground,
    canvasColor: kSmokeyBackground,
    dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF262628)),
    snackBarTheme: const SnackBarThemeData(backgroundColor: Color(0xFF333336), contentTextStyle: TextStyle(color: Colors.white)),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Color(0xFF3A3A3D), borderRadius: BorderRadius.all(Radius.circular(6))),
      textStyle: TextStyle(color: Colors.white, fontSize: 12),
    ),
  );
}

/// Root widget. Also pushes the library to Google Drive when the app goes to the
/// background or is about to exit (open notebooks are saved first).
class EasyNotesApp extends StatefulWidget {
  const EasyNotesApp({super.key, required this.library, required this.sync});

  final LibraryService library;
  final SyncService sync;

  @override
  State<EasyNotesApp> createState() => _EasyNotesAppState();
}

class _EasyNotesAppState extends State<EasyNotesApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => unawaited(widget.sync.flush()),
      onExitRequested: () async {
        // Desktop window closing: finish the backup (bounded) before the process ends.
        await widget.sync.flush(timeout: const Duration(seconds: 15));
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EasyNotes',
      debugShowCheckedModeBanner: false,
      theme: buildEasyNotesTheme(),
      themeMode: ThemeMode.dark,
      home: HomeScreen(library: widget.library, sync: widget.sync),
    );
  }
}
