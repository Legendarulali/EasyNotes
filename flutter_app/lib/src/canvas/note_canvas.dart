import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/editor_controller.dart';
import '../editor/tools.dart';
import '../rust/geometry/sticky_note.dart';
import '../ui/selection_actions.dart';
import 'painters.dart';
import 'scene_cache.dart';

enum _Mode { idle, drawing, erasing, lasso, box, transform, noteMove, noteResize, noteCreate, navigate }

/// The page canvas. All input arrives through one raw [Listener] so we fully control
/// the routing between devices:
///
/// * **Stylus / mouse** – draw, erase, select, place notes (inverted stylus = eraser).
/// * **Touch** – one finger pans, two fingers pinch-zoom; touching the selection box or
///   its handles moves / resizes it. Fingers only draw while "stylus only" is off, and are
///   ignored entirely while a pen stroke is in progress (palm rejection).
/// * **Mouse wheel / trackpad** – scroll and Ctrl+wheel / pinch to zoom.
class NoteCanvas extends StatefulWidget {
  const NoteCanvas({super.key, required this.controller, required this.onEditNote, required this.onMessage});

  final EditorController controller;

  /// Opens the note editor; `isNew` notes are deleted if the user cancels with no text.
  final Future<void> Function(StickyNote note, {bool isNew}) onEditNote;
  final void Function(String message) onMessage;

  @override
  State<NoteCanvas> createState() => _NoteCanvasState();
}

class _NoteCanvasState extends State<NoteCanvas> {
  static const double _tapSlop = 6;
  static const double _noteResizeGrip = 28;

  EditorController get c => widget.controller;

  _Mode _mode = _Mode.idle;
  int? _pointer;
  PointerDeviceKind? _pointerKind;
  EditorTool _gestureTool = EditorTool.pen;
  Offset _downScreen = Offset.zero;
  Offset _downWorld = Offset.zero;
  bool _moved = false;

  // Selection transform.
  SelectionHandle? _handle;
  Rect? _startBounds;

  // Sticky note drag.
  StickyNote? _note;

  // Eraser: previous sample, so each move erases the swept segment.
  Offset? _lastEraser;

  // Navigation (touch pan / pinch, mouse right/middle drag).
  final Map<int, Offset> _navPointers = {};
  Offset? _navTapStart;
  bool _navMoved = false;

  // Trackpad pinch.
  double _lastTrackpadScale = 1;

  // ------------------------------------------------------------------ helpers

  Offset _world(Offset screen) => c.viewport.screenToWorld(screen);

  static bool _isStylus(PointerDeviceKind k) => k == PointerDeviceKind.stylus || k == PointerDeviceKind.invertedStylus;

  /// Normalised pressure; devices without pressure report the neutral 0.5.
  static double _pressure(PointerEvent e) {
    if (!_isStylus(e.kind)) return 0.5;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
  }

  bool get _penBusy =>
      _mode != _Mode.idle && _mode != _Mode.navigate && _pointerKind != null && _pointerKind != PointerDeviceKind.touch;

  // ------------------------------------------------------------------ pointer down

  void _onDown(PointerDownEvent e) {
    final kind = e.kind;
    if (_isStylus(kind) && c.registerStylus()) {
      widget.onMessage('Stylus detected — the pen draws, fingers pan & zoom.');
    }

    // Mouse right / middle button: pan.
    if (kind == PointerDeviceKind.mouse && (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
      _startNavigation(e);
      return;
    }

    if (kind == PointerDeviceKind.touch) {
      if (_penBusy) return; // palm rejection
      if (_mode != _Mode.idle && _mode != _Mode.navigate && _pointerKind == PointerDeviceKind.touch) {
        // A second finger while finger-drawing / selecting → abort it and navigate.
        final first = _pointer!;
        final lastPos = c.viewport.worldToScreen(_lastWorld ?? _downWorld);
        _abortGesture();
        _navPointers[first] = lastPos;
        _mode = _Mode.navigate;
        _navMoved = true;
      }
      if (_mode == _Mode.idle) {
        if (_tryBeginTransform(e)) return;
        if (c.tool == EditorTool.stickyNote && _tryBeginNote(e)) return;
        if (!c.stylusOnly) {
          _beginToolGesture(e, c.tool);
          return;
        }
      }
      _startNavigation(e);
      return;
    }

    // Stylus or mouse primary button.
    if (_mode == _Mode.navigate) {
      _navPointers.clear();
      _mode = _Mode.idle;
    }
    if (_mode != _Mode.idle) return;
    if (kind == PointerDeviceKind.invertedStylus) {
      _beginToolGesture(e, EditorTool.eraser);
      return;
    }
    if (_tryBeginTransform(e)) return;
    if (c.tool == EditorTool.stickyNote && _tryBeginNote(e)) return;
    _beginToolGesture(e, c.tool);
  }

  Offset? _lastWorld;

  void _track(PointerEvent e) {
    _pointer = e.pointer;
    _pointerKind = e.kind;
    _downScreen = e.localPosition;
    _downWorld = _world(e.localPosition);
    _lastWorld = _downWorld;
    _moved = false;
  }

  void _beginToolGesture(PointerDownEvent e, EditorTool tool) {
    _track(e);
    _gestureTool = tool;
    final world = _downWorld;
    switch (tool) {
      case EditorTool.pen:
      case EditorTool.pencil:
      case EditorTool.highlighter:
        if (c.hasSelection) c.clearSelection();
        c.beginStroke(tool, world, _pressure(e));
        _mode = _Mode.drawing;
      case EditorTool.eraser:
        _mode = _Mode.erasing;
        _lastEraser = world;
        c.eraseAlong(world, world);
      case EditorTool.lasso:
        _mode = _Mode.lasso;
        c.live.clear();
        c.live.addLassoPoint(world);
      case EditorTool.boxSelect:
        _mode = _Mode.box;
        c.live.setBox(Rect.fromPoints(world, world));
      case EditorTool.stickyNote:
        _mode = _Mode.noteCreate;
    }
  }

  bool _tryBeginTransform(PointerDownEvent e) {
    if (!c.hasSelection) return false;
    final slop = e.kind == PointerDeviceKind.touch ? 24.0 : 14.0;
    final handle = SelectionOverlayPainter.hitTestSelection(c, e.localPosition, slop: slop);
    if (handle == null) return false;
    _track(e);
    _handle = handle;
    _startBounds = c.selectionBounds;
    _mode = _Mode.transform;
    return true;
  }

  bool _tryBeginNote(PointerDownEvent e) {
    final world = _world(e.localPosition);
    final note = c.noteAt(world);
    if (note == null) return false;
    _track(e);
    _note = note;
    final bottomRight = c.viewport.worldToScreen(note.rect.bottomRight);
    _mode = (bottomRight - e.localPosition).distance <= _noteResizeGrip ? _Mode.noteResize : _Mode.noteMove;
    return true;
  }

  void _startNavigation(PointerDownEvent e) {
    _navPointers[e.pointer] = e.localPosition;
    if (_mode != _Mode.navigate) {
      _mode = _Mode.navigate;
      _navTapStart = e.localPosition;
      _navMoved = false;
    } else {
      _navMoved = true; // multi-finger gestures are never taps
    }
  }

  // ------------------------------------------------------------------ pointer move

  void _onMove(PointerMoveEvent e) {
    if (_navPointers.containsKey(e.pointer)) {
      _updateNavigation(e);
      return;
    }
    if (e.pointer != _pointer) return;
    final world = _world(e.localPosition);
    _lastWorld = world;
    if (!_moved && (e.localPosition - _downScreen).distance > _tapSlop) _moved = true;

    switch (_mode) {
      case _Mode.drawing:
        c.addPoint(world, _pressure(e));
      case _Mode.erasing:
        c.eraseAlong(_lastEraser ?? world, world);
        _lastEraser = world;
      case _Mode.lasso:
        c.live.addLassoPoint(world);
      case _Mode.box:
        c.live.setBox(Rect.fromPoints(_downWorld, world));
      case _Mode.transform:
        _updateTransformPreview(world);
      case _Mode.noteMove:
      case _Mode.noteResize:
        _updateNotePreview(world);
      case _Mode.noteCreate:
      case _Mode.navigate:
      case _Mode.idle:
        break;
    }
  }

  void _updateNavigation(PointerMoveEvent e) {
    final before = Map<int, Offset>.of(_navPointers);
    _navPointers[e.pointer] = e.localPosition;
    if (_navTapStart != null && (e.localPosition - _navTapStart!).distance > _tapSlop) _navMoved = true;

    final oldFocal = _centroid(before.values);
    final newFocal = _centroid(_navPointers.values);
    var scale = 1.0;
    if (_navPointers.length >= 2) {
      final oldSpread = _spread(before.values, oldFocal);
      final newSpread = _spread(_navPointers.values, newFocal);
      if (oldSpread > 1) scale = newSpread / oldSpread;
    }
    c.viewport.pinch(focalScreen: newFocal, scaleFactor: scale, focalDelta: newFocal - oldFocal);
  }

  static Offset _centroid(Iterable<Offset> pts) {
    var sum = Offset.zero;
    for (final p in pts) {
      sum += p;
    }
    return pts.isEmpty ? Offset.zero : sum / pts.length.toDouble();
  }

  static double _spread(Iterable<Offset> pts, Offset c) {
    if (pts.isEmpty) return 0;
    return pts.map((p) => (p - c).distance).reduce((a, b) => a + b) / pts.length;
  }

  void _updateTransformPreview(Offset world) {
    final b = _startBounds;
    if (b == null) return;
    final d = world - _downWorld;
    Rect target;
    if (_handle == SelectionHandle.move) {
      target = b.shift(Offset(math.max(d.dx, -b.left), math.max(d.dy, -b.top)));
    } else {
      const minSize = 8.0;
      final left = _handle == SelectionHandle.topLeft || _handle == SelectionHandle.bottomLeft;
      final top = _handle == SelectionHandle.topLeft || _handle == SelectionHandle.topRight;
      var l = b.left, t = b.top, r = b.right, btm = b.bottom;
      if (left) {
        l = math.max(0, math.min(b.left + d.dx, b.right - minSize));
      } else {
        r = math.max(b.right + d.dx, b.left + minSize);
      }
      if (top) {
        t = math.max(0, math.min(b.top + d.dy, b.bottom - minSize));
      } else {
        btm = math.max(b.bottom + d.dy, b.top + minSize);
      }
      if (HardwareKeyboard.instance.isShiftPressed && b.width > 0 && b.height > 0) {
        // Aspect-ratio lock around the opposite (anchored) corner.
        final s = math.max((r - l) / b.width, (btm - t) / b.height);
        if (left) {
          l = math.max(0, b.right - b.width * s);
        } else {
          r = b.left + b.width * s;
        }
        if (top) {
          t = math.max(0, b.bottom - b.height * s);
        } else {
          btm = b.top + b.height * s;
        }
      }
      target = Rect.fromLTRB(l, t, r, btm);
    }
    c.selectionPreview.value = SelectionPreview(from: b, to: target);
  }

  void _updateNotePreview(Offset world) {
    final note = _note;
    if (note == null) return;
    final d = world - _downWorld;
    final r = note.rect;
    final rect = _mode == _Mode.noteMove
        ? r.shift(Offset(math.max(d.dx, -r.left), math.max(d.dy, -r.top)))
        : Rect.fromLTWH(r.left, r.top, math.max(48, r.width + d.dx), math.max(48, r.height + d.dy));
    c.notePreview.value = NotePreview(note.id, rect);
  }

  // ------------------------------------------------------------------ pointer up / cancel

  void _onUp(PointerUpEvent e) {
    if (_navPointers.containsKey(e.pointer)) {
      _endNavigationPointer(e.pointer);
      return;
    }
    if (e.pointer != _pointer) return;
    final world = _world(e.localPosition);
    final tolerance = (e.kind == PointerDeviceKind.touch ? 16 : 8) / c.viewport.scale;

    switch (_mode) {
      case _Mode.drawing:
        c.finishStroke(_gestureTool);
      case _Mode.erasing:
        if (e.kind != PointerDeviceKind.mouse) c.live.setEraser(null, c.eraserRadius);
      case _Mode.lasso:
        if (_moved && c.live.lasso.length > 2) {
          c.selectLasso(List.of(c.live.lasso));
        } else {
          c.selectAt(_downWorld, tolerance);
        }
        c.live.clear();
      case _Mode.box:
        final box = c.live.box;
        if (_moved && box != null) {
          c.selectBox(box);
        } else {
          c.selectAt(_downWorld, tolerance);
        }
        c.live.clear();
      case _Mode.transform:
        final p = c.selectionPreview.value;
        if (_moved && p != null) {
          c.commitTransform(p);
        } else {
          c.selectionPreview.value = null;
        }
      case _Mode.noteMove:
      case _Mode.noteResize:
        final note = _note;
        final p = c.notePreview.value;
        c.notePreview.value = null;
        if (note != null) {
          if (_moved && p != null) {
            c.updateNote(note.withRect(p.rect));
          } else {
            widget.onEditNote(note);
          }
        }
      case _Mode.noteCreate:
        if (!_moved) {
          final note = c.createNote(Offset(math.max(0, world.dx - 20), math.max(0, world.dy - 20)));
          widget.onEditNote(note, isNew: true);
        }
      case _Mode.navigate:
      case _Mode.idle:
        break;
    }
    _resetGesture();
  }

  void _endNavigationPointer(int pointer) {
    _navPointers.remove(pointer);
    if (_navPointers.isNotEmpty) return;
    final tap = _navTapStart;
    if (!_navMoved && tap != null) {
      if (c.tool == EditorTool.stickyNote) {
        // Fingers can place notes even in stylus-only mode.
        final w = _world(tap);
        final note = c.createNote(Offset(math.max(0, w.dx - 20), math.max(0, w.dy - 20)));
        widget.onEditNote(note, isNew: true);
      } else if (c.hasSelection) {
        // A clean single-finger tap outside the selection deselects.
        c.clearSelection();
      }
    }
    _mode = _Mode.idle;
    _navTapStart = null;
  }

  void _onCancel(PointerCancelEvent e) {
    if (_navPointers.containsKey(e.pointer)) {
      _navPointers.remove(e.pointer);
      if (_navPointers.isEmpty) _mode = _Mode.idle;
      return;
    }
    if (e.pointer == _pointer) _abortGesture();
  }

  /// Cancels whatever the active pointer was doing without committing anything.
  void _abortGesture() {
    switch (_mode) {
      case _Mode.drawing:
        c.cancelStroke();
      case _Mode.lasso:
      case _Mode.box:
        c.live.clear();
      case _Mode.transform:
        c.selectionPreview.value = null;
      case _Mode.noteMove:
      case _Mode.noteResize:
        c.notePreview.value = null;
      default:
        break;
    }
    _resetGesture();
  }

  void _resetGesture() {
    _mode = _navPointers.isEmpty ? _Mode.idle : _Mode.navigate;
    _pointer = null;
    _pointerKind = null;
    _handle = null;
    _startBounds = null;
    _note = null;
    _lastWorld = null;
    _lastEraser = null;
  }

  // ------------------------------------------------------------------ hover / wheel / trackpad

  void _onHover(PointerHoverEvent e) {
    if (c.tool == EditorTool.eraser || e.kind == PointerDeviceKind.invertedStylus) {
      c.live.setEraser(_world(e.localPosition), c.eraserRadius);
    } else if (c.live.eraserCursor != null) {
      c.live.setEraser(null, c.eraserRadius);
    }
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        final factor = math.exp(-e.scrollDelta.dy / 400);
        c.viewport.zoomAt(e.localPosition, c.viewport.scale * factor);
      } else if (keys.isShiftPressed) {
        c.viewport.panBy(Offset(-e.scrollDelta.dy, -e.scrollDelta.dx));
      } else {
        c.viewport.panBy(-e.scrollDelta);
      }
    } else if (e is PointerScaleEvent) {
      c.viewport.zoomAt(e.localPosition, c.viewport.scale * e.scale);
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) => _lastTrackpadScale = 1;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    final factor = _lastTrackpadScale == 0 ? 1.0 : e.scale / _lastTrackpadScale;
    _lastTrackpadScale = e.scale;
    c.viewport.pinch(focalScreen: e.localPosition, scaleFactor: factor, focalDelta: e.localPanDelta);
  }

  // ------------------------------------------------------------------ build

  MouseCursor get _cursor {
    if (c.tool.isInk || c.tool == EditorTool.eraser) return SystemMouseCursors.precise;
    if (c.tool == EditorTool.stickyNote) return SystemMouseCursors.cell;
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        c.viewport.setViewportSize(constraints.biggest);
        c.devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        if (c.takeInitialFit()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) c.viewport.fitPageWidth();
          });
        }
        return ListenableBuilder(
        listenable: Listenable.merge([c, c.viewport, c.selectionPreview]),
        builder: (context, _) {
          final selRect = c.selectionPreview.value == null ? SelectionOverlayPainter.screenRect(c) : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              MouseRegion(
                cursor: _cursor,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onCancel,
                  onPointerHover: _onHover,
                  onPointerSignal: _onSignal,
                  onPointerPanZoomStart: _onPanZoomStart,
                  onPointerPanZoomUpdate: _onPanZoomUpdate,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(child: CustomPaint(painter: ScenePainter(c))),
                      RepaintBoundary(child: CustomPaint(painter: LivePainter(c))),
                      CustomPaint(painter: SelectionOverlayPainter(c)),
                    ],
                  ),
                ),
              ),
              if (selRect != null)
                SelectionActionBar.positioned(
                  controller: c,
                  selectionScreenRect: selRect,
                  canvasSize: constraints.biggest,
                  onEditNote: (note) => widget.onEditNote(note),
                ),
            ],
          );
        },
      );
      },
    );
  }
}
