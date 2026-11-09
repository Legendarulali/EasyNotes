import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/src/rust/document/page.dart';
import 'package:flutter_app/src/rust/document/paper.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/widgets/draggable_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LibraryService', () {
    late Directory tmp;
    late LibraryService lib;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('easynotes_test');
      lib = LibraryService(tmp);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('creates notebooks and folders, folders listed first', () async {
      final ruled = await lib.createNotebook(tmp, 'Matematică', NotebookTemplate.grid);
      await lib.createNotebook(tmp, 'Board', NotebookTemplate.whiteboard);
      await lib.createFolder(tmp, 'Școală');
      final entries = await lib.list(tmp);
      expect(entries.first, isA<FolderEntry>());
      expect(entries.first.name, 'Școală');
      final notebooks = entries.whereType<NotebookEntry>().toList();
      expect(notebooks, hasLength(2));
      final grid = notebooks.firstWhere((n) => n.name == 'Matematică');
      expect(grid.meta.kind, DocumentKind.notebook);
      expect(grid.meta.paper, PaperStyle.matematica);
      expect(ruled.dir.path, endsWith('Matematică$kNotebookExtension'));
    });

    test('names are sanitised and made unique', () async {
      expect(LibraryService.sanitizeName('  a/b:c*?  ', fallback: 'x'), 'a b c');
      expect(LibraryService.sanitizeName('...', fallback: 'x'), 'x');
      final a = await lib.createNotebook(tmp, 'Notes', NotebookTemplate.ruled);
      final b = await lib.createNotebook(tmp, 'Notes', NotebookTemplate.ruled);
      expect(a.name, 'Notes');
      expect(b.name, 'Notes (2)');
      expect(lib.suggestName(tmp, NotebookTemplate.ruled), 'Ruled notebook');
    });

    test('rename, move into a folder and delete', () async {
      final nb = await lib.createNotebook(tmp, 'Draft', NotebookTemplate.ruled);
      final folder = await lib.createFolder(tmp, 'Archive');
      final renamed = await lib.rename(nb, 'Final');
      expect(renamed.name, 'Final');
      final moved = await lib.move(renamed, folder.dir);
      expect(lib.breadcrumbs(moved.dir.parent), ['Archive']);
      expect((await lib.list(folder.dir)).single.name, 'Final');
      expect(() => lib.move(folder, folder.dir), throwsArgumentError);
      await lib.delete(folder);
      expect(await lib.list(tmp), isEmpty);
    });

    test('imports PDFs into a bundle and rejects other files', () async {
      final pdf = Uint8List.fromList('%PDF-1.7\n%%EOF'.codeUnits);
      final entry = await lib.importPdf(tmp, 'Paper', pdf);
      expect(entry.isPdf, isTrue);
      expect(await entry.pdfFile.readAsBytes(), pdf);
      expect(
        () => lib.importPdf(tmp, 'Nope', Uint8List.fromList([1, 2, 3, 4, 5, 6])),
        throwsFormatException,
      );
    });

    test('settings persist', () async {
      await lib.updateSettings({'toolbarDock': 'left'});
      await lib.updateSettings({'other': 1});
      final s = await lib.readSettings();
      expect(s['toolbarDock'], 'left');
      expect(s['other'], 1);
    });
  });

  group('Floating toolbar snapping', () {
    const bounds = Size(1200, 800);
    const size = Size(400, 50);

    test('snaps to edges and corners, floats elsewhere', () {
      expect(snapDock(const Offset(400, 10) & size, bounds), ToolbarDock.top);
      expect(snapDock(const Offset(400, 740) & size, bounds), ToolbarDock.bottom);
      expect(snapDock(const Offset(5, 300) & size, bounds), ToolbarDock.left);
      expect(snapDock(const Offset(790, 300) & size, bounds), ToolbarDock.right);
      expect(snapDock(const Offset(790, 4) & size, bounds), ToolbarDock.topRight);
      expect(snapDock(const Offset(0, 0) & size, bounds), ToolbarDock.topLeft);
      expect(snapDock(const Offset(300, 300) & size, bounds), ToolbarDock.floating);
    });

    test('side docks are vertical', () {
      expect(ToolbarDock.left.axis, Axis.vertical);
      expect(ToolbarDock.right.axis, Axis.vertical);
      expect(ToolbarDock.topRight.axis, Axis.horizontal);
    });

    test('dock offsets stay inside the canvas', () {
      expect(dockOffset(const ToolbarPlacement(ToolbarDock.top), size, bounds), const Offset(400, 12));
      expect(dockOffset(const ToolbarPlacement(ToolbarDock.topRight), size, bounds), const Offset(788, 12));
      expect(dockOffset(const ToolbarPlacement(ToolbarDock.bottomLeft), size, bounds), const Offset(12, 738));
      final floating = dockOffset(const ToolbarPlacement(ToolbarDock.floating, Offset(0.5, 1)), size, bounds);
      expect(floating, const Offset(400, 750));
    });

    test('placement survives a JSON round trip', () {
      const p = ToolbarPlacement(ToolbarDock.floating, Offset(0.25, 0.75));
      final back = ToolbarPlacement.fromJson(p.toJson());
      expect(back.dock, ToolbarDock.floating);
      expect(back.fraction, const Offset(0.25, 0.75));
      expect(ToolbarPlacement.fromJson({}).dock, ToolbarDock.top);
    });
  });

  test('relative dates', () {
    final now = DateTime(2026, 11, 9, 18, 0);
    expect(formatRelativeDate(DateTime(2026, 11, 9, 9, 5), now: now), 'Today 09:05');
    expect(formatRelativeDate(DateTime(2026, 11, 8, 23), now: now), 'Yesterday');
    expect(formatRelativeDate(DateTime(2026, 3, 2), now: now), '2 Mar 2026');
  });
}
