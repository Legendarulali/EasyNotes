// Captures the screenshots and the logo of the website in `docs/` from the real app (Rust
// engine, library, editor, split screen, pins) filled with demo content:
//
//   flutter test integration_test/website_screenshots_test.dart -d windows \
//     --dart-define=SCREENSHOT_DIR=C:/path/to/easynotes/docs
//
// Skipped unless SCREENSHOT_DIR is set. It uses a temporary library and a demo Google account
// backed by an in-memory Drive: no OAuth client ids, no network, nothing of the real library.
// The handwriting is a small built-in stroke font written through the engine like pen input.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/screens/editor_screen.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/src/canvas/viewport.dart' as canvas;
import 'package:flutter_app/src/editor/editor_controller.dart';
import 'package:flutter_app/src/editor/open_notebooks.dart';
import 'package:flutter_app/src/editor/tools.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:flutter_app/src/rust/geometry/sticky_note.dart';
import 'package:flutter_app/src/rust/geometry/stroke.dart';
import 'package:flutter_app/src/services/library_service.dart';
import 'package:flutter_app/src/sync/drive_remote.dart';
import 'package:flutter_app/src/sync/google_auth.dart';
import 'package:flutter_app/src/sync/sync_service.dart';
import 'package:flutter_app/src/ui/app_logo.dart';
import 'package:flutter_app/widgets/canvas_status_bar.dart';
import 'package:flutter_app/widgets/editor_app_bar.dart';
import 'package:flutter_app/widgets/pinned_overlay.dart';
import 'package:flutter_app/widgets/split_view.dart';
import 'package:flutter_app/widgets/sync_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

const _outDir = String.fromEnvironment('SCREENSHOT_DIR');
const _window = Size(1280, 800);
const _dpr = 2.0;
final _frame = GlobalKey();

const _ink = Color(0xFF1A1A1A);
const _blue = Color(0xFF1E40AF);
const _red = Color(0xFFD32F2F);
const _green = Color(0xFF2E7D32);
const _purple = Color(0xFF6A1B9A);
const _orange = Color(0xFFEF6C00);
const _teal = Color(0xFF00838F);
const _pencilGrey = Color(0xFF55585E);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('website screenshots', skip: _outDir.isEmpty, (tester) async {
    tester.view
      ..physicalSize = _window * _dpr
      ..devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);
    final assets = Directory('$_outDir/assets')..createSync(recursive: true);

    final root = await Directory.systemTemp.createTemp('easynotes_site');
    final lib = LibraryService(root);
    final sync = SyncService(library: lib, auth: _DemoAuth(), remoteFactory: (_) => _MemoryDrive());
    await sync.start();

    // ---------------------------------------------------------------- the demo library
    for (final (folder, names) in [
      ('Physics', ['Mechanics', 'Optics', 'Lab Report 2']),
      ('Chemistry', ['Organic']),
      ('Archive', ['Term 1', 'Term 2']),
    ]) {
      final f = await lib.createFolder(root, folder);
      for (final n in names) {
        await lib.createNotebook(f.dir, n, NotebookTemplate.ruled);
      }
    }
    // Created and closed in reverse order: the library lists the latest edit first.
    final books = <String, NotebookEntry>{};
    final build = OpenNotebooks(library: lib, sync: sync);
    await tester.pumpWidget(_app(EditorScreen(tabs: build)));
    Future<void> make(String name, Future<NotebookEntry> Function() create, void Function(_Hand h) content) async {
      final entry = books[name] = await create();
      final c = build.open(entry);
      await _until(tester, () => c.isOpen);
      await _frames(tester);
      content(_Hand(c, seed: name.hashCode));
      await _frames(tester, entry.isPdf ? 2500 : 300);
      await build.close(c);
      await _frames(tester);
    }

    await make('Meeting Notes', () => lib.createNotebook(root, 'Meeting Notes', NotebookTemplate.ruled), _meeting);
    await make('Sketches', () => lib.createNotebook(root, 'Sketches', NotebookTemplate.whiteboard), _sketches);
    await make('Reading Notes', () => lib.createNotebook(root, 'Reading Notes', NotebookTemplate.ruled), _reading);
    await make('Statistics', () => lib.createNotebook(root, 'Statistics', NotebookTemplate.grid), _statistics);
    await make('Project Ideas', () => lib.createNotebook(root, 'Project Ideas', NotebookTemplate.whiteboard), _ideas);
    await make('Calculus II', () => lib.createNotebook(root, 'Calculus II', NotebookTemplate.ruled), _calculus);
    await make('Homework 4', () => lib.createNotebook(root, 'Homework 4', NotebookTemplate.grid), _homework);
    await make('Lecture 4 – Eigenvalues', () => lib.importPdf(root, 'Lecture 4 – Eigenvalues', _lecturePdf()), _lecture);
    await make('Linear Algebra', () => lib.createNotebook(root, 'Linear Algebra', NotebookTemplate.grid), _algebra);
    await tester.pumpWidget(const SizedBox());
    build.dispose();
    await sync.syncNow();

    // ---------------------------------------------------------------- library + New menu
    await tester.pumpWidget(_app(HomeScreen(library: lib, sync: sync)));
    await _until(tester, () => find.text('Linear Algebra').evaluate().isNotEmpty);
    await _until(tester, () => sync.phase == SyncPhase.synced);
    await _frames(tester, 1200);
    await _shoot(tester, assets, 'screen_home.png');
    _hotspots('home', {
      'new': find.widgetWithText(FilledButton, 'New'),
      'import': find.widgetWithText(OutlinedButton, 'Import PDF'),
      'account': find.byType(AccountButton),
      'folder': find.text('Physics'),
      'card': find.text('Lecture 4 – Eigenvalues'),
    });

    await tester.tap(find.widgetWithText(FilledButton, 'New'));
    await _frames(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1270, 700));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Grid Notebook')));
    await _frames(tester);
    await _shoot(tester, assets, 'screen_new_menu.png');
    _hotspots('menu', {
      for (final item in ['Ruled Notebook', 'Grid Notebook', 'Blank Whiteboard', 'New Folder', 'Import PDF…'])
        item: find.text(item),
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);

    // ---------------------------------------------------------------- editor
    final tabs = OpenNotebooks(library: lib, sync: sync);
    await tester.pumpWidget(_app(EditorScreen(tabs: tabs)));
    final algebra = tabs.open(books['Linear Algebra']!);
    final lecture = tabs.open(books['Lecture 4 – Eigenvalues']!);
    final homework = tabs.open(books['Homework 4']!);
    tabs.activate(0);
    await _until(tester, () => algebra.isOpen && lecture.isOpen && homework.isOpen);
    await _frames(tester, 600);
    algebra.setAutoCorrect(true);
    _zoomTo(algebra.viewport, 0.7, top: 40);
    await _synced(tester, sync, algebra);
    await mouse.moveTo(const Offset(1270, 700));
    await _frames(tester, 600);
    await _shoot(tester, assets, 'screen_editor.png');
    _hotspots('editor', {
      for (final t in [
        'Pen',
        'Pencil',
        'Highlighter',
        'Eraser',
        'Lasso select',
        'Box select',
        'Sticky note',
        'Undo (Ctrl+Z)',
        'Redo (Ctrl+Y)',
        'Custom colour (hex)',
        'Drag to move the toolbar',
        'Shape auto-correct: ON',
        'Finger drawing: one finger draws, two fingers navigate',
        'Split view (Ctrl+\\)',
        'Export PDF',
        'Home',
        'Open a notebook in a new tab',
      ])
        t: find.byTooltip(t),
      'slider': find.byType(Slider),
      'tabs': find.text('Lecture 4 – Eigenvalues'),
    });

    // ---------------------------------------------------------------- pin to screen
    algebra.selectTool(EditorTool.boxSelect);
    algebra.selectBox(const Rect.fromLTRB(60, 150, 400, 290));
    await _frames(tester);
    const pinTip = 'Pin to screen (stays in view while you scroll)';
    await tester.tap(find.byTooltip(pinTip));
    await _until(tester, () => tabs.pins.length == 1);
    // A larger card (resized like with its corner grip), still top right.
    final card = tabs.pins.boxes.single;
    tabs.pins
      ..resize(card, 250)
      ..move(card, Offset(_window.width - 250 - 16, card.position.dy));
    await _frames(tester);
    // Down to page 2, where the exercise needs the matrix of page 1.
    final view = algebra.viewport;
    view.panBy(Offset(0, -(1030 - view.offset.dy) * view.scale));
    await _frames(tester);
    algebra.selectBox(const Rect.fromLTRB(60, 1590, 800, 1760));
    await _frames(tester);
    await _synced(tester, sync, algebra);
    await mouse.moveTo(tester.getCenter(find.byTooltip(pinTip)));
    await _frames(tester, 900);
    await _shoot(tester, assets, 'screen_pin_action.png');
    _hotspots('pin', {
      'pinButton': find.byTooltip(pinTip),
      'card': find.byType(PinnedOverlayBox),
      'opacity': find.byTooltip('Make see-through (75 %)'),
      'unpin': find.byTooltip('Unpin'),
      'resize': find.byTooltip('Drag to resize'),
      'toolbar': find.byTooltip('Drag to move the toolbar'),
      'autocorrect': find.byTooltip('Shape auto-correct: ON'),
      'touch': find.byTooltip('Finger drawing: one finger draws, two fingers navigate'),
    });
    await mouse.moveTo(const Offset(1270, 700));
    algebra.clearSelection();
    for (final box in tabs.pins.boxes.toList()) {
      tabs.pins.remove(box);
    }

    // ---------------------------------------------------------------- split screen
    tabs.activate(1);
    tabs.splitRight(homework);
    await _frames(tester, 2500);
    _zoomTo(homework.viewOf(EditorPane.secondary), 0.62, top: 30);
    await _synced(tester, sync, lecture);
    await _synced(tester, sync, homework);
    await _frames(tester, 1500);
    await _shoot(tester, assets, 'screen_split.png');
    _hotspots('split', {
      'divider': find.byType(SplitDivider),
      'headers': find.byType(PaneHeader),
      'tabLecture': find.widgetWithText(NotebookTab, 'Lecture 4 – Eigenvalues'),
      'tabHomework': find.widgetWithText(NotebookTab, 'Homework 4'),
      'status': find.byType(CanvasStatusBar),
    });

    await tester.pumpWidget(const SizedBox());
    for (final c in tabs.tabs.toList()) {
      await tabs.close(c);
    }
    tabs.dispose();
    sync.dispose();

    await _writeLogo(File('$_outDir/logo.png'), 120);
    // Best effort: Windows may still hold a file of the temporary library for a moment.
    try {
      await root.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Temporary library left behind: $e');
    }
  });
}

// ------------------------------------------------------------------------------ harness

Widget _app(Widget home) => RepaintBoundary(
  key: _frame,
  child: MaterialApp(
    title: 'EasyNotes',
    debugShowCheckedModeBanner: false,
    theme: buildEasyNotesTheme(),
    themeMode: ThemeMode.dark,
    home: home,
  ),
);

Future<void> _frames(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t < ms; t += 20) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _until(WidgetTester tester, bool Function() done, {int tries = 600}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(done(), isTrue, reason: 'condition not reached in time');
}

Future<void> _shoot(WidgetTester tester, Directory dir, String name) async {
  await tester.pump();
  final boundary = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: _dpr);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  debugPrint('SHOT $name ${image.width}x${image.height}');
  image.dispose();
  await File('${dir.path}/$name').writeAsBytes(png!.buffer.asUint8List(), flush: true);
}

/// Writes [c] and backs the library up, so the status bar says "Synced".
Future<void> _synced(WidgetTester tester, SyncService sync, EditorController c) async {
  await c.save();
  await sync.syncNow();
  await _frames(tester, 200);
}

/// Prints where [targets] are, as fractions of the window (the website's callouts use them).
void _hotspots(String screen, Map<String, Finder> targets) {
  for (final MapEntry(:key, :value) in targets.entries) {
    for (final (i, e) in value.evaluate().indexed) {
      final box = e.renderObject! as RenderBox;
      final r = box.localToGlobal(Offset.zero) & box.size;
      String f(double v) => v.toStringAsFixed(4);
      debugPrint(
        'HOTSPOT $screen $key#$i x=${f(r.left / _window.width)} y=${f(r.top / _window.height)} '
        'w=${f(r.width / _window.width)} h=${f(r.height / _window.height)}',
      );
    }
  }
}

/// Zooms [view] to [scale] with world y [top] at the top of its free area.
void _zoomTo(canvas.Viewport view, double scale, {required double top}) {
  view.zoomAt(Offset(view.insets.left, view.insets.top), scale);
  view.panBy(Offset(0, -(top - view.offset.dy) * view.scale));
}

/// Signed in as a made-up account (no avatar picture, nothing real).
class _DemoAuth implements GoogleAuth {
  static const _account = GoogleAccount(email: 'alex.student@example.com', name: 'Alex Student');

  @override
  bool get isConfigured => true;

  @override
  String get setupHint => '';

  @override
  Future<GoogleAccount?> restore() async => _account;

  @override
  Future<GoogleAccount> signIn() async => _account;

  @override
  void cancelSignIn() {}

  @override
  Future<void> signOut() async {}

  @override
  Future<http.Client> client() async => http.Client();
}

class _Node {
  _Node(this.name, this.parent, {this.folder = false, this.props = const {}});
  String name;
  String parent;
  final bool folder;
  final Map<String, String> props;
  String? md5;
}

/// Accepts every upload, keeps only names and checksums.
class _MemoryDrive implements DriveRemote {
  final _nodes = <String, _Node>{};
  String? _root;
  var _next = 0;

  String _add(_Node n) {
    final id = 'n${_next++}';
    _nodes[id] = n;
    return id;
  }

  Iterable<MapEntry<String, _Node>> _in(String parent) => _nodes.entries.where((e) => e.value.parent == parent);

  @override
  Future<String?> findRoot() async => _root;

  @override
  Future<String> createRoot(String name) async => _root = _add(_Node(name, 'root', folder: true));

  @override
  Future<String?> findFolder(String name, String parentId) async =>
      _in(parentId).where((e) => e.value.folder && e.value.name == name).map((e) => e.key).firstOrNull;

  @override
  Future<String> createFolder(String name, String parentId, {Map<String, String> properties = const {}}) async =>
      _add(_Node(name, parentId, folder: true, props: properties));

  @override
  Future<String?> findNotebookFolder(String key) async =>
      _nodes.entries.where((e) => e.value.folder && e.value.props.containsValue(key)).map((e) => e.key).firstOrNull;

  @override
  Future<List<RemoteEntry>> listChildren(String folderId) async => [
    for (final e in _in(folderId)) RemoteEntry(e.key, e.value.name, md5: e.value.md5, isFolder: e.value.folder),
  ];

  /// Contents are not kept.
  @override
  Future<Uint8List> download(String fileId) async => throw RemoteNotFoundException(fileId);

  @override
  Future<bool> isAlive(String id) async => _nodes.containsKey(id);

  @override
  Future<RemoteEntry> upload({
    required String name,
    required String parentId,
    required Uint8List bytes,
    required String mimeType,
    String? fileId,
  }) async {
    final id = fileId ?? _add(_Node(name, parentId));
    final n = _nodes[id] ?? (throw RemoteNotFoundException(id));
    n.md5 = md5.convert(bytes).toString();
    return RemoteEntry(id, name, md5: n.md5);
  }

  @override
  Future<void> move(String id, {required String parentId, required String name}) async {
    _nodes[id]!
      ..parent = parentId
      ..name = name;
  }

  @override
  Future<void> trash(String id) async => _nodes.remove(id);
}

// ------------------------------------------------------------------------------ handwriting

/// A character of the demo handwriting: strokes in em units (cap height 1, baseline at
/// y = 0, y grows downwards) and the advance width.
class _Glyph {
  _Glyph(this.width, this.strokes);
  final double width;
  final List<List<Offset>> strokes;
}

/// Points along an elliptical arc from [from]° to [to]° (0° = right, 90° = down).
List<Offset> _arc(double cx, double cy, double rx, double ry, double from, double to) {
  final n = math.max(8, ((to - from).abs() / 6).ceil());
  return [
    for (var i = 0; i <= n; i++)
      Offset(
        cx + rx * math.cos((from + (to - from) * i / n) * math.pi / 180),
        cy + ry * math.sin((from + (to - from) * i / n) * math.pi / 180),
      ),
  ];
}

/// Polyline through the coordinate pairs [xy].
List<Offset> _l(List<double> xy) => [for (var i = 0; i + 1 < xy.length; i += 2) Offset(xy[i], xy[i + 1])];

List<Offset> _dot(double x, double y) => _arc(x, y, .03, .03, 0, 340);

final Map<String, _Glyph> _glyphs = () {
  final bowl = _arc(.25, -.25, .24, .25, -40, -375);
  final bump = _arc(.26, -.25, .25, .25, 175, 535);
  List<Offset> s(double cx, double top, double w, double h) => [
    ..._arc(cx, top + h / 4, w / 2 * .9, h / 4, -25, -270),
    ..._arc(cx, top + h * 3 / 4, w / 2, h / 4, -90, 150),
  ];
  final o = _arc(.38, -.5, .37, .5, -100, -460);
  final p = [..._l([0, 0, 0, -1, .28, -1]), ..._arc(.28, -.74, .24, .26, -90, 90), ..._l([.28, -.48, 0, -.48])];
  return <String, _Glyph>{
    'a': _Glyph(.56, [[...bowl, ..._l([.49, -.5, .49, -.05, .55, 0])]]),
    'b': _Glyph(.54, [_l([0, -1, 0, 0]), bump]),
    'c': _Glyph(.48, [_arc(.25, -.25, .24, .25, -35, -325)]),
    'd': _Glyph(.56, [_arc(.25, -.25, .24, .25, -30, -370), _l([.5, -1, .5, -.04, .56, 0])]),
    'e': _Glyph(.5, [[..._l([.03, -.24, .48, -.26]), ..._arc(.25, -.25, .23, .25, -5, -325)]]),
    'f': _Glyph(.36, [[..._arc(.31, -.86, .12, .13, -20, -180), ..._l([.19, -.86, .19, 0])], _l([.04, -.5, .36, -.5])]),
    'g': _Glyph(.54, [[...bowl, ..._l([.49, -.5, .49, .18]), ..._arc(.27, .18, .22, .17, 0, 165)]]),
    'h': _Glyph(.5, [_l([0, -1, 0, 0]), [..._arc(.22, -.28, .22, .22, 180, 360), ..._l([.44, -.28, .45, 0])]]),
    'i': _Glyph(.18, [_l([.06, -.5, .06, -.03, .1, 0]), _dot(.065, -.74)]),
    'j': _Glyph(.24, [[..._l([.16, -.5, .16, .2]), ..._arc(.02, .2, .14, .15, 0, 140)], _dot(.165, -.74)]),
    'k': _Glyph(.44, [_l([0, -1, 0, 0]), _l([.38, -.5, .03, -.22, .42, 0])]),
    'l': _Glyph(.18, [_l([.06, -1, .06, -.05, .13, 0])]),
    'm': _Glyph(.72, [
      _l([0, -.5, 0, 0]),
      [..._arc(.17, -.32, .17, .18, 175, 360), ..._l([.34, -.32, .34, 0])],
      [..._arc(.51, -.32, .17, .18, 180, 360), ..._l([.68, -.32, .69, 0])],
    ]),
    'n': _Glyph(.5, [_l([0, -.5, 0, 0]), [..._arc(.22, -.3, .21, .2, 175, 360), ..._l([.43, -.3, .44, 0])]]),
    'o': _Glyph(.5, [_arc(.25, -.25, .24, .25, -100, -460)]),
    'p': _Glyph(.54, [_l([0, -.5, 0, .38]), bump]),
    'q': _Glyph(.56, [[...bowl, ..._l([.49, -.5, .49, .38, .56, .3])]]),
    'r': _Glyph(.36, [_l([0, -.5, 0, 0]), _arc(.2, -.3, .2, .2, 180, 300)]),
    's': _Glyph(.42, [s(.21, -.5, .38, .5)]),
    't': _Glyph(.34, [[..._l([.13, -.85, .13, -.08]), ..._arc(.24, -.08, .11, .08, 180, 90)], _l([0, -.5, .32, -.52])]),
    'u': _Glyph(.5, [[..._l([0, -.5, 0, -.22]), ..._arc(.22, -.22, .22, .22, 180, 0), ..._l([.44, -.22, .44, -.5])], _l([.44, -.5, .45, -.03, .5, 0])]),
    'v': _Glyph(.46, [_l([0, -.5, .22, 0, .46, -.52])]),
    'w': _Glyph(.66, [_l([0, -.5, .15, 0, .33, -.4, .5, 0, .66, -.52])]),
    'x': _Glyph(.44, [_l([0, -.5, .44, 0]), _l([.44, -.5, 0, 0])]),
    'y': _Glyph(.46, [_l([0, -.5, .22, -.02]), _l([.46, -.5, .2, .2, .08, .37])]),
    'z': _Glyph(.44, [_l([.02, -.5, .43, -.5, .02, 0, .45, 0])]),
    'A': _Glyph(.72, [_l([0, 0, .36, -1, .72, 0]), _l([.16, -.38, .57, -.38])]),
    'B': _Glyph(.6, [
      [
        ..._l([0, 0, 0, -1, .3, -1]),
        ..._arc(.3, -.76, .22, .24, -90, 90),
        ..._l([.3, -.52, .02, -.52, .33, -.52]),
        ..._arc(.33, -.26, .25, .26, -90, 90),
        ..._l([.33, 0, 0, 0]),
      ],
    ]),
    'C': _Glyph(.7, [_arc(.38, -.5, .36, .5, -35, -325)]),
    'D': _Glyph(.66, [[..._l([0, 0, 0, -1, .22, -1]), ..._arc(.22, -.5, .42, .5, -90, 90), ..._l([.22, 0, 0, 0])]]),
    'E': _Glyph(.54, [_l([.54, -1, 0, -1, 0, 0, .56, 0]), _l([0, -.52, .44, -.52])]),
    'F': _Glyph(.5, [_l([.52, -1, 0, -1, 0, 0]), _l([0, -.52, .42, -.52])]),
    'G': _Glyph(.74, [[..._arc(.38, -.5, .36, .5, -35, -360), ..._l([.74, -.5, .45, -.5])]]),
    'H': _Glyph(.64, [_l([0, -1, 0, 0]), _l([.62, -1, .62, 0]), _l([0, -.5, .62, -.5])]),
    'I': _Glyph(.14, [_l([.06, -1, .06, 0])]),
    'L': _Glyph(.5, [_l([0, -1, 0, 0, .5, 0])]),
    'M': _Glyph(.86, [_l([0, 0, .06, -1, .43, -.32, .8, -1, .86, 0])]),
    'N': _Glyph(.66, [_l([0, 0, 0, -1, .64, 0, .64, -1])]),
    'O': _Glyph(.76, [o]),
    'P': _Glyph(.54, [p]),
    'Q': _Glyph(.78, [o, _l([.45, -.22, .76, .06])]),
    'R': _Glyph(.58, [p, _l([.24, -.48, .6, 0])]),
    'S': _Glyph(.56, [s(.27, -1, .54, 1)]),
    'T': _Glyph(.64, [_l([0, -1, .66, -1]), _l([.33, -1, .33, 0])]),
    'U': _Glyph(.66, [[..._l([0, -1, 0, -.32]), ..._arc(.32, -.32, .32, .32, 180, 0), ..._l([.64, -.32, .64, -1])]]),
    'V': _Glyph(.7, [_l([0, -1, .35, 0, .7, -1])]),
    'W': _Glyph(.96, [_l([0, -1, .22, 0, .48, -.72, .72, 0, .96, -1])]),
    'X': _Glyph(.64, [_l([0, -1, .64, 0]), _l([.64, -1, 0, 0])]),
    'Y': _Glyph(.64, [_l([0, -1, .33, -.5, .66, -1]), _l([.33, -.5, .33, 0])]),
    '0': _Glyph(.54, [_arc(.27, -.5, .26, .5, -95, -455)]),
    '1': _Glyph(.32, [_l([.04, -.78, .26, -1, .26, 0])]),
    '2': _Glyph(.56, [[..._arc(.27, -.72, .25, .27, 195, 380), ..._l([.51, -.62, .02, 0, .58, 0])]]),
    '3': _Glyph(.54, [[..._arc(.26, -.76, .23, .24, 200, 450), ..._arc(.26, -.27, .27, .27, -90, 155)]]),
    '4': _Glyph(.58, [_l([.36, -1, 0, -.32, .6, -.32]), _l([.44, -.68, .44, 0])]),
    '5': _Glyph(.54, [[..._l([.52, -1, .1, -1, .07, -.56]), ..._arc(.27, -.31, .27, .31, -125, 155)]]),
    '6': _Glyph(.54, [[..._arc(.32, -.3, .3, .7, -62, -180), ..._arc(.28, -.27, .26, .27, 180, -178)]]),
    '7': _Glyph(.54, [_l([0, -1, .56, -1, .2, 0])]),
    '8': _Glyph(.54, [_arc(.28, -.76, .21, .24, -90, -450), _arc(.28, -.26, .26, .26, -90, 270)]),
    '9': _Glyph(.54, [[..._arc(.27, -.72, .24, .27, 0, -360), ..._l([.51, -.72, .46, 0])]]),
    '=': _Glyph(.5, [_l([0, -.54, .48, -.55]), _l([.01, -.3, .5, -.31])]),
    '+': _Glyph(.5, [_l([0, -.42, .5, -.42]), _l([.25, -.68, .25, -.16])]),
    '-': _Glyph(.46, [_l([0, -.42, .46, -.43])]),
    '±': _Glyph(.5, [_l([0, -.54, .5, -.54]), _l([.25, -.8, .25, -.28]), _l([0, -.12, .5, -.12])]),
    '·': _Glyph(.16, [_dot(.06, -.42)]),
    '.': _Glyph(.14, [_dot(.05, -.03)]),
    ',': _Glyph(.14, [_l([.07, -.04, .02, .16])]),
    ':': _Glyph(.16, [_dot(.06, -.45), _dot(.06, -.03)]),
    '!': _Glyph(.16, [_l([.07, -1, .07, -.3]), _dot(.07, -.03)]),
    "'": _Glyph(.12, [_l([.1, -1, .04, -.72])]),
    '/': _Glyph(.42, [_l([0, .12, .42, -1.0])]),
    '(': _Glyph(.28, [_arc(.36, -.45, .32, .66, 235, 125)]),
    ')': _Glyph(.28, [_arc(-.06, -.45, .32, .66, -55, 55)]),
    'λ': _Glyph(.56, [_l([0, -1, .1, -.98, .56, 0]), _l([.3, -.52, .02, 0])]),
    'π': _Glyph(.6, [_l([0, -.5, .6, -.52]), _l([.16, -.5, .14, 0]), _l([.44, -.5, .46, -.04, .54, 0])]),
    '∫': _Glyph(.4, [[..._arc(.42, -.92, .1, .1, -20, -180), ..._l([.32, -.92, .2, .18]), ..._arc(.1, .18, .1, .1, 0, 160)]]),
    '⇒': _Glyph(.74, [_l([0, -.56, .56, -.56]), _l([0, -.28, .56, -.28]), _l([.48, -.72, .74, -.42, .48, -.12])]),
    '→': _Glyph(.68, [_l([0, -.42, .66, -.42]), _l([.5, -.56, .68, -.42, .5, -.28])]),
    '✓': _Glyph(.6, [_l([0, -.42, .2, -.08, .62, -.92])]),
  };
}();

/// Writes with the built-in stroke font through [c], as pen input would.
class _Hand {
  _Hand(this.c, {int seed = 7}) : _rnd = math.Random(seed);

  final EditorController c;
  final math.Random _rnd;
  static const slant = 0.12;

  /// Roughly normal noise in [-1, 1].
  double _n() => (_rnd.nextDouble() + _rnd.nextDouble() + _rnd.nextDouble() - 1.5) / 1.5;

  static double measure(String text, double size) {
    var x = 0.0;
    var small = false;
    for (final ch in text.split('')) {
      if (ch == '^' || ch == '_') {
        small = true;
        continue;
      }
      final s = small ? size * .6 : size;
      small = false;
      x += ch == ' ' ? .36 * s : (_glyphs[ch]!.width + .13) * s;
    }
    return x;
  }

  void _brush(EditorTool tool, Color color, double width) {
    c.selectTool(tool);
    c.setColor(color);
    c.setWidth(width);
  }

  /// Writes [text] with the baseline starting at [at] ([size] = cap height in world units).
  /// `^x` / `_x` raise / lower the next character. Returns the x after the text.
  double write(String text, Offset at, double size, {Color color = _ink, EditorTool tool = EditorTool.pen, double? width}) {
    _brush(tool, color, width ?? (size * .085).clamp(1.6, 4.2));
    var x = at.dx;
    var mode = 0;
    for (final ch in text.split('')) {
      if (ch == '^' || ch == '_') {
        mode = ch == '^' ? 1 : -1;
        continue;
      }
      final s = mode == 0 ? size : size * .6;
      final base = at.dy + (mode == 1 ? -.52 * size : (mode == -1 ? .2 * size : 0));
      mode = 0;
      if (ch == ' ') {
        x += .36 * s;
        continue;
      }
      final g = _glyphs[ch] ?? (throw ArgumentError('no glyph for "$ch"'));
      final k = s * (1 + .035 * _n());
      final origin = Offset(x, base + .02 * s * _n());
      final rot = .035 * _n();
      final (sin, cos) = (math.sin(rot), math.cos(rot));
      for (final stroke in g.strokes) {
        _stroke(tool, [
          for (final p in stroke)
            () {
              final q = Offset(p.dx - p.dy * slant, p.dy) * k;
              return origin + Offset(q.dx * cos - q.dy * sin, q.dx * sin + q.dy * cos);
            }(),
        ], s);
      }
      x += (g.width + .13 + .025 * _n()) * s;
    }
    return x;
  }

  /// A hand-drawn straight-ish line.
  void line(Offset a, Offset b, {Color color = _ink, double width = 2.6, EditorTool tool = EditorTool.pen, double bow = 1.5}) {
    _brush(tool, color, width);
    final d = b - a;
    final normal = Offset(-d.dy, d.dx) / d.distance;
    _stroke(tool, [for (var i = 0; i <= 24; i++) Offset.lerp(a, b, i / 24)! + normal * (bow * math.sin(math.pi * i / 24))], 30);
  }

  /// A matrix whose left bracket starts at [at] (top-left). Returns the x after it.
  double matrix(Offset at, List<List<String>> rows, double size, {Color color = _ink}) {
    final cols = rows.first.length;
    final widths = [for (var j = 0; j < cols; j++) rows.map((r) => measure(r[j], size)).reduce(math.max)];
    final gap = .7 * size;
    final pad = .38 * size;
    final rowStep = 1.5 * size;
    final top = at.dy;
    final bottom = top + .45 * size + (rows.length - 1) * rowStep + size + .3 * size;
    final w = pad * 2 + widths.reduce((a, b) => a + b) + gap * (cols - 1);
    final width = (size * .085).clamp(1.6, 4.2);
    _brush(EditorTool.pen, color, width);
    final x0 = at.dx;
    final hook = .22 * size;
    _stroke(EditorTool.pen, _l([x0 + hook, top, x0, top + 2, x0, bottom - 2, x0 + hook, bottom]), size);
    _stroke(EditorTool.pen, _l([x0 + w - hook, top, x0 + w, top + 2, x0 + w, bottom - 2, x0 + w - hook, bottom]), size);
    for (var i = 0; i < rows.length; i++) {
      var x = x0 + pad;
      for (var j = 0; j < cols; j++) {
        final text = rows[i][j];
        write(text, Offset(x + widths[j] - measure(text, size), top + .45 * size + size + i * rowStep), size, color: color);
        x += widths[j] + gap;
      }
    }
    return x0 + w + .3 * size;
  }

  /// A stacked fraction on the math axis of baseline [base]. Returns the x after it.
  double fraction(double x, double base, String num, String den, double size, {Color color = _ink}) {
    final s = size * .85;
    final w = math.max(measure(num, s), measure(den, s)) + .35 * s;
    final axis = base - .42 * size;
    write(num, Offset(x + (w - measure(num, s)) / 2, axis - .3 * size), s, color: color);
    line(Offset(x, axis), Offset(x + w, axis + .5), color: color, width: (size * .08).clamp(1.6, 4.0), bow: .6);
    write(den, Offset(x + (w - measure(den, s)) / 2, axis + .3 * size + s), s, color: color);
    return x + w + .25 * size;
  }

  /// √ over [inner], written from [x] on baseline [base]. Returns the x after it.
  double sqrt(double x, double base, String inner, double size, {Color color = _ink}) {
    final innerX = x + .62 * size;
    final end = write(inner, Offset(innerX, base), size, color: color);
    _brush(EditorTool.pen, color, (size * .085).clamp(1.6, 4.2));
    final top = base - 1.18 * size;
    _stroke(EditorTool.pen, _l([x, base - .42 * size, x + .12 * size, base - .5 * size, x + .3 * size, base + .1 * size, x + .52 * size, top, end + .1 * size, top - 1]), size);
    return end + .2 * size;
  }

  void highlight(Rect r, {Color color = const Color(0xFFFFEB3B)}) {
    _brush(EditorTool.highlighter, color, r.height);
    final y = r.center.dy;
    _stroke(EditorTool.highlighter, [for (var i = 0; i <= 20; i++) Offset(r.left + r.width * i / 20, y + math.sin(i / 3) * .8)], 30);
  }

  /// A rough shape drawn with auto-correct on (the engine snaps it to clean geometry).
  void shape(List<Offset> points, {Color color = _ink, double width = 3}) {
    _brush(EditorTool.pen, color, width);
    c.setAutoCorrect(true);
    _raw(EditorTool.pen, points);
    c.setAutoCorrect(false);
    final last = c.scene.strokes.last.render;
    if (last.kind == RenderKind.filledOutline) debugPrint('SHAPE NOT SNAPPED at ${points.first}');
  }

  void note(Offset at, Size size, String text, Color color, {double fontSize = 18}) {
    final n = c.createNote(at);
    c.updateNote(
      StickyNote(
        id: n.id,
        x: at.dx,
        y: at.dy,
        width: size.width,
        height: size.height,
        color: color.toARGB32(),
        text: text,
        fontSize: fontSize,
      ),
    );
    c.clearSelection();
  }

  /// Densify, round the corners a little, add a slow wobble and a pressure profile.
  void _stroke(EditorTool tool, List<Offset> world, double size) {
    var pts = _resample(world, math.max(.5, size * .05));
    pts = _resample(_chaikin(_chaikin(pts)), math.max(.6, size * .03));
    if (pts.length < 2) pts = [world.first, world.first + const Offset(.4, .3)];
    final phase = _rnd.nextDouble() * 10;
    final amp = size * .008;
    final out = <(Offset, double)>[];
    for (var i = 0; i < pts.length; i++) {
      final t = i / (pts.length - 1);
      final wob = Offset(math.sin(phase + t * 5.1), math.cos(phase * 1.3 + t * 4.3)) * amp;
      final taper = math.min(1.0, math.min(t / .1, (1 - t) / .16)).clamp(0.0, 1.0);
      out.add((pts[i] + wob, .34 + .3 * taper + .04 * math.sin(phase + t * 9)));
    }
    _feed(tool, out);
  }

  void _raw(EditorTool tool, List<Offset> pts) => _feed(tool, [for (final p in pts) (p, .5)]);

  void _feed(EditorTool tool, List<(Offset, double)> pts) {
    c.beginStroke(tool, pts.first.$1, pts.first.$2);
    for (final (p, pressure) in pts.skip(1)) {
      c.addPoint(p, pressure);
    }
    c.finishStroke(tool);
  }

  // Rough shapes, as a hand would draw them.
  List<Offset> roughLoop(List<Offset> corners) {
    final pts = <Offset>[];
    for (var i = 0; i < corners.length; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % corners.length];
      final d = b - a;
      final normal = Offset(-d.dy, d.dx) / d.distance;
      final bow = 1.2 * _n();
      final n = math.max(6, (d.distance / 3).ceil());
      for (var k = 0; k < n; k++) {
        final t = k / n;
        pts.add(Offset.lerp(a, b, t)! + normal * (bow * math.sin(math.pi * t) + .25 * _n()));
      }
    }
    return pts..add(corners.first + Offset(_n(), _n()));
  }

  List<Offset> roughEllipse(Offset center, double rx, double ry) => [
    for (var i = 0; i <= 74; i++)
      () {
        final a = -math.pi / 2 + 2 * math.pi * i / 72;
        final wobble = 1 + .012 * math.sin(3 * a + 1);
        return center + Offset(math.cos(a) * rx * wobble, math.sin(a) * ry * wobble);
      }(),
  ];

  List<Offset> roughLine(Offset a, Offset b) => [
    for (var i = 0; i <= 30; i++) Offset.lerp(a, b, i / 30)! + Offset(0, .8 * math.sin(i / 4) + .2 * _n()),
  ];

  List<Offset> regular(Offset center, double r, int n, {double start = -90}) => [
    for (var i = 0; i < n; i++) center + Offset.fromDirection((start + 360 * i / n) * math.pi / 180, r),
  ];
}

List<Offset> _resample(List<Offset> pts, double step) {
  if (pts.length < 2) return pts;
  final out = <Offset>[pts.first];
  var carry = 0.0;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    final len = (b - a).distance;
    var t = step - carry;
    while (t <= len) {
      out.add(Offset.lerp(a, b, t / len)!);
      t += step;
    }
    carry = len - (t - step);
  }
  if ((out.last - pts.last).distance > step * .25) out.add(pts.last);
  return out;
}

List<Offset> _chaikin(List<Offset> p) {
  if (p.length < 3) return p;
  return [
    p.first,
    for (var i = 0; i + 1 < p.length; i++) ...[Offset.lerp(p[i], p[i + 1], .25)!, Offset.lerp(p[i], p[i + 1], .75)!],
    p.last,
  ];
}

// ------------------------------------------------------------------------------ notebooks

void _underline(_Hand h, double x0, double x1, double y, Color color) =>
    h.line(Offset(x0, y), Offset(x1, y - 3), color: color, width: 3, bow: 1.5);

void _algebra(_Hand h) {
  // Page 1: matrices.
  final t = h.write('Matrices', const Offset(70, 110), 46, color: _blue);
  _underline(h, 64, t + 6, 126, _blue);
  h.write('Oct 14', const Offset(842, 92), 20, tool: EditorTool.pencil, color: _pencilGrey);
  var x = h.write('A =', const Offset(84, 232), 32);
  h.matrix(Offset(x + 8, 172), const [['2', '1'], ['1', '3']], 30);
  x = h.write('det A = 2·3 - 1·1 =', const Offset(84, 352), 30);
  h.highlight(Rect.fromLTRB(x - 6, 318, x + 58, 360));
  h.write('5', Offset(x + 14, 352), 30, color: _red);
  x = h.write('A^-^1 =', const Offset(84, 470), 30);
  x = h.fraction(x + 6, 470, '1', '5', 30);
  h.matrix(Offset(x, 410), const [['3', '-1'], ['-1', '2']], 30);
  h.write('check: A A^-^1 = I ✓', const Offset(600, 470), 22, tool: EditorTool.pencil, color: _pencilGrey);
  h.note(const Offset(640, 160), const Size(280, 150), 'Exam on Friday!\nReview: det, inverse,\neigenvalues (ch. 4)', const Color(0xFFFFF59D));

  final s = h.write('Shapes', const Offset(70, 600), 34, color: _blue);
  _underline(h, 64, s + 6, 614, _blue);
  void label(String text, double cx, double y) =>
      h.write(text, Offset(cx - _Hand.measure(text, 18) / 2, y), 18, tool: EditorTool.pencil, color: _pencilGrey);
  h.shape(h.roughLine(const Offset(80, 720), const Offset(190, 668)), color: _ink);
  label('line', 135, 770);
  h.shape(h.roughEllipse(const Offset(310, 694), 46, 46), color: _blue);
  label('circle', 310, 770);
  h.shape(h.roughEllipse(const Offset(480, 694), 70, 40), color: _teal);
  label('ellipse', 480, 770);
  h.shape(h.roughLoop(const [Offset(600, 738), Offset(710, 738), Offset(655, 648)]), color: _green);
  label('triangle', 655, 770);
  h.shape(h.roughLoop(const [Offset(780, 652), Offset(900, 652), Offset(900, 738), Offset(780, 738)]), color: _red);
  label('rectangle', 840, 770);
  h.shape(h.roughLoop(const [Offset(80, 900), Offset(200, 900), Offset(172, 828), Offset(108, 828)]), color: _orange);
  label('trapezoid', 140, 940);
  h.shape(h.roughLoop(h.regular(const Offset(310, 862), 46, 6, start: 0)), color: _purple);
  label('hexagon', 310, 940);
  h.shape(h.roughLoop(h.regular(const Offset(480, 864), 46, 5)), color: _teal);
  label('pentagon', 480, 940);
  final tips = h.regular(const Offset(655, 866), 54, 5);
  h.shape(h.roughLoop([tips[0], tips[2], tips[4], tips[1], tips[3]]), color: _orange);
  label('star', 655, 940);
  h.note(const Offset(770, 820), const Size(170, 110), 'Area: A = πr²\nPerimeter: 2πr', const Color(0xFFA5D6A7), fontSize: 16);

  // Page 2: an exercise that needs the matrix of page 1, then the quadratic formula.
  final e = h.write('Exercise 1', const Offset(70, 1110), 38, color: _blue);
  _underline(h, 64, e + 6, 1126, _blue);
  x = h.write('Solve  A x = b  for  b =', const Offset(84, 1222), 28);
  h.matrix(Offset(x + 10, 1166), const [['4'], ['7']], 28);
  x = h.write('x = A^-^1 b =', const Offset(84, 1346), 28);
  x = h.fraction(x + 6, 1346, '1', '5', 28);
  x = h.matrix(Offset(x, 1290), const [['3·4 - 7'], ['-4 + 2·7']], 28);
  x = h.write('=', Offset(x + 4, 1346), 28);
  x = h.matrix(Offset(x + 10, 1290), const [['1'], ['2']], 28);
  h.write('✓', Offset(x + 10, 1346), 30, color: _green);

  final q = h.write('Quadratic formula', const Offset(70, 1490), 36, color: _blue);
  _underline(h, 64, q + 6, 1506, _blue);
  x = h.write('ax^2 + bx + c = 0', const Offset(90, 1670), 30);
  x = h.write('⇒', Offset(x + 18, 1670), 30);
  x = h.write('x =', Offset(x + 18, 1670), 30);
  final axis = 1670 - .42 * 30;
  final numStart = x + 10;
  var n = h.write('-b ±', Offset(numStart + 8, axis - 12), 28);
  n = h.sqrt(n + 6, axis - 12, 'b^2 - 4ac', 28);
  h.line(Offset(numStart, axis), Offset(n + 4, axis + 1), width: 2.6, bow: .6);
  h.write('2a', Offset(numStart + (n - numStart) / 2 - 20, axis + 44), 28);
  h.shape(h.roughLoop([const Offset(70, 1610), Offset(n + 30, 1610), Offset(n + 30, 1730), const Offset(70, 1730)]), color: _red, width: 2.4);
}

void _lecture(_Hand h) {
  // Pages are 1000 units wide, 1.6807 units per PDF point (y = (842 − pdfY) · k).
  const k = 1000 / 595;
  double y(double pdf) => (842 - pdf) * k;
  h.highlight(Rect.fromLTRB(250 * k, y(633), 345 * k, y(610)));
  h.shape(h.roughEllipse(Offset(102 * k, y(354)), 76, 22), color: _red, width: 2.4);
  h.write('exam!', Offset(470, y(296) + 4), 26, color: _red);
  h.line(Offset(456, y(296) - 8), Offset(370, y(296) - 8), color: _red, width: 2.4, bow: -2);
  h.line(Offset(370, y(296) - 8), Offset(386, y(296) - 19), color: _red, width: 2.4, bow: 0);
  h.line(Offset(370, y(296) - 8), Offset(386, y(296) + 3), color: _red, width: 2.4, bow: 0);
  h.write('✓ 1 + 3 = 4 = tr A', Offset(600, y(388) + 2), 22, color: _blue);
  h.write('A^k is easy!', Offset(600, y(200) + 2), 22, color: _blue);
}

void _homework(_Hand h) {
  final e = h.write('Exercise 1', const Offset(70, 100), 36, color: _blue);
  _underline(h, 64, e + 6, 116, _blue);
  final x = h.write('B =', const Offset(84, 212), 30);
  h.matrix(Offset(x + 8, 154), const [['4', '1'], ['2', '3']], 28);
  h.write('det(B - λI) = (4 - λ)(3 - λ) - 2', const Offset(84, 340), 28);
  h.write('= λ^2 - 7λ + 10', const Offset(246, 414), 28);
  h.write('= (λ - 2)(λ - 5) = 0', const Offset(246, 488), 28);
  final end = h.write('λ_1 = 2 ,   λ_2 = 5', const Offset(110, 584), 30, color: _red);
  h.shape(h.roughLoop([const Offset(92, 540), Offset(end + 20, 540), Offset(end + 20, 610), const Offset(92, 610)]), color: _red, width: 2.4);
  final e2 = h.write('Exercise 2', const Offset(70, 720), 36, color: _blue);
  _underline(h, 64, e2 + 6, 736, _blue);
  h.write('det(A^T - λI) = det((A - λI)^T)', const Offset(84, 826), 28);
  h.write('= det(A - λI)  ✓', const Offset(246, 900), 28);
}

void _calculus(_Hand h) {
  final t = h.write('Integration by parts', const Offset(70, 110), 42, color: _blue);
  _underline(h, 64, t + 6, 126, _blue);
  h.write('∫ u dv = uv - ∫ v du', const Offset(100, 240), 36);
  h.write('Example:', const Offset(70, 350), 28, color: _red);
  h.write('∫ x e^x dx = x e^x - ∫ e^x dx', const Offset(100, 450), 32);
  h.write('= (x - 1) e^x + C', const Offset(236, 540), 32);
}

void _statistics(_Hand h) {
  final t = h.write('Statistics', const Offset(70, 110), 44, color: _blue);
  _underline(h, 64, t + 6, 126, _blue);
  h.shape(h.roughLine(const Offset(100, 560), const Offset(640, 562)));
  h.shape([for (var i = 0; i <= 30; i++) Offset(100 + .5 * math.sin(i / 3), 560 - 360 * i / 30)]);
  final heights = <double>[120, 230, 300, 190, 90];
  final colors = [_blue, _teal, _green, _orange, _red];
  for (var i = 0; i < 5; i++) {
    final l = 140 + 100.0 * i;
    h.shape(h.roughLoop([Offset(l, 556), Offset(l + 64, 556), Offset(l + 64, 556 - heights[i]), Offset(l, 556 - heights[i])]), color: colors[i]);
  }
  h.write('mean = 4.2', const Offset(680, 300), 30);
  h.write('n = 25', const Offset(680, 380), 30);
}

// Whiteboard thumbnails show the middle of the content area (cards crop them to portrait),
// so these two keep their content in x 150…650 and reach down to y ≈ 600.
void _ideas(_Hand h) {
  h.write('Project ideas', const Offset(160, 110), 40, color: _blue);
  h.note(const Offset(160, 160), const Size(200, 120), 'Study planner\nwith reminders', const Color(0xFFFFF59D), fontSize: 18);
  h.note(const Offset(440, 160), const Size(200, 120), 'Flashcards from\nmy notes', const Color(0xFF90CAF9), fontSize: 18);
  h.note(const Offset(300, 420), const Size(200, 120), 'Group whiteboard\nfor the lab', const Color(0xFFF48FB1), fontSize: 18);
  h.line(const Offset(368, 220), const Offset(432, 220), width: 3);
  h.line(const Offset(432, 220), const Offset(420, 210), width: 3, bow: 0);
  h.line(const Offset(432, 220), const Offset(420, 231), width: 3, bow: 0);
  h.line(const Offset(260, 288), const Offset(330, 412), width: 3);
  h.shape(h.roughEllipse(const Offset(590, 515), 40, 40), color: _orange);
  h.write('vote on Fri!', const Offset(160, 600), 26, color: _red);
}

void _reading(_Hand h) {
  final t = h.write('Chapter 3', const Offset(70, 110), 44, color: _blue);
  _underline(h, 64, t + 6, 126, _blue);
  h.write('- memory is rebuilt,', const Offset(80, 220), 30);
  h.write('not replayed', const Offset(116, 290), 30);
  h.write('- spaced practice beats', const Offset(80, 380), 30);
  h.write('cramming (p. 52)', const Offset(116, 450), 30);
  h.write('- teach it to learn it!', const Offset(80, 540), 30, color: _red);
}

void _sketches(_Hand h) {
  h.write('sketches', const Offset(160, 140), 40, color: _blue);
  h.shape(h.roughLoop(const [Offset(180, 430), Offset(340, 430), Offset(340, 590), Offset(180, 590)]), color: _red);
  h.shape(h.roughLoop(const [Offset(160, 430), Offset(360, 430), Offset(260, 310)]), color: _orange);
  h.shape(h.roughEllipse(const Offset(480, 250), 55, 55), color: _orange);
  final tips = h.regular(const Offset(560, 480), 80, 5);
  h.shape(h.roughLoop([tips[0], tips[2], tips[4], tips[1], tips[3]]), color: _purple);
}

void _meeting(_Hand h) {
  final t = h.write('Group project', const Offset(70, 110), 42, color: _blue);
  _underline(h, 64, t + 6, 126, _blue);
  h.write('- split the tasks by Fri', const Offset(80, 220), 30);
  h.write('- slides: Ana + me', const Offset(80, 300), 30);
  h.write('- next meeting: Tue 3 pm', const Offset(80, 380), 30, color: _red);
}

// ------------------------------------------------------------------------------ lecture PDF

const _pdfSymbol = {'λ': 'l', '−': '-', '⇒': '\xDE'};
const _pdfSub = {'₁': '1', '₂': '2', 'ₙ': 'n'};
const _pdfSup = {'⁻': (true, '-'), '¹': (false, '1'), '²': (false, '2'), 'ᵀ': (false, 'T'), 'ᵏ': (false, 'k'), '⁵': (false, '5')};

class _PdfPage {
  final _ops = StringBuffer();
  static String _n(double v) => v.toStringAsFixed(2);
  static String _esc(String s) => s.replaceAll('\\', '\\\\').replaceAll('(', '\\(').replaceAll(')', '\\)');

  /// Text from ([x], [y]); λ, −, ⇒ come from the Symbol font, ₁ ₂ ₙ are lowered, ⁻ ¹ ² ᵀ ᵏ raised.
  void text(double x, double y, String s, {String font = 'F3', double size = 11.5, List<double> rgb = const [.13, .13, .15]}) {
    _ops.write('BT ${rgb.map(_n).join(' ')} rg ${_n(x)} ${_n(y)} Td ');
    String? f;
    var sz = -1.0;
    var rise = 0.0;
    final run = StringBuffer();
    void flush() {
      if (run.isEmpty) return;
      _ops.write('(${_esc(run.toString())}) Tj ');
      run.clear();
    }

    void use(String nf, double nsz, double nrise) {
      if (nf != f || nsz != sz) {
        flush();
        _ops.write('/$nf ${_n(nsz)} Tf ');
        f = nf;
        sz = nsz;
      }
      if (nrise != rise) {
        flush();
        _ops.write('${_n(nrise)} Ts ');
        rise = nrise;
      }
    }

    for (final ch in s.split('')) {
      final sym = _pdfSymbol[ch];
      final sub = _pdfSub[ch];
      final sup = _pdfSup[ch];
      if (sym != null) {
        use('F5', size, 0);
        run.write(sym);
      } else if (sub != null) {
        use(font, size * .7, -size * .22);
        run.write(sub);
      } else if (sup != null) {
        use(sup.$1 ? 'F5' : font, size * .7, size * .42);
        run.write(sup.$2);
      } else {
        use(font, size, 0);
        run.write(ch == '…' ? '\x85' : ch);
      }
    }
    flush();
    _ops.writeln('0 Ts ET');
  }

  void line(double x1, double y1, double x2, double y2, {double width = .8, double gray = .13}) =>
      _ops.writeln('q ${_n(gray)} G ${_n(width)} w ${_n(x1)} ${_n(y1)} m ${_n(x2)} ${_n(y2)} l S Q');

  void box(double x, double y, double w, double h, List<double> fill, List<double> stroke) => _ops.writeln(
    'q ${fill.map(_n).join(' ')} rg ${stroke.map(_n).join(' ')} RG .8 w ${_n(x)} ${_n(y)} ${_n(w)} ${_n(h)} re B Q',
  );

  /// A 2 × 2 matrix with its left bracket at [x], centred on [mid] (baseline of the line).
  double matrix(double x, double mid, List<List<String>> rows, {double size = 11.5}) {
    final top = mid + 15;
    final bottom = mid - 13;
    line(x + 3, top, x, top);
    line(x, top, x, bottom);
    line(x, bottom, x + 3, bottom);
    for (final (i, row) in rows.indexed) {
      for (final (j, v) in row.indexed) {
        text(x + 6 + j * 13, mid + 5 - i * 14, v, size: size);
      }
    }
    final r = x + 6 + rows.first.length * 13;
    line(r - 3, top, r, top);
    line(r, top, r, bottom);
    line(r, bottom, r - 3, bottom);
    return r + 4;
  }

  void chrome(int page) {
    text(64, 804, 'MATH 201 · LINEAR ALGEBRA', font: 'F1', size: 8.5, rgb: const [.42, .44, .5]);
    text(452, 804, 'Lecture 4 · Week 6', font: 'F1', size: 8.5, rgb: const [.42, .44, .5]);
    line(64, 796, 531, 796, width: .6, gray: .78);
    text(294, 40, '$page', font: 'F1', size: 9, rgb: const [.42, .44, .5]);
  }
}

const _heading = [.1, .22, .5];

Uint8List _lecturePdf() {
  final p1 = _PdfPage()..chrome(1);
  p1
    ..text(64, 748, 'Eigenvalues and Eigenvectors', font: 'F2', size: 24)
    ..text(64, 726, 'Lecture notes · Department of Mathematics', font: 'F1', size: 10.5, rgb: const [.42, .44, .5])
    ..text(64, 686, '4.1   Definition', font: 'F2', size: 13, rgb: _heading)
    ..text(64, 664, 'Let A be an n × n matrix. A nonzero vector v is called an eigenvector of A')
    ..text(64, 648, 'if there is a scalar λ such that')
    ..text(258, 616, 'A v = λ v', font: 'F4', size: 16)
    ..text(503, 616, '(4.1)')
    ..text(64, 588, 'The scalar λ is called an eigenvalue of A, and v is an eigenvector belonging')
    ..text(64, 572, 'to λ. An eigenvector is only determined up to a nonzero factor.')
    ..box(64, 500, 467, 52, const [.93, .955, 1], const [.6, .72, .93])
    ..text(78, 532, 'Characteristic equation', font: 'F2', size: 11, rgb: _heading)
    ..text(78, 512, 'λ is an eigenvalue of A if and only if   det(A − λI) = 0.')
    ..text(64, 470, '4.2   Example', font: 'F2', size: 13, rgb: _heading)
    ..text(64, 438, 'Let')
    ..text(86, 438, 'A =', font: 'F4');
  final after = p1.matrix(108, 438, const [['2', '1'], ['1', '2']]);
  p1
    ..text(after, 438, '. Then')
    ..text(64, 404, 'det(A − λI) = (2 − λ)² − 1 = λ² − 4λ + 3 = (λ − 1)(λ − 3),')
    ..text(64, 386, 'so the eigenvalues of A are λ₁ = 1 and λ₂ = 3.')
    ..text(64, 350, 'Theorem 4.3.', font: 'F2', size: 11.5)
    ..text(138, 350, 'Eigenvectors belonging to distinct eigenvalues of A are', font: 'F4')
    ..text(64, 334, 'linearly independent.', font: 'F4')
    ..text(64, 296, '4.3   Diagonalization', font: 'F2', size: 13, rgb: _heading)
    ..text(64, 274, 'If A has n linearly independent eigenvectors v₁, …, vₙ, then')
    ..text(250, 244, 'A = P D P⁻¹', font: 'F4', size: 16)
    ..text(503, 244, '(4.2)')
    ..text(64, 216, 'where the columns of P are the eigenvectors and D = diag(λ₁, …, λₙ).')
    ..text(64, 200, 'Then Aᵏ = P Dᵏ P⁻¹, so powers of A are cheap to compute.');

  final p2 = _PdfPage()..chrome(2);
  p2
    ..text(64, 748, 'Exercises', font: 'F2', size: 18)
    ..text(64, 716, '1.   Find the eigenvalues and eigenvectors of')
    ..text(286, 716, 'B =', font: 'F4');
  p2.text(p2.matrix(308, 716, const [['4', '1'], ['2', '3']]), 716, '.');
  p2
    ..text(64, 680, '2.   Show that A and Aᵀ have the same eigenvalues.')
    ..text(64, 656, '3.   Let λ be an eigenvalue of an invertible matrix A. Show that 1/λ is an')
    ..text(86, 640, 'eigenvalue of A⁻¹.')
    ..text(64, 612, '4.   Diagonalize')
    ..text(146, 612, 'C =', font: 'F4');
  p2.text(p2.matrix(168, 612, const [['1', '2'], ['2', '1']]), 612, ' if possible, and compute C⁵.');
  p2.text(64, 570, 'Reading: sections 5.1 to 5.3 of the textbook.', font: 'F4');
  return _pdf([p1, p2]);
}

Uint8List _pdf(List<_PdfPage> pages) {
  const fonts = ['Helvetica', 'Helvetica-Bold', 'Times-Roman', 'Times-Italic', 'Symbol'];
  final pageIds = [for (var i = 0; i < pages.length; i++) 8 + 2 * i];
  final resources = [for (var i = 0; i < fonts.length; i++) '/F${i + 1} ${3 + i} 0 R'].join(' ');
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] /Count ${pages.length} >>',
    for (final f in fonts)
      '<< /Type /Font /Subtype /Type1 /BaseFont /$f${f == 'Symbol' ? '' : ' /Encoding /WinAnsiEncoding'} >>',
    for (final (i, p) in pages.indexed) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << $resources >> >> '
          '/Contents ${pageIds[i] + 1} 0 R >>',
      '<< /Length ${p._ops.length} >>\nstream\n${p._ops}\nendstream',
    ],
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (final (i, o) in objects.indexed) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n$o\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}

// ------------------------------------------------------------------------------ logo

/// The app mark (see [paintAppLogo]) as a PNG.
Future<void> _writeLogo(File file, int size) async {
  final image = await renderAppLogo(size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
  debugPrint('LOGO ${file.path}');
}
