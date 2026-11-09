import 'package:flutter/material.dart';

import '../canvas/stroke_renderer.dart';
import '../editor/tools.dart';
import '../rust/geometry/sticky_note.dart';

/// What the user decided in the note editor.
sealed class NoteEditResult {
  const NoteEditResult();
}

class NoteSaved extends NoteEditResult {
  const NoteSaved(this.text, this.color);
  final String text;
  final Color color;
}

class NoteDeleted extends NoteEditResult {
  const NoteDeleted();
}

Future<NoteEditResult?> showStickyNoteEditor(BuildContext context, StickyNote note) {
  return showDialog<NoteEditResult>(
    context: context,
    builder: (_) => _StickyNoteDialog(note: note),
  );
}

class _StickyNoteDialog extends StatefulWidget {
  const _StickyNoteDialog({required this.note});
  final StickyNote note;

  @override
  State<_StickyNoteDialog> createState() => _StickyNoteDialogState();
}

class _StickyNoteDialogState extends State<_StickyNoteDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.note.text);
  late Color _color = Color(widget.note.color);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sticky note'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(color: _color, borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _text,
                autofocus: true,
                minLines: 4,
                maxLines: 10,
                style: noteTextStyle(widget.note.fontSize),
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Write something…'),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final c in kStickySwatches)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: c.toARGB32() == _color.toARGB32() ? 3 : 1,
                          color: c.toARGB32() == _color.toARGB32()
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, const NoteDeleted()),
          icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
          label: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, NoteSaved(_text.text, _color)), child: const Text('Save')),
      ],
    );
  }
}
