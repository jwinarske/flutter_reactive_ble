// lib/src/ble_logger.dart — Structured, pluggable logger for dart_bluez_ble.
//
// Mirrors the LogLevel enum expected by flutter_reactive_ble's platform
// interface and adds a structured [BleLogRecord] type so callers can route
// entries to their own logging framework.

import 'dart:async';

/// Log severity levels — compatible with flutter_reactive_ble LogLevel.
enum BleLogLevel {
  verbose,
  debug,
  info,
  warning,
  error,
  none;

  bool operator >=(BleLogLevel other) => index >= other.index;
}

/// A single structured log entry.
final class BleLogRecord {
  const BleLogRecord({
    required this.level,
    required this.tag,
    required this.message,
    required this.timestamp,
    this.error,
    this.stackTrace,
  });

  final BleLogLevel  level;
  final String       tag;       // e.g. "scan", "gatt", "ring", "init"
  final String       message;
  final DateTime     timestamp;
  final Object?      error;
  final StackTrace?  stackTrace;

  @override
  String toString() {
    final ts  = timestamp.toIso8601String();
    final lvl = level.name.toUpperCase().padRight(7);
    final err = error != null ? '\n  error: $error' : '';
    final st  = stackTrace != null ? '\n$stackTrace' : '';
    return '$ts [$lvl] $tag: $message$err$st';
  }
}

/// Global logger for the dart_bluez_ble library.
///
/// By default all records go to `print`.  Replace [sink] with your own
/// handler to integrate with `package:logging`, `flutter_logger`, etc.:
///
/// ```dart
/// BleLogger.sink = (record) => Logger('BLE').log(record.level.name, record.message);
/// BleLogger.minimumLevel = BleLogLevel.debug;
/// ```
abstract final class BleLogger {
  BleLogger._();

  /// Minimum level to emit; records below this are dropped.
  static BleLogLevel minimumLevel = BleLogLevel.info;

  /// Synchronous sink.  Replace for custom routing.
  /// Default: print to stdout.
  static void Function(BleLogRecord) sink = _defaultSink;

  // Broadcast stream — subscribe to receive all records above [minimumLevel].
  static Stream<BleLogRecord> get stream => _ctrl.stream;
  static final _ctrl = StreamController<BleLogRecord>.broadcast();

  /// Emit a log record.
  static void log(
    BleLogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < minimumLevel.index) return;
    final record = BleLogRecord(
      level:      level,
      tag:        tag,
      message:    message,
      timestamp:  DateTime.now(),
      error:      error,
      stackTrace: stackTrace,
    );
    sink(record);
    if (!_ctrl.isClosed) _ctrl.add(record);
  }

  // Convenience methods
  static void v(String tag, String msg) =>
      log(BleLogLevel.verbose, tag, msg);
  static void d(String tag, String msg) =>
      log(BleLogLevel.debug,   tag, msg);
  static void i(String tag, String msg) =>
      log(BleLogLevel.info,    tag, msg);
  static void w(String tag, String msg, {Object? error}) =>
      log(BleLogLevel.warning, tag, msg, error: error);
  static void e(String tag, String msg,
                {Object? error, StackTrace? stackTrace}) =>
      log(BleLogLevel.error, tag, msg,
          error: error, stackTrace: stackTrace);

  static void _defaultSink(BleLogRecord r) {
    // ignore: avoid_print
    print(r.toString());
  }
}

/// Mixin that adds per-class logging helpers using a fixed [_logTag].
mixin BleLogging {
  String get _logTag;

  void logV(String msg) => BleLogger.v(_logTag, msg);
  void logD(String msg) => BleLogger.d(_logTag, msg);
  void logI(String msg) => BleLogger.i(_logTag, msg);
  void logW(String msg, {Object? error}) =>
      BleLogger.w(_logTag, msg, error: error);
  void logE(String msg, {Object? error, StackTrace? stackTrace}) =>
      BleLogger.e(_logTag, msg, error: error, stackTrace: stackTrace);
}
