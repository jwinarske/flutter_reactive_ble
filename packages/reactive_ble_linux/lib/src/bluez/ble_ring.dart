// lib/src/ble_ring.dart — Dart wrapper for the C++ SPSC notification ring.
//
// Used for high-frequency GATT characteristic notifications (e.g. 200 Hz
// IMU sensors) where posting every value through Dart_PostCObject_DL would
// saturate the ReceivePort scheduler.  Instead, C++ pushes into the ring
// and Dart drains it via a Timer.periodic poll.
//
// Pattern from jwinarske/native_comms Channel C (SPSCRing / drainRing).

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'ffi_types.dart';

/// A single notification value drained from the ring.
final class BleRingNotification {
  const BleRingNotification({
    required this.charPath,
    required this.data,
  });

  final String    charPath;
  final Uint8List data; // zero-copy view over the C malloc allocation
}

/// High-throughput GATT notification channel backed by an SPSC lock-free ring.
///
/// Usage:
/// ```dart
/// final ring = BleNotifRingChannel.create(capacity: 64);
/// ring.attach('/org/bluez/hci0/dev_AA_BB/service0001/char0002');
/// ring.stream.listen((notif) => print(notif.data));
/// await ring.dispose();
/// ```
final class BleNotifRingChannel {
  BleNotifRingChannel._({
    required Pointer<BleNotifRingOpaque> handle,
    required Duration pollInterval,
  })  : _handle = handle,
        _controller = StreamController<BleRingNotification>.broadcast() {
    _timer = Timer.periodic(pollInterval, (_) => _drain());
  }

  /// Create a new ring with [capacity] slots (rounded up to power-of-two).
  factory BleNotifRingChannel.create({
    int capacity = 64,
    Duration pollInterval = const Duration(milliseconds: 8),
  }) {
    final handle = bluezBleRingCreate(capacity);
    if (handle == nullptr) {
      throw StateError('bluez_ble_ring_create($capacity) returned null');
    }
    return BleNotifRingChannel._(
      handle: handle,
      pollInterval: pollInterval,
    );
  }

  final Pointer<BleNotifRingOpaque> _handle;
  final StreamController<BleRingNotification> _controller;
  late final Timer _timer;

  /// Broadcast stream of notifications drained from the ring.
  Stream<BleRingNotification> get stream => _controller.stream;

  /// How many slots are currently occupied.
  int get size => bluezBleRingSize(_handle);

  /// Attach this ring to receive notifications from characteristics whose
  /// D-Bus path starts with [charPathPrefix].  Pass [null] for all.
  void attach([String? charPathPrefix]) {
    using((arena) {
      final prefix = charPathPrefix != null
          ? charPathPrefix.toNativeUtf8(allocator: arena).cast<Char>()
          : nullptr.cast<Char>();
      final rc = bluezBleRingAttach(prefix, _handle);
      if (rc != 0) throw StateError('bluez_ble_ring_attach failed ($rc)');
    });
  }

  /// Detach from C++; notifications stop being pushed to this ring.
  void detach() => bluezBleRingDetach(_handle);

  /// Drain all available slots and emit them on [stream].
  /// Called automatically by the internal [Timer]; exposed for testing.
  void drainNow() => _drain();

  void _drain() {
    using((arena) {
      final outData = arena<Pointer<Uint8>>();
      final outLen  = arena<Uint32>();
      final outPath = arena<Pointer<Char>>();

      while (bluezBleRingPop(_handle, outData, outLen, outPath)) {
        final len  = outLen.value;
        final data = outData.value;
        final path = outPath.value;

        // Copy data to a Dart-owned Uint8List and free the C allocation.
        final view = Uint8List.fromList(data.asTypedList(len));
        bluezBleFree(data.cast<Void>());

        final charPath = path != nullptr
            ? path.cast<Utf8>().toDartString()
            : '';

        // Free the path string (the data pointer is owned by the finalizer)
        if (path != nullptr) bluezBleFree(path.cast<Void>());

        if (!_controller.isClosed) {
          _controller.add(BleRingNotification(charPath: charPath, data: view));
        }
      }
    });
  }

  Future<void> dispose() async {
    _timer.cancel();
    detach();
    await _controller.close();
    bluezBleRingDestroy(_handle);
  }
}

