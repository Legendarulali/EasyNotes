import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../src/rust/document/page.dart';
import '../src/rust/document/paper.dart';
import '../src/services/library_service.dart';
import 'editor_screen.dart';

/// Smokey grey of the home screen.
const Color kSmokeyBackground = Color(0xFF1E1E1E);
const Color _cardColor = Color(0xFF2A2A2C);
const Color _cardBorder = Color(0xFF353538);

/// Library dashboard: folders and notebooks of the current folder, a "New" menu
/// (Ruled / Grid notebook, Blank whiteboard, folder) and PDF import.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.library});

  final LibraryService library;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LibraryService get lib => widget.library;

  late Directory _folder = lib.root;
  List<LibraryEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final entries = await lib.list(_folder);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ navigation

  void _enter(Directory folder) {
    setState(() {
      _folder = folder;
      _loading = true;
    });
    _refresh();
  }

  void _up() {
    if (!lib.isRoot(_folder)) _enter(_folder.parent);
  }

  Future<void> _open(NotebookEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(builder: (_) => EditorScreen(entry: entry, library: lib)),
    );
    _thumbs.remove(entry.path);
    await _refresh();
  }

  // ------------------------------------------------------------------ creation

  Future<void> _onNew(_NewAction action) async {
    switch (action) {
      case _NewAction.ruled:
        await _createNotebook(NotebookTemplate.ruled);
      case _NewAction.grid:
        await _createNotebook(NotebookTemplate.grid);
      case _NewAction.whiteboard:
        await _createNotebook(NotebookTemplate.whiteboard);
      case _NewAction.folder:
        await _createFolder();
      case _NewAction.importPdf:
        await _importPdf();
    }
  }

  Future<void> _createNotebook(NotebookTemplate template) async {
    final name = await _askName(title: 'New ${template.label}', initial: lib.suggestName(_folder, template));
    if (name == null) return;
    NotebookEntry? entry;
    await _guard(() async => entry = await lib.createNotebook(_folder, name, template));
    if (entry != null && mounted) await _open(entry!);
  }

  Future<void> _createFolder() async {
    final name = await _askName(title: 'New folder', initial: lib.uniqueName(_folder, 'New folder'), action: 'Create');
    if (name == null) return;
    await _guard(() async {
      await lib.createFolder(_folder, name);
      await _refresh();
    });
  }

  Future<void> _importPdf() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        dialogTitle: 'Import a PDF to annotate',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
    } catch (e) {
      _toast('Could not open the file picker: $e');
      return;
    }
    if (file == null) return;
    final picked = file;
    NotebookEntry? entry;
    await _guard(() async {
      final bytes = await picked.readAsBytes();
      final name = picked.name.toLowerCase().endsWith('.pdf')
          ? picked.name.substring(0, picked.name.length - 4)
          : picked.name;
      entry = await lib.importPdf(_folder, name, bytes);
    });
    if (entry != null && mounted) await _open(entry!);
  }

  // ------------------------------------------------------------------ item actions

  Future<void> _onItemAction(LibraryEntry entry, _ItemAction action) async {
    switch (action) {
      case _ItemAction.open:
        if (entry is NotebookEntry) {
          await _open(entry);
        } else {
          _enter(entry.dir);
        }
      case _ItemAction.rename:
        final name = await _askName(title: 'Rename', initial: entry.name, action: 'Rename');
        if (name == null) return;
        await _guard(() async {
          await lib.rename(entry, name);
          _thumbs.remove(entry.path);
          await _refresh();
        });
      case _ItemAction.move:
        final target = await _pickFolder(entry);
        if (target == null) return;
        await _guard(() async {
          await lib.move(entry, target);
          _thumbs.remove(entry.path);
          await _refresh();
        });
      case _ItemAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${entry.name}"?'),
            content: Text(
              entry is FolderEntry
                  ? 'The folder and everything inside it will be deleted permanently.'
                  : 'The notebook will be deleted permanently.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await _guard(() async {
          await lib.delete(entry);
          await _refresh();
        });
    }
  }

  Future<String?> _askName({required String title, required String initial, String action = 'Create'}) {
    final ctrl = TextEditingController(text: initial)
      ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  Future<Directory?> _pickFolder(LibraryEntry moving) async {
    final folders = await lib.allFolders();
    if (!mounted) return null;
    final movingPath = moving.dir.absolute.path;
    return showDialog<Directory>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${moving.name}" to'),
        children: [
          for (final f in folders)
            if (!(moving is FolderEntry &&
                (f.absolute.path == movingPath || f.absolute.path.startsWith('$movingPath${Platform.pathSeparator}'))))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, f),
                child: Padding(
                  padding: EdgeInsets.only(left: 16.0 * lib.breadcrumbs(f).length),
                  child: Row(
                    children: [
                      Icon(lib.isRoot(f) ? Icons.home_outlined : Icons.folder_outlined, size: 20),
                      const SizedBox(width: 10),
                      Flexible(child: Text(lib.isRoot(f) ? 'Library' : lib.breadcrumbs(f).last)),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Future<Uint8List?> _thumbnail(NotebookEntry e) => _thumbs.putIfAbsent(e.path, () async {
    try {
      final f = e.thumbnailFile;
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  });

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final crumbs = lib.breadcrumbs(_folder);
    final compact = MediaQuery.sizeOf(context).width < 600;
    return PopScope(
      canPop: lib.isRoot(_folder),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        backgroundColor: kSmokeyBackground,
        appBar: AppBar(
          backgroundColor: kSmokeyBackground,
          surfaceTintColor: Colors.transparent,
          leading: crumbs.isEmpty
              ? const Padding(padding: EdgeInsets.all(14), child: Icon(Icons.edit_note, color: Colors.white70))
              : IconButton(tooltip: 'Up', icon: const Icon(Icons.arrow_back), onPressed: _up),
          titleSpacing: 0,
          title: _Breadcrumbs(
            crumbs: crumbs,
            onTap: (depth) {
              var d = _folder;
              for (var i = crumbs.length; i > depth; i--) {
                d = d.parent;
              }
              _enter(d);
            },
          ),
          actions: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Import PDF'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _NewMenuButton(onSelected: _onNew, enabled: !_busy),
            ),
          ],
          bottom: _busy
              ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
              : null,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
            ? _EmptyState(onNew: _onNew, inFolder: crumbs.isNotEmpty)
            : RefreshIndicator(
                onRefresh: _refresh,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 210,
                    mainAxisSpacing: 18,
                    crossAxisSpacing: 18,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: _entries.length,
                  itemBuilder: (context, i) {
                    final e = _entries[i];
                    return switch (e) {
                      FolderEntry() => _FolderCard(
                        entry: e,
                        onOpen: () => _enter(e.dir),
                        onAction: (a) => _onItemAction(e, a),
                      ),
                      NotebookEntry() => _NotebookCard(
                        entry: e,
                        thumbnail: _thumbnail(e),
                        onOpen: () => _open(e),
                        onAction: (a) => _onItemAction(e, a),
                      ),
                    };
                  },
                ),
              ),
        floatingActionButton: compact
            ? FloatingActionButton.extended(
                onPressed: _busy ? null : () => _showNewSheet(context),
                icon: const Icon(Icons.add),
                label: const Text('New'),
              )
            : null,
      ),
    );
  }

  Future<void> _showNewSheet(BuildContext context) async {
    final action = await showModalBottomSheet<_NewAction>(
      context: context,
      backgroundColor: const Color(0xFF262628),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in _NewAction.values)
              ListTile(
                leading: Icon(a.icon),
                title: Text(a.label),
                subtitle: Text(a.subtitle),
                onTap: () => Navigator.pop(context, a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action != null) await _onNew(action);
  }
}

// ---------------------------------------------------------------------------- menus

enum _NewAction {
  ruled('Ruled Notebook', 'Lined pages with a margin', Icons.format_align_justify),
  grid('Grid Notebook', '5 mm squared pages', Icons.grid_on),
  whiteboard('Blank Whiteboard', 'Unbounded canvas', Icons.dashboard_outlined),
  folder('New Folder', 'Organise your notebooks', Icons.create_new_folder_outlined),
  importPdf('Import PDF…', 'Write directly over a PDF', Icons.picture_as_pdf_outlined);

  const _NewAction(this.label, this.subtitle, this.icon);
  final String label;
  final String subtitle;
  final IconData icon;
}

enum _ItemAction {
  open('Open', Icons.open_in_new),
  rename('Rename', Icons.drive_file_rename_outline),
  move('Move to…', Icons.drive_file_move_outline),
  delete('Delete', Icons.delete_outline);

  const _ItemAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _NewMenuButton extends StatelessWidget {
  const _NewMenuButton({required this.onSelected, required this.enabled});

  final ValueChanged<_NewAction> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(backgroundColor: WidgetStatePropertyAll(Color(0xFF2C2C2E))),
      menuChildren: [
        for (final a in _NewAction.values) ...[
          if (a == _NewAction.folder) const Divider(height: 8),
          MenuItemButton(
            leadingIcon: Icon(a.icon, size: 20),
            onPressed: () => onSelected(a),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(a.label),
                  Text(a.subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          ),
        ],
      ],
      builder: (context, menu, _) => FilledButton.icon(
        onPressed: enabled ? () => menu.isOpen ? menu.close() : menu.open() : null,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.crumbs, required this.onTap});

  final List<String> crumbs;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600);
    if (crumbs.isEmpty) return Text('EasyNotes', style: style);
    final dim = style?.copyWith(color: Colors.white54, fontWeight: FontWeight.w400);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          InkWell(onTap: () => onTap(0), child: Text('Library', style: dim)),
          for (var i = 0; i < crumbs.length; i++) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.chevron_right, color: Colors.white38),
            ),
            i == crumbs.length - 1
                ? Text(crumbs[i], style: style)
                : InkWell(onTap: () => onTap(i + 1), child: Text(crumbs[i], style: dim)),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------- cards

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, required this.onOpen, required this.onAction});

  final Widget child;
  final VoidCallback onOpen;
  final ValueChanged<_ItemAction> onAction;

  Future<void> _menuAt(BuildContext context, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_ItemAction>(
      context: context,
      color: const Color(0xFF2C2C2E),
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final a in _ItemAction.values)
          PopupMenuItem(
            value: a,
            child: Row(children: [Icon(a.icon, size: 20), const SizedBox(width: 12), Text(a.label)]),
          ),
      ],
    );
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) _menuAt(context, box.localToGlobal(box.size.center(Offset.zero)));
        },
        onSecondaryTapDown: (d) => _menuAt(context, d.globalPosition),
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: 2,
              right: 2,
              child: PopupMenuButton<_ItemAction>(
                tooltip: 'Options',
                color: const Color(0xFF2C2C2E),
                icon: const Icon(Icons.more_vert, size: 20, color: Colors.white70),
                onSelected: onAction,
                itemBuilder: (_) => [
                  for (final a in _ItemAction.values)
                    PopupMenuItem(
                      value: a,
                      child: Row(children: [Icon(a.icon, size: 20), const SizedBox(width: 12), Text(a.label)]),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({required this.entry, required this.onOpen, required this.onAction});

  final FolderEntry entry;
  final VoidCallback onOpen;
  final ValueChanged<_ItemAction> onAction;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onOpen: onOpen,
      onAction: onAction,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Center(child: Icon(Icons.folder_rounded, size: 84, color: Color(0xFFE2B45C))),
            ),
            Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              entry.itemCount == 1 ? '1 item' : '${entry.itemCount} items',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotebookCard extends StatelessWidget {
  const _NotebookCard({required this.entry, required this.thumbnail, required this.onOpen, required this.onAction});

  final NotebookEntry entry;
  final Future<Uint8List?> thumbnail;
  final VoidCallback onOpen;
  final ValueChanged<_ItemAction> onAction;

  String get _kindLabel => switch (entry.meta.kind) {
    DocumentKind.whiteboard => 'Whiteboard',
    DocumentKind.pdfAnnotation => 'PDF',
    DocumentKind.notebook => switch (entry.meta.paper) {
      PaperStyle.dictando => 'Ruled',
      PaperStyle.matematica => 'Grid',
      PaperStyle.whiteboard => 'Blank',
    },
  };

  @override
  Widget build(BuildContext context) {
    final pages = entry.meta.kind == DocumentKind.whiteboard
        ? ''
        : ' · ${entry.meta.pageCount} ${entry.meta.pageCount == 1 ? 'page' : 'pages'}';
    return _CardShell(
      onOpen: onOpen,
      onAction: onAction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 3))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: FutureBuilder<Uint8List?>(
                    future: thumbnail,
                    builder: (context, snap) {
                      final bytes = snap.data;
                      if (bytes != null) {
                        return Image.memory(bytes, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true);
                      }
                      return CustomPaint(painter: _PaperPreviewPainter(entry.meta.kind, entry.meta.paper));
                    },
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_kindLabel$pages · ${formatRelativeDate(entry.meta.modified)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder cover until the first thumbnail exists.
class _PaperPreviewPainter extends CustomPainter {
  _PaperPreviewPainter(this.kind, this.paper);

  final DocumentKind kind;
  final PaperStyle paper;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFDFDFB));
    final line = Paint()
      ..color = const Color(0xFFB5CBE3)
      ..strokeWidth = 0.8;
    if (kind == DocumentKind.pdfAnnotation) {
      final icon = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.picture_as_pdf_outlined.codePoint),
          style: TextStyle(fontSize: size.width * 0.38, fontFamily: Icons.picture_as_pdf_outlined.fontFamily, color: const Color(0xFFD9534F)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      icon.paint(canvas, size.center(Offset.zero) - Offset(icon.width / 2, icon.height / 2));
      icon.dispose();
      return;
    }
    if (kind == DocumentKind.whiteboard) {
      final dot = Paint()..color = const Color(0xFFCFD6DE);
      for (var y = 10.0; y < size.height; y += 14) {
        for (var x = 10.0; x < size.width; x += 14) {
          canvas.drawCircle(Offset(x, y), 0.9, dot);
        }
      }
      return;
    }
    switch (paper) {
      case PaperStyle.dictando:
        for (var y = size.height * 0.12; y < size.height; y += 9) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        canvas.drawLine(
          Offset(size.width * 0.12, 0),
          Offset(size.width * 0.12, size.height),
          Paint()
            ..color = const Color(0xFFE57373)
            ..strokeWidth = 0.9,
        );
      case PaperStyle.matematica:
        for (var y = 0.0; y < size.height; y += 7) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        for (var x = 0.0; x < size.width; x += 7) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
      case PaperStyle.whiteboard:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPreviewPainter old) => old.kind != kind || old.paper != paper;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onNew, required this.inFolder});

  final ValueChanged<_NewAction> onNew;
  final bool inFolder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(inFolder ? Icons.folder_open : Icons.auto_stories_outlined, size: 72, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              inFolder ? 'This folder is empty' : 'No notebooks yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 6),
            const Text('Create a notebook or import a PDF to write on.', style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                for (final a in _NewAction.values)
                  if (a != _NewAction.folder)
                    OutlinedButton.icon(onPressed: () => onNew(a), icon: Icon(a.icon), label: Text(a.label)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Today 14:05", "Yesterday", "Mon", or "12 Nov 2026".
String formatRelativeDate(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (diff == 0) return 'Today ${two(t.hour)}:${two(t.minute)}';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return weekdays[t.weekday - 1];
  return '${t.day} ${months[t.month - 1]} ${t.year}';
}
