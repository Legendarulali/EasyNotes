import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

/// Where the desktop Google session (account + refresh token) is kept between runs.
abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// A file in the app's support directory.
///
/// * **Windows:** the content is encrypted with DPAPI (`CryptProtectData`, current-user
///   scope plus app-specific entropy), so only the same Windows user can decrypt it.
/// * **Linux / macOS:** plain file readable by the owner only (`chmod 600`), like the
///   credential files of `gcloud` or `gh`.
class FileSessionStore implements SessionStore {
  FileSessionStore(this.file);

  final File file;

  static Future<FileSessionStore> standard() async {
    final dir = await getApplicationSupportDirectory();
    return FileSessionStore(File('${dir.path}${Platform.pathSeparator}google_session.bin'));
  }

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return utf8.decode(Platform.isWindows ? Dpapi.unprotect(bytes) : bytes);
  }

  @override
  Future<void> write(String value) async {
    final plain = Uint8List.fromList(utf8.encode(value));
    final bytes = Platform.isWindows ? Dpapi.protect(plain) : plain;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', tmp.path]);
    await tmp.rename(file.path);
  }

  @override
  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}

// ---------------------------------------------------------------------------- DPAPI

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _ProtectDart =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _UnprotectNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _UnprotectDart =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> mem);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> mem);

/// Windows Data Protection API (crypt32.dll), current-user scope.
abstract final class Dpapi {
  static const int _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN
  static final Uint8List _entropy = Uint8List.fromList(utf8.encode('EasyNotes/google-session/v1'));

  static final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _ProtectDart _protect = _crypt32.lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');
  static final _UnprotectDart _unprotect = _crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>(
    'CryptUnprotectData',
  );
  static final _LocalFreeDart _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  static Uint8List protect(Uint8List plain) => _run(plain, encrypt: true);

  /// Throws [StateError] if the data was not protected by this Windows user / app.
  static Uint8List unprotect(Uint8List cipher) => _run(cipher, encrypt: false);

  static Uint8List _run(Uint8List data, {required bool encrypt}) {
    return using((arena) {
      Pointer<_DataBlob> blob(Uint8List bytes) {
        final b = arena<_DataBlob>();
        final buf = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
        buf.asTypedList(bytes.length).setAll(0, bytes);
        b.ref
          ..cbData = bytes.length
          ..pbData = buf;
        return b;
      }

      final input = blob(data);
      final entropy = blob(_entropy);
      final output = arena<_DataBlob>();
      final ok = encrypt
          ? _protect(input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output)
          : _unprotect(input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) {
        throw StateError('${encrypt ? 'CryptProtectData' : 'CryptUnprotectData'} failed');
      }
      try {
        return Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    });
  }
}
