import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../rust/document.dart';
import '../rust/geometry/point.dart';
import '../rust/geometry/sticky_note.dart';
import '../rust/geometry/stroke.dart';
import 'stroke_renderer.dart';

extension ViewportRectX on ViewportRect {
  Rect toRect() => Rect.fromLTRB(left, top, right, bottom);
}

extension StickyNoteX on StickyNote {
  Rect get rect => Rect.fromLTWH(x, y, width, height);

  StickyNote copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    int? color,
    String? text,
    double? fontSize,
  }) => StickyNote(
    id: id,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    color: color ?? this.color,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
  );

  StickyNote withRect(Rect r) => copyWith(x: r.left, y: r.top, width: r.width, height: r.height);
}

/// A committed stroke plus its pre-built [ui.Path] (built once, reused every frame).
class CachedStroke {
  CachedStroke(this.render) : path = buildStrokePath(render), bounds = render.bounds.toRect();

  final StrokeRender render;
  final ui.Path path;
  final Rect bounds;

  String get id => render.id;
  bool get isHighlighter => render.tool == ToolType.highlighter;
}

/// Flutter-side mirror of the Rust document, kept in sync through [SceneDelta]s.
///
/// Dart's default `Map` preserves insertion order, which matches the engine's z-order:
/// new items are appended, updates of existing ids keep their position.
class SceneCache extends ChangeNotifier {
  final Map<String, CachedStroke> _strokes = {};
  final Map<String, StickyNote> _notes = {};
  final Map<String, _NoteText> _noteText = {};

  Iterable<CachedStroke> get strokes => _strokes.values;
  Iterable<StickyNote> get notes => _notes.values;
  int get strokeCount => _strokes.length;
  int get noteCount => _notes.length;
  bool get isEmpty => _strokes.isEmpty && _notes.isEmpty;

  CachedStroke? stroke(String id) => _strokes[id];

  /// Union of every item's bounds (`null` when empty).
  Rect? get contentBounds {
    Rect? r;
    for (final s in _strokes.values) {
      r = r == null ? s.bounds : r.expandToInclude(s.bounds);
    }
    for (final n in _notes.values) {
      r = r == null ? n.rect : r.expandToInclude(n.rect);
    }
    return r;
  }
  StickyNote? note(String id) => _notes[id];

  /// Forces a repaint of the scene layer (e.g. paper style or pencil texture changed).
  void markDirty() => notifyListeners();

  void load(SceneSnapshot snapshot) {
    _strokes.clear();
    _notes.clear();
    _noteText.clear();
    for (final r in snapshot.strokes) {
      _strokes[r.id] = CachedStroke(r);
    }
    for (final n in snapshot.notes) {
      _notes[n.id] = n;
    }
    notifyListeners();
  }

  void addStroke(StrokeRender r) {
    _strokes[r.id] = CachedStroke(r);
    notifyListeners();
  }

  void upsertNote(StickyNote n) {
    _notes[n.id] = n;
    notifyListeners();
  }

  void removeIds(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      changed |= _strokes.remove(id) != null;
      changed |= _notes.remove(id) != null;
      _noteText.remove(id);
    }
    if (changed) notifyListeners();
  }

  void applyDelta(SceneDelta delta) {
    for (final id in delta.removedIds) {
      _strokes.remove(id);
      _notes.remove(id);
      _noteText.remove(id);
    }
    for (final r in delta.upsertedStrokes) {
      _strokes[r.id] = CachedStroke(r);
    }
    for (final n in delta.upsertedNotes) {
      _notes[n.id] = n;
    }
    notifyListeners();
  }

  /// Laid-out text for a note, cached until its text, font size or width changes.
  TextPainter noteTextPainter(StickyNote note, {double? width}) {
    final w = ((width ?? note.width) - 2 * kNotePadding).clamp(8.0, double.infinity);
    final cached = _noteText[note.id];
    if (cached != null && cached.text == note.text && cached.fontSize == note.fontSize && cached.width == w) {
      return cached.painter;
    }
    cached?.painter.dispose();
    final painter = TextPainter(
      text: TextSpan(text: note.text, style: noteTextStyle(note.fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    _noteText[note.id] = _NoteText(note.text, note.fontSize, w, painter);
    return painter;
  }

  @override
  void dispose() {
    for (final t in _noteText.values) {
      t.painter.dispose();
    }
    super.dispose();
  }
}

class _NoteText {
  _NoteText(this.text, this.fontSize, this.width, this.painter);
  final String text;
  final double fontSize;
  final double width;
  final TextPainter painter;
}
