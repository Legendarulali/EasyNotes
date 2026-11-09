import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// Rasterises imported PDF pages (PDFium via pdfrx) for the canvas background layer.
///
/// The Rust engine owns the page layout; this class only turns "PDF page *i* at about
/// *w* device pixels wide" into a [ui.Image]. Requests are quantised to a few widths so
/// zooming does not re-render every frame, rendered one at a time (nearest-first), and
/// the cache keeps a bounded number of pixels, evicting pages far from the viewport.
class PdfBackgrounds extends ChangeNotifier {
  PdfBackgrounds(this.path);

  final String path;

  static const List<int> _widths = [384, 768, 1152, 1536, 2304, 3072, 4096];
  static const int _pixelBudget = 48 * 1000 * 1000;

  pdfrx.PdfDocument? _doc;
  Object? _error;
  bool _disposed = false;
  bool _busy = false;
  final Map<int, _PageImage> _cache = {};
  final Map<int, int> _wanted = {};
  Set<int> _visible = const {};

  bool get isReady => _doc != null;
  Object? get error => _error;

  Future<void> open() async {
    try {
      await pdfrx.pdfrxFlutterInitialize();
      final doc = await pdfrx.PdfDocument.openFile(path);
      if (_disposed) {
        await doc.dispose();
        return;
      }
      _doc = doc;
      // Requests made while the file was still opening are queued: start on them now.
      scheduleMicrotask(_pump);
    } catch (e) {
      _error = e;
      debugPrint('PDF background could not be opened: $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// Best image currently available for [pdfPage] (possibly lower resolution).
  ui.Image? image(int pdfPage) => _cache[pdfPage]?.image;

  /// Called by the painter for each visible page: asks for a raster roughly
  /// [targetWidthPx] device pixels wide. Never notifies synchronously.
  void request(int pdfPage, double targetWidthPx) {
    final want = _quantise(targetWidthPx);
    final have = _cache[pdfPage];
    if (have != null && have.width >= want) return;
    if ((_wanted[pdfPage] ?? 0) < want) _wanted[pdfPage] = want;
    if (!_busy) scheduleMicrotask(_pump);
  }

  /// Pages currently on screen; used to prioritise rendering and to evict others.
  void setVisible(Set<int> pages) {
    if (setEquals(pages, _visible)) return;
    _visible = pages;
  }

  static int _quantise(double px) {
    final target = px.isFinite ? px : _widths.first.toDouble();
    return _widths.firstWhere((w) => w >= target, orElse: () => _widths.last);
  }

  Future<void> _pump() async {
    if (_busy || _disposed) return;
    final doc = _doc;
    if (doc == null || _wanted.isEmpty) return;
    _busy = true;
    try {
      while (_wanted.isNotEmpty && !_disposed) {
        // Visible pages first.
        final next = _wanted.keys.firstWhere(_visible.contains, orElse: () => _wanted.keys.first);
        final width = _wanted.remove(next)!;
        if (next < 0 || next >= doc.pages.length) continue;
        final page = doc.pages[next];
        final height = math.max(1, (width * page.height / page.width).round());
        ui.Image? img;
        try {
          img = await page.renderForDisplay(
            fullWidth: width.toDouble(),
            fullHeight: height.toDouble(),
            backgroundColor: 0xFFFFFFFF,
          );
        } catch (e) {
          debugPrint('PDF page $next failed to render: $e');
        }
        if (img == null) continue;
        if (_disposed) {
          img.dispose();
          break;
        }
        _cache.remove(next)?.image.dispose();
        _cache[next] = _PageImage(img, width);
        _evict();
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  void _evict() {
    var total = _cache.values.fold<int>(0, (sum, e) => sum + e.pixels);
    if (total <= _pixelBudget) return;
    final victims = _cache.keys.where((k) => !_visible.contains(k)).toList()
      ..sort((a, b) => _distance(b).compareTo(_distance(a)));
    for (final k in victims) {
      if (total <= _pixelBudget) break;
      final e = _cache.remove(k)!;
      total -= e.pixels;
      e.image.dispose();
    }
  }

  int _distance(int page) => _visible.isEmpty ? page : _visible.map((v) => (v - page).abs()).reduce(math.min);

  @override
  void dispose() {
    _disposed = true;
    for (final e in _cache.values) {
      e.image.dispose();
    }
    _cache.clear();
    _doc?.dispose();
    super.dispose();
  }
}

class _PageImage {
  _PageImage(this.image, this.width);
  final ui.Image image;
  final int width;
  int get pixels => image.width * image.height;
}
