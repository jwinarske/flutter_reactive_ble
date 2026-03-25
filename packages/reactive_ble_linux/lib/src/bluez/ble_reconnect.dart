// lib/src/ble_reconnect.dart — Automatic reconnection with exponential backoff.
//
// Uses [BleConnectionSource] — a minimal interface satisfied by [BluezBle]
// and by test fakes — to avoid circular imports.

import 'dart:async';
import 'ble_types.dart';

// ── Interface ─────────────────────────────────────────────────────────────

/// Minimal BLE connection surface required by [BleReconnectManager].
/// [BluezBle] satisfies this via its duck-typed API.
abstract interface class BleConnectionSource {
  Stream<BleConnectionEvent> get connectionEvents;
  void connectToDevice(String address);
  void disconnectDevice(String address);
}

// ── Session ───────────────────────────────────────────────────────────────

/// Managed reconnect session returned by [BleReconnectManager.connect].
final class ReconnectSession {
  ReconnectSession._internal({
    required this.deviceAddress,
    required Stream<BleConnectionEvent> connectionEvents,
    required Future<void> Function() dispose,
    required Future<void> Function({Duration timeout}) waitConnected,
  })  : connectionEvents = connectionEvents.asBroadcastStream(),
        _disposeImpl = dispose,
        _waitImpl = waitConnected;

  final String deviceAddress;
  final Stream<BleConnectionEvent> connectionEvents;

  final Future<void> Function() _disposeImpl;
  final Future<void> Function({Duration timeout}) _waitImpl;

  Future<void> waitConnected({Duration timeout = const Duration(seconds: 30)}) =>
      _waitImpl(timeout: timeout);

  Future<void> dispose() => _disposeImpl();
}

// ── Manager ───────────────────────────────────────────────────────────────

/// Reconnect manager. Accepts any [BleConnectionSource].
final class BleReconnectManager {
  BleReconnectManager(this._src);
  final BleConnectionSource _src;

  ReconnectSession connect(
    String deviceAddress, {
    bool     keepAlive      = true,
    int      maxAttempts    = 0,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff     = const Duration(seconds: 30),
    Duration connectTimeout = const Duration(seconds: 15),
  }) {
    final ctrl       = StreamController<BleConnectionEvent>.broadcast();
    var   disposed   = false;
    var   attempts   = 0;
    Duration backoff = initialBackoff;
    Completer<void>? latestConnected;

    Future<void> loop() async {
      while (!disposed) {
        if (maxAttempts > 0 && attempts >= maxAttempts) {
          if (!ctrl.isClosed) {
            ctrl.addError(BleException(
                'Max reconnect attempts ($maxAttempts) reached for $deviceAddress'));
            await ctrl.close();
          }
          return;
        }

        attempts++;
        final connectedC = Completer<void>();
        latestConnected  = connectedC;

        final sub = _src.connectionEvents
            .where((e) => e.address.toUpperCase() == deviceAddress.toUpperCase())
            .listen((e) {
          if (!ctrl.isClosed) ctrl.add(e);
          if (e.state == BleConnectionState.connected) {
            backoff  = initialBackoff;
            attempts = 0;
            if (!connectedC.isCompleted) connectedC.complete();
          }
        });

        _src.connectToDevice(deviceAddress);

        try {
          await connectedC.future.timeout(connectTimeout);
        } on TimeoutException {
          await sub.cancel();
          if (disposed) return;
          if (!ctrl.isClosed) {
            ctrl.add(BleConnectionEvent(
                address: deviceAddress,
                state: BleConnectionState.disconnected,
                errorCode: 1));
          }
          await _slicedDelay(backoff, () => disposed);
          backoff = _doubleCapped(backoff, maxBackoff);
          continue;
        }

        if (!keepAlive) { await sub.cancel(); return; }

        final dcC   = Completer<void>();
        final dcSub = _src.connectionEvents
            .where((e) =>
                e.address.toUpperCase() == deviceAddress.toUpperCase() &&
                e.state == BleConnectionState.disconnected)
            .listen((_) { if (!dcC.isCompleted) dcC.complete(); });

        await dcC.future;
        await dcSub.cancel();
        await sub.cancel();
        if (disposed) return;

        if (!ctrl.isClosed) {
          ctrl.add(BleConnectionEvent(
              address: deviceAddress,
              state: BleConnectionState.disconnected,
              errorCode: 0));
        }

        await _slicedDelay(backoff, () => disposed);
        backoff = _doubleCapped(backoff, maxBackoff);
      }
    }

    // Start loop fire-and-forget
    loop().catchError((Object e) { if (!ctrl.isClosed) ctrl.addError(e); });

    return ReconnectSession._internal(
      deviceAddress:    deviceAddress,
      connectionEvents: ctrl.stream,
      dispose: () async {
        disposed = true;
        _src.disconnectDevice(deviceAddress);
        if (!ctrl.isClosed) await ctrl.close();
      },
      waitConnected: ({Duration timeout = const Duration(seconds: 30)}) {
        if (latestConnected?.isCompleted ?? false) return Future.value();
        final c = Completer<void>();
        StreamSubscription<BleConnectionEvent>? s;
        s = ctrl.stream.where((e) => e.state == BleConnectionState.connected)
            .listen(
          (_) { if (!c.isCompleted) c.complete(); },
          onError: (Object e) { if (!c.isCompleted) c.completeError(e); },
          onDone: () {
            if (!c.isCompleted)
              c.completeError(BleException('Session ended before connecting'));
          },
        );
        return c.future.timeout(timeout).whenComplete(() => s?.cancel());
      },
    );
  }

  static Duration _doubleCapped(Duration d, Duration cap) {
    final next = d * 2;
    return next > cap ? cap : next;
  }

  static Future<void> _slicedDelay(Duration d, bool Function() cancelled) async {
    const slice = Duration(milliseconds: 50);
    var elapsed = Duration.zero;
    while (elapsed < d && !cancelled()) {
      await Future<void>.delayed(slice);
      elapsed += slice;
    }
  }
}
