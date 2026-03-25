// test/ble_logger_test.dart — Unit tests for BleLogger.
// No .so required.

import 'dart:async';
import 'package:test/test.dart';
import 'package:reactive_ble_linux/src/bluez/ble_logger.dart';

void main() {
  // Save and restore original state around each test
  late BleLogLevel savedLevel;
  late void Function(BleLogRecord) savedSink;

  setUp(() {
    savedLevel = BleLogger.minimumLevel;
    savedSink  = BleLogger.sink;
    // Silence the default print sink during tests
    BleLogger.sink = (_) {};
  });

  tearDown(() {
    BleLogger.minimumLevel = savedLevel;
    BleLogger.sink         = savedSink;
  });

  // ── Level filtering ──────────────────────────────────────────────────────
  group('level filtering', () {
    test('records below minimumLevel are dropped', () {
      BleLogger.minimumLevel = BleLogLevel.warning;
      final seen = <BleLogLevel>[];
      BleLogger.sink = (r) => seen.add(r.level);

      BleLogger.v('t', 'verbose');
      BleLogger.d('t', 'debug');
      BleLogger.i('t', 'info');
      BleLogger.w('t', 'warning');
      BleLogger.e('t', 'error');

      expect(seen, equals([BleLogLevel.warning, BleLogLevel.error]));
    });

    test('minimumLevel=none drops all records', () {
      BleLogger.minimumLevel = BleLogLevel.none;
      final seen = <BleLogRecord>[];
      BleLogger.sink = seen.add;

      BleLogger.e('t', 'should be dropped');
      expect(seen, isEmpty);
    });

    test('minimumLevel=verbose passes all records', () {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      final seen = <BleLogLevel>[];
      BleLogger.sink = (r) => seen.add(r.level);

      BleLogger.v('t', 'v');
      BleLogger.d('t', 'd');
      BleLogger.i('t', 'i');
      BleLogger.w('t', 'w');
      BleLogger.e('t', 'e');

      expect(seen.length, equals(5));
    });
  });

  // ── Record content ───────────────────────────────────────────────────────
  group('record content', () {
    test('tag and message are preserved', () {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      BleLogRecord? captured;
      BleLogger.sink = (r) => captured = r;

      BleLogger.i('gatt', 'connected device AA:BB');

      expect(captured?.tag,     equals('gatt'));
      expect(captured?.message, equals('connected device AA:BB'));
      expect(captured?.level,   equals(BleLogLevel.info));
    });

    test('error and stackTrace are preserved', () {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      BleLogRecord? captured;
      BleLogger.sink = (r) => captured = r;

      final err = Exception('test error');
      final st  = StackTrace.current;
      BleLogger.e('ring', 'ring full', error: err, stackTrace: st);

      expect(captured?.error,      equals(err));
      expect(captured?.stackTrace, equals(st));
    });

    test('timestamp is recent', () {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      BleLogRecord? captured;
      BleLogger.sink = (r) => captured = r;

      final before = DateTime.now();
      BleLogger.i('t', 'now');
      final after  = DateTime.now();

      expect(captured?.timestamp.isAfter(before.subtract(
              const Duration(milliseconds: 50))),
             isTrue);
      expect(captured?.timestamp.isBefore(after.add(
              const Duration(milliseconds: 50))),
             isTrue);
    });
  });

  // ── Broadcast stream ─────────────────────────────────────────────────────
  group('stream', () {
    test('records are delivered on stream', () async {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      final received = <BleLogRecord>[];
      final sub = BleLogger.stream.listen(received.add);

      BleLogger.i('stream-test', 'hello');
      BleLogger.w('stream-test', 'world');

      // Give the stream time to deliver
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received.where((r) => r.tag == 'stream-test').length,
             greaterThanOrEqualTo(2));
    });

    test('stream records include the correct message', () async {
      BleLogger.minimumLevel = BleLogLevel.verbose;
      final msgs = <String>[];
      final sub  = BleLogger.stream
          .where((r) => r.tag == 'msg-test')
          .map((r) => r.message)
          .listen(msgs.add);

      BleLogger.d('msg-test', 'alpha');
      BleLogger.d('msg-test', 'beta');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(msgs, containsAll(['alpha', 'beta']));
    });
  });

  // ── toString ─────────────────────────────────────────────────────────────
  group('BleLogRecord.toString', () {
    test('contains level, tag, and message', () {
      final r = BleLogRecord(
        level:     BleLogLevel.warning,
        tag:       'scan',
        message:   'no adapter found',
        timestamp: DateTime(2025, 1, 1),
      );
      final s = r.toString();
      expect(s, contains('WARNING'));
      expect(s, contains('scan'));
      expect(s, contains('no adapter found'));
    });

    test('includes error when present', () {
      final r = BleLogRecord(
        level:     BleLogLevel.error,
        tag:       'conn',
        message:   'failed',
        timestamp: DateTime.now(),
        error:     Exception('boom'),
      );
      expect(r.toString(), contains('boom'));
    });
  });

  // ── BleLogLevel comparison ────────────────────────────────────────────────
  group('BleLogLevel ordering', () {
    test('verbose < debug < info < warning < error < none', () {
      expect(BleLogLevel.verbose >= BleLogLevel.verbose, isTrue);
      expect(BleLogLevel.debug   >= BleLogLevel.verbose, isTrue);
      expect(BleLogLevel.info    >= BleLogLevel.debug,   isTrue);
      expect(BleLogLevel.warning >= BleLogLevel.info,    isTrue);
      expect(BleLogLevel.error   >= BleLogLevel.warning, isTrue);
      expect(BleLogLevel.none    >= BleLogLevel.error,   isTrue);

      expect(BleLogLevel.verbose >= BleLogLevel.info, isFalse);
      expect(BleLogLevel.debug   >= BleLogLevel.error, isFalse);
    });
  });
}
