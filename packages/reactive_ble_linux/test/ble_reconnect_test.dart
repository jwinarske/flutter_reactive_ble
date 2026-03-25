// test/ble_reconnect_test.dart — Unit tests for BleReconnectManager.
//
// Uses _FakeBle (implements BleConnectionSource) to inject synthetic
// connection events — no .so, no hardware required.

import 'dart:async';
import 'package:test/test.dart';

import 'package:reactive_ble_linux/src/bluez/ble_reconnect.dart';
import 'package:reactive_ble_linux/src/bluez/ble_types.dart';

// ── Fake BLE source ────────────────────────────────────────────────────────

final class _FakeBle implements BleConnectionSource {
  final _ctrl = StreamController<BleConnectionEvent>.broadcast();

  int connectCalls    = 0;
  int disconnectCalls = 0;

  @override
  Stream<BleConnectionEvent> get connectionEvents => _ctrl.stream;

  @override
  void connectToDevice(String address) => connectCalls++;

  @override
  void disconnectDevice(String address) {
    disconnectCalls++;
    inject(address, BleConnectionState.disconnected, 0);
  }

  void inject(String address, BleConnectionState state, int err) {
    if (!_ctrl.isClosed) {
      _ctrl.add(BleConnectionEvent(
          address: address, state: state, errorCode: err));
    }
  }

  Future<void> close() => _ctrl.close();
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  const addr = 'AA:BB:CC:DD:EE:FF';

  late _FakeBle     fake;
  late BleReconnectManager mgr;

  setUp(() {
    fake = _FakeBle();
    mgr  = BleReconnectManager(fake);
  });

  tearDown(() async => fake.close());

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Create a session with very short timeouts for fast tests.
  ReconnectSession quickSession({
    bool keepAlive   = false,
    int  maxAttempts = 0,
  }) =>
      mgr.connect(addr,
          keepAlive:      keepAlive,
          maxAttempts:    maxAttempts,
          initialBackoff: const Duration(milliseconds: 10),
          maxBackoff:     const Duration(milliseconds: 40),
          connectTimeout: const Duration(milliseconds: 150));

  // ── Single-shot (keepAlive=false) ─────────────────────────────────────────
  group('single-shot connect', () {
    test('connectToDevice is called once', () async {
      final session = quickSession();
      fake.inject(addr, BleConnectionState.connected, 0);
      await session.waitConnected(timeout: const Duration(seconds: 2));
      await session.dispose();
      expect(fake.connectCalls, equals(1));
    });

    test('waitConnected resolves after connected event', () async {
      final session = quickSession();
      Future.delayed(const Duration(milliseconds: 20),
          () => fake.inject(addr, BleConnectionState.connected, 0));
      await expectLater(
          session.waitConnected(timeout: const Duration(seconds: 2)),
          completes);
      await session.dispose();
    });

    test('deviceAddress is forwarded correctly', () {
      final session = quickSession();
      expect(session.deviceAddress, equals(addr));
      session.dispose();
    });

    test('connection events are forwarded to the session stream', () async {
      final states = <BleConnectionState>[];
      final session = quickSession();
      final sub = session.connectionEvents.map((e) => e.state).listen(states.add);

      fake.inject(addr, BleConnectionState.connecting, 0);
      fake.inject(addr, BleConnectionState.connected,  0);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await sub.cancel();
      await session.dispose();

      expect(states, containsAll([
        BleConnectionState.connecting,
        BleConnectionState.connected,
      ]));
    });

    test('events for other devices are not forwarded', () async {
      const other  = '11:22:33:44:55:66';
      final states = <BleConnectionState>[];
      final session = quickSession();
      session.connectionEvents.map((e) => e.state).listen(states.add);

      fake.inject(other, BleConnectionState.connected, 0); // different device
      fake.inject(addr,  BleConnectionState.connected, 0); // our device
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await session.dispose();

      // Only the addr event should appear — not the 'other' one
      expect(states.where((s) => s == BleConnectionState.connected).length,
             equals(1));
    });

    test('waitConnected times out if no event arrives', () async {
      final session = quickSession();
      await expectLater(
          session.waitConnected(timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()));
      await session.dispose();
    });
  });

  // ── keepAlive reconnect ───────────────────────────────────────────────────
  group('keepAlive reconnect', () {
    test('reconnects after disconnect — connectCalls increases', () async {
      final session = quickSession(keepAlive: true);

      // First successful connection
      fake.inject(addr, BleConnectionState.connected, 0);
      await session.waitConnected(timeout: const Duration(seconds: 2));
      expect(fake.connectCalls, equals(1));

      // Simulate unexpected disconnect
      fake.inject(addr, BleConnectionState.disconnected, 0);
      // Allow backoff + reconnect attempt
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Second connection
      fake.inject(addr, BleConnectionState.connected, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fake.connectCalls, greaterThanOrEqualTo(2));
      await session.dispose();
    });

    test('backoff resets to initialBackoff after successful reconnect', () async {
      final session = quickSession(keepAlive: true);

      // Connect successfully — this resets attempts and backoff
      fake.inject(addr, BleConnectionState.connected, 0);
      await session.waitConnected(timeout: const Duration(seconds: 2));

      // Disconnect, wait, reconnect
      fake.inject(addr, BleConnectionState.disconnected, 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      fake.inject(addr, BleConnectionState.connected, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fake.connectCalls, greaterThanOrEqualTo(2));
      await session.dispose();
    });
  });

  // ── maxAttempts ───────────────────────────────────────────────────────────
  group('maxAttempts', () {
    test('errors stream closes after maxAttempts exhausted', () async {
      final errors  = <Object>[];
      final session = quickSession(keepAlive: false, maxAttempts: 2);

      final done = Completer<void>();
      session.connectionEvents.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );

      await done.future.timeout(const Duration(seconds: 3));

      expect(errors, isNotEmpty);
      expect(errors.first, isA<BleException>());
      expect((errors.first as BleException).message,
             contains('Max reconnect attempts'));
    });

    test('connectToDevice called at most maxAttempts times', () async {
      final errors  = <Object>[];
      final session = quickSession(keepAlive: false, maxAttempts: 3);

      final done = Completer<void>();
      session.connectionEvents.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );

      await done.future.timeout(const Duration(seconds: 3));
      expect(fake.connectCalls, lessThanOrEqualTo(3));
    });
  });

  // ── dispose ───────────────────────────────────────────────────────────────
  group('dispose', () {
    test('disconnectDevice called on dispose', () async {
      final session = quickSession();
      fake.inject(addr, BleConnectionState.connected, 0);
      await session.waitConnected(timeout: const Duration(seconds: 2));
      await session.dispose();
      expect(fake.disconnectCalls, greaterThan(0));
    });

    test('no further connectToDevice calls after dispose', () async {
      final session = quickSession(keepAlive: true);
      fake.inject(addr, BleConnectionState.connected, 0);
      await session.waitConnected(timeout: const Duration(seconds: 2));

      final countAtDispose = fake.connectCalls;
      await session.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fake.connectCalls, equals(countAtDispose));
    });

    test('waitConnected throws after session disposed', () async {
      final session = quickSession();
      await session.dispose();
      // Stream is closed, so waitConnected completer should error
      await expectLater(
          session.waitConnected(timeout: const Duration(milliseconds: 100)),
          throwsA(anything));
    });
  });

  // ── address normalisation ─────────────────────────────────────────────────
  group('address normalisation', () {
    test('lowercase address matches uppercase injected event', () async {
      const lower = 'aa:bb:cc:dd:ee:ff';
      final session = mgr.connect(lower,
          keepAlive: false,
          initialBackoff: const Duration(milliseconds: 10),
          connectTimeout: const Duration(milliseconds: 200));

      fake.inject('AA:BB:CC:DD:EE:FF', BleConnectionState.connected, 0);
      await expectLater(
          session.waitConnected(timeout: const Duration(seconds: 2)),
          completes);
      await session.dispose();
    });
  });
}
