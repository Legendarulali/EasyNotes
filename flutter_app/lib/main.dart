import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'src/rust/api/stroke_api.dart' as engine;
import 'src/rust/frb_generated.dart';
import 'src/services/library_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await _registerPdfFont();
  final library = await LibraryService.open();
  runApp(EasyNotesApp(library: library));
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

class EasyNotesApp extends StatelessWidget {
  const EasyNotesApp({super.key, required this.library});

  final LibraryService library;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EasyNotes',
      debugShowCheckedModeBanner: false,
      theme: buildEasyNotesTheme(),
      themeMode: ThemeMode.dark,
      home: HomeScreen(library: library),
    );
  }
}
