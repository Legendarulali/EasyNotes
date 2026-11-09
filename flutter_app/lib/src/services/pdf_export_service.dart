import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../rust/export/pdf_exporter.dart';

bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// Where exported PDFs go: the app documents folder on mobile (then shared via the
/// system sheet), the Downloads folder on desktop.
Future<String> exportDirectory() async {
  if (isMobile) return (await getApplicationDocumentsDirectory()).path;
  final downloads = await getDownloadsDirectory();
  return (downloads ?? await getApplicationDocumentsDirectory()).path;
}

/// `<notebook name>_YYYYMMDD_HHMMSS.pdf` (file-system safe).
String exportFileName({String baseName = 'EasyNotes', DateTime? now}) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  var base = baseName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (base.isEmpty) base = 'EasyNotes';
  return '${base}_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.pdf';
}

Future<String> nextExportPath({String baseName = 'EasyNotes'}) async {
  final dir = await exportDirectory();
  return '$dir${Platform.pathSeparator}${exportFileName(baseName: baseName)}';
}

/// Opens the system share sheet (mobile) or the default PDF viewer (desktop).
Future<void> openExportedPdf(PdfExportReport report, {Rect? shareOrigin}) async {
  if (isMobile) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(report.path, mimeType: 'application/pdf')],
        title: 'EasyNotes PDF',
        sharePositionOrigin: shareOrigin,
      ),
    );
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer', [report.path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [report.path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [report.path]);
  }
}
