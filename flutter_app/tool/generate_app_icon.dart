// Writes the app icons from the vector logo in lib/src/ui/app_logo.dart. Run from flutter_app/:
//
//   flutter test tool/generate_app_icon.dart
//
// Every size is drawn from the vector mark, not scaled from one bitmap, so the small ones stay
// sharp.
//
// * Windows: windows/runner/resources/app_icon.ico, which Runner.rc embeds as IDI_APP_ICON.
//   Besides 16–256 px it holds 20, 24 and 40 px, which Windows picks at 125 % and 150 % display
//   scaling. 256 px is stored as PNG and the rest as 32-bit BMPs with an AND mask, the classic
//   layout every Windows tool reads.
// * Android: the adaptive icon's layers, mipmap-*/ic_launcher_{background,foreground}.png
//   (108 dp; mipmap-anydpi-v26/ic_launcher.xml stacks them, Android 8+), and the plain
//   mipmap-*/ic_launcher.png (48 dp) for older versions.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_app/src/ui/app_logo.dart';
import 'package:flutter_test/flutter_test.dart';

const _sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const _out = 'windows/runner/resources/app_icon.ico';

/// Pixels per dp of each Android density bucket.
const _densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
const _res = 'android/app/src/main/res';

void main() {
  test('writes the Android launcher icons', () async {
    for (final MapEntry(key: bucket, value: scale) in _densities.entries) {
      final dir = '$_res/mipmap-$bucket';
      await _writePng('$dir/ic_launcher.png', (48 * scale).round(), AppLogoLayer.full);
      await _writePng('$dir/ic_launcher_background.png', (108 * scale).round(), AppLogoLayer.adaptiveBackground);
      await _writePng('$dir/ic_launcher_foreground.png', (108 * scale).round(), AppLogoLayer.adaptiveForeground);
    }
    expect(File('$_res/mipmap-anydpi-v26/ic_launcher.xml').existsSync(), isTrue, reason: 'stacks the adaptive layers');
  });

  test('writes $_out', () async {
    final images = <(int, Uint8List)>[];
    for (final size in _sizes) {
      final image = await renderAppLogo(size);
      final data = size >= 256
          ? await image.toByteData(format: ui.ImageByteFormat.png)
          : await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      final bytes = data!.buffer.asUint8List();
      images.add((size, size >= 256 ? bytes : _bmp(bytes, size)));
    }
    final ico = _ico(images);
    File(_out).writeAsBytesSync(ico, flush: true);
    // ignore: avoid_print
    print('Wrote $_out: ${_sizes.join(', ')} px, ${ico.length} bytes');
  });
}

Future<void> _writePng(String path, int size, AppLogoLayer layer) async {
  final image = await renderAppLogo(size, layer: layer);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(png!.buffer.asUint8List(), flush: true);
  // ignore: avoid_print
  print('Wrote $path ($size px)');
}

/// An ICONDIR header, one 16-byte entry per image, then the images themselves.
Uint8List _ico(List<(int, Uint8List)> images) {
  const le = Endian.little;
  final header = ByteData(6 + 16 * images.length)
    ..setUint16(2, 1, le) // type: icon
    ..setUint16(4, images.length, le);
  var offset = header.lengthInBytes;
  for (final (i, (size, bytes)) in images.indexed) {
    final e = 6 + 16 * i;
    header
      ..setUint8(e, size & 0xFF) // width; 0 means 256
      ..setUint8(e + 1, size & 0xFF) // height
      ..setUint16(e + 4, 1, le) // colour planes
      ..setUint16(e + 6, 32, le) // bits per pixel
      ..setUint32(e + 8, bytes.length, le)
      ..setUint32(e + 12, offset, le);
    offset += bytes.length;
  }
  final out = BytesBuilder(copy: false)..add(header.buffer.asUint8List());
  for (final (_, bytes) in images) {
    out.add(bytes);
  }
  return out.takeBytes();
}

/// A 32-bit icon bitmap: a BITMAPINFOHEADER whose height counts the colour rows and the mask
/// rows, BGRA rows bottom-up, then the 1-bit AND mask (set where the pixel is fully transparent).
Uint8List _bmp(Uint8List rgba, int size) {
  const le = Endian.little;
  final maskStride = (size + 31) ~/ 32 * 4;
  final pixelBytes = size * size * 4;
  final b = ByteData(40 + pixelBytes + maskStride * size)
    ..setUint32(0, 40, le) // biSize
    ..setInt32(4, size, le)
    ..setInt32(8, size * 2, le)
    ..setUint16(12, 1, le) // planes
    ..setUint16(14, 32, le) // bit count; compression 0 = BI_RGB
    ..setUint32(20, pixelBytes + maskStride * size, le);
  var o = 40;
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      b
        ..setUint8(o++, rgba[i + 2])
        ..setUint8(o++, rgba[i + 1])
        ..setUint8(o++, rgba[i])
        ..setUint8(o++, rgba[i + 3]);
    }
  }
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      if (rgba[(y * size + x) * 4 + 3] == 0) {
        final m = o + (x >> 3);
        b.setUint8(m, b.getUint8(m) | 0x80 >> (x & 7));
      }
    }
    o += maskStride;
  }
  return b.buffer.asUint8List();
}
