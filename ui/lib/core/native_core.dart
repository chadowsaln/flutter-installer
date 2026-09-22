import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// In-process bridge to the Rust core, loaded as a shared library via
/// `dart:ffi`. There is no daemon process ("server"): the core runs inside
/// this process and we drain its message queue with a small poll timer.
///
/// The C ABI mirrors the daemon's wire protocol (one JSON string per message:
/// a response tagged with `id`, or a notification such as progress/log).
class NativeCore {
  NativeCore._(this._handle) {
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _drain());
  }

  final Pointer<Void> _handle;
  Timer? _timer;

  /// One complete JSON line per callback, exactly like `CoreClient._onLine`.
  void Function(String line)? onMessage;

  // ------------------------------------------------------------------ ABI --

  static final _coreNewFn = _libCore!
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'ffi_core_new');
  static final _coreCallFn = _libCore!.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int64),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int)>(
          'ffi_core_call');
  static final _corePollFn = _libCore!.lookupFunction<
      Pointer<Utf8> Function(Pointer<Void>),
      Pointer<Utf8> Function(Pointer<Void>)>('ffi_core_poll');
  static final _coreFreeStringFn = _libCore!.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('ffi_core_free_string');
  static final _coreDestroyFn = _libCore!.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('ffi_core_destroy');

  static DynamicLibrary? _libCore;

  // ----------------------------------------------------------------- lookup --

  /// Finds the core library: `CORE_FFI` env override, dev build locations,
  /// then bundled beside the executable.
  static String? locate() {
    final env = Platform.environment['CORE_FFI'];
    if (env != null && File(env).existsSync()) return env;

    final libName = Platform.isWindows
        ? 'flutter_core.dll'
        : Platform.isMacOS
            ? 'libflutter_core.dylib'
            : 'libflutter_core.so';
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/../core/target/release/$libName',
      '$cwd/../core/target/debug/$libName',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    // Bundled next to the app executable (release packaging).
    final exe = Platform.resolvedExecutable;
    final sidecar =
        File('${File(exe).parent.path}${Platform.isWindows ? '\\' : '/'}$libName');
    if (sidecar.existsSync()) return sidecar.path;
    return null;
  }

  /// Loads the library and creates a core handle. Call [dispose] when done.
  static NativeCore open(String path) {
    final lib = DynamicLibrary.open(path);
    _libCore = lib;
    final handle = _coreNewFn();
    if (handle == nullptr) {
      throw StateError('ffi_core_new returned null');
    }
    return NativeCore._(handle);
  }

  // ------------------------------------------------------------------ ops --

  /// Schedules a request; the response arrives later via [onMessage].
  void send(int id, String method, Map<String, dynamic> params) {
    final m = method.toNativeUtf8();
    final p = jsonEncode(params).toNativeUtf8();
    _coreCallFn(_handle, m, p, id);
    malloc.free(m);
    malloc.free(p);
  }

  void _drain() {
    while (true) {
      final ptr = _corePollFn(_handle);
      if (ptr == nullptr) return;
      final line = ptr.toDartString();
      _coreFreeStringFn(ptr);
      onMessage?.call(line);
    }
  }

  void dispose() {
    _timer?.cancel();
    _coreDestroyFn(_handle);
    _libCore = null;
  }
}