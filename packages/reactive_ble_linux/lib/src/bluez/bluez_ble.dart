// lib/bluez_ble.dart — Public Dart API for the BlueZ BLE FFI bridge.
//
// Matches the ReactiveBlePlatform interface from:
//   PhilipsHue/flutter_reactive_ble PR #347 (robert-ancell, linux-federated)
//
// Architecture:
//   • Channel A (Dart → C++): sync FFI calls via ffi.dart / bindings.dart
//   • Channel B (C++ → Dart): RawReceivePort + Dart_PostCObject_DL events
//   • Channel C (C++ → Dart): SPSC ring for high-freq notifications (opt-in)
//
// Zero-copy throughout — payloads live on the C heap; Dart accesses them
// through asTypedList() views with NativeFinalizer GC hooks.
//
// Lifecycle:
//   1. BluezBle.initialize()          — binds Dart_PostCObject_DL
//   2. Use scan / connect / GATT APIs
//   3. BluezBle.dispose()             — shuts down event loop

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'ble_events.dart';
import 'ble_gatt_cache.dart';
import 'ble_logger.dart';
import 'ble_reconnect.dart';
import 'ble_ring.dart';
import 'ble_types.dart';

export 'ble_gatt_cache.dart';
export 'ble_logger.dart';
export 'ble_reconnect.dart'
    show BleConnectionSource, BleReconnectManager, ReconnectSession;
export 'ble_ring.dart'      show BleNotifRingChannel, BleRingNotification;
export 'ble_types.dart';

// ── BluezBle — main facade ─────────────────────────────────────────────────

/// Top-level BLE facade.  Use as a singleton:
///
/// ```dart
/// final ble = BluezBle();
/// await ble.initialize();
///
/// ble.scanResults.listen((r) => print(r));
/// await ble.startScan(timeoutMs: 10000);
/// ...
/// await ble.dispose();
/// ```
final class BluezBle implements BleConnectionSource {
  BluezBle._();

  static final BluezBle _instance = BluezBle._();
  factory BluezBle() => _instance;

  // ── Internal state ───────────────────────────────────────────────────────

  RawReceivePort? _port;
  StreamController<BleEvent>? _eventCtrl;

  bool _initialized = false;

  // Pending read/write futures: requestId → Completer<BleCharEvent>
  final Map<int, Completer<BleCharEvent>> _pending = {};
  int _nextRequestId = 1;

  /// GATT characteristic path cache — avoids repeated GetManagedObjects calls.
  final BleGattCache gattCache = BleGattCache();

  /// Auto-reconnect manager for this bridge instance.
  late final BleReconnectManager reconnect = BleReconnectManager(this);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Version string of the native library.
  String get version => bluezBleVersion();

  /// Initialize the bridge.  Must be called once before any other method.
  ///
  /// Internally calls [Dart_InitializeApiDL] via [NativeApi.initializeApiDLData],
  /// matching the protocol in jwinarske/native_comms.
  Future<void> initialize() async {
    if (_initialized) return;

    final rc = bluezBleInit(NativeApi.initializeApiDLData);
    if (rc != 0) {
      throw StateError(
          'bluez_ble_init failed ($rc). '
          'Is libdart_bluez_ble.so built and on LD_LIBRARY_PATH?');
    }

    // Open the event port (Channel B).
    _eventCtrl = StreamController<BleEvent>.broadcast();
    _port = RawReceivePort(_onNativeMessage, 'bluez_ble_events');

    final portRc = bluezBleRegisterEventPort(_port!.sendPort.nativePort);
    if (portRc != 0) throw StateError('bluez_ble_register_event_port failed');

    _initialized = true;
    BleLogger.i('init', version);
  }

  /// Release all resources.  After this call the object can be re-initialized.
  Future<void> dispose() async {
    _assertInitialized();
    _initialized = false;

    bluezBleUnregisterEventPort();
    bluezBleShutdown();

    _port?.close();
    _port = null;

    // Fail any pending requests
    for (final c in _pending.values) {
      c.completeError(StateError('BluezBle disposed'));
    }
    _pending.clear();
    gattCache.invalidateAll();

    await _eventCtrl?.close();
    _eventCtrl = null;
    BleLogger.i('init', 'BluezBle disposed');
  }

  // ── Event stream ──────────────────────────────────────────────────────────

  /// All raw BLE events as a broadcast stream.
  /// For typed sub-streams use [scanResults], [connectionEvents], etc.
  Stream<BleEvent> get events {
    _assertInitialized();
    return _eventCtrl!.stream;
  }

  /// Stream of adapter power / discovery state changes.
  Stream<BleAdapterState> get adapterStateStream => events
      .where((e) => e is BleAdapterStateEvent)
      .map((e) => (e as BleAdapterStateEvent).state);

  /// Stream of scan results (one per advertisement packet received).
  Stream<BleScanResult> get scanResults => events
      .where((e) => e is BleScanResultEvent)
      .map((e) => (e as BleScanResultEvent).result);

  /// Stream of device connection state changes.
  Stream<BleConnectionEvent> get connectionEvents => events
      .where((e) => e is BleConnectionEvent2)
      .map((e) => (e as BleConnectionEvent2).event);

  /// Stream of unsolicited GATT notifications (subscribeToCharacteristic).
  Stream<BleCharEvent> get characteristicNotifications => events
      .where((e) => e is BleCharDataEvent)
      .map((e) => (e as BleCharDataEvent).event)
      .where((e) => e.eventType == BleEventType.charNotify);

  /// Stream of C++ error messages.
  Stream<BleError> get errors => events
      .where((e) => e is BleErrorEvent)
      .map((e) => (e as BleErrorEvent).error);

  // ── Adapter ───────────────────────────────────────────────────────────────

  /// Request current adapter state; result arrives on [adapterStateStream].
  int requestAdapterState() {
    _assertInitialized();
    return bluezBleAdapterState();
  }

  // ── Scanning ──────────────────────────────────────────────────────────────

  /// Start BLE scanning.
  ///
  /// [filterUuids]: if non-empty, only report devices advertising these
  ///   service UUIDs (128-bit UUID strings).
  /// [timeoutMs]: automatically stop after this many milliseconds.
  ///   Pass 0 to scan indefinitely (call [stopScan] manually).
  ///
  /// Results arrive on [scanResults].
  Future<int> startScan({
    List<String> filterUuids = const [],
    int timeoutMs = 0,
  }) async {
    _assertInitialized();
    BleLogger.i('scan', 'startScan(filterUuids=$filterUuids, timeoutMs=$timeoutMs)');

    return using((arena) {
      Pointer<Pointer<Char>> uuidPtrs;
      if (filterUuids.isEmpty) {
        uuidPtrs = nullptr;
      } else {
        uuidPtrs = arena<Pointer<Char>>(filterUuids.length + 1);
        for (var i = 0; i < filterUuids.length; i++) {
          uuidPtrs[i] = filterUuids[i].toNativeUtf8(allocator: arena).cast<Char>();
        }
        uuidPtrs[filterUuids.length] = nullptr;
      }
      final rc = bluezBleStartScan(uuidPtrs, timeoutMs);
      BleLogger.i('scan', 'bluezBleStartScan returned $rc');
      return rc;
    });
  }

  /// Stop an ongoing scan.
  int stopScan() {
    _assertInitialized();
    return bluezBleStopScan();
  }

  /// Convenience: scan for [duration] and return all discovered devices.
  Future<List<BleScanResult>> scanForDuration(Duration duration,
      {List<String> filterUuids = const []}) async {
    _assertInitialized();
    final results = <BleScanResult>[];
    final sub = scanResults.listen(results.add);
    await startScan(
        filterUuids: filterUuids,
        timeoutMs: duration.inMilliseconds);
    await Future.delayed(duration);
    stopScan();
    await sub.cancel();
    return results;
  }

  // ── Connection ────────────────────────────────────────────────────────────

  /// Connect to device with BD address [address] ("XX:XX:XX:XX:XX:XX").
  /// State changes arrive on [connectionEvents].
  int connectToDevice(String address) {
    _assertInitialized();
    return using((arena) {
      return bluezBleConnect(address.toNativeUtf8(allocator: arena).cast<Char>());
    });
  }

  /// Disconnect from [address].
  int disconnectDevice(String address) {
    _assertInitialized();
    return using((arena) {
      return bluezBleDisconnect(address.toNativeUtf8(allocator: arena).cast<Char>());
    });
  }

  /// Wait until [address] reaches [BleConnectionState.connected] or throws
  /// on timeout.
  Future<void> waitForConnection(String address,
      {Duration timeout = const Duration(seconds: 10)}) {
    _assertInitialized();
    final completer = Completer<void>();
    late StreamSubscription<BleConnectionEvent> sub;
    sub = connectionEvents
        .where((e) => e.address.toUpperCase() == address.toUpperCase())
        .listen((e) {
      if (e.isConnected) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      } else if (e.hasError) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
              BleException('Connection to $address failed (err=${e.errorCode})'));
        }
      }
    });
    return completer.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw BleException('Connection to $address timed out');
    });
  }

  // ── GATT discovery ────────────────────────────────────────────────────────

  /// Return all characteristic D-Bus object paths for [deviceAddress].
  List<String> getCharacteristicPaths(String deviceAddress) {
    _assertInitialized();
    return using((arena) {
      final addrPtr = deviceAddress.toNativeUtf8(allocator: arena).cast<Char>();
      final result  = bluezBleGetCharPaths(addrPtr);
      if (result == nullptr) return [];

      final paths = <String>[];
      var ptr = result;
      while (ptr.value != nullptr) {
        paths.add(ptr.value.cast<Utf8>().toDartString());
        ptr = Pointer.fromAddress(ptr.address + sizeOf<Pointer>());
      }
      bluezBleFreeStringList(result);
      return paths;
    });
  }

  /// Cache-aware variant: fetches once per connection, returns cached result
  /// on subsequent calls.  Invalidated automatically on disconnect.
  List<String> getCharacteristicPathsCached(String deviceAddress) {
    _assertInitialized();
    if (gattCache.isCached(deviceAddress)) {
      return gattCache.allPaths(deviceAddress);
    }
    final paths = getCharacteristicPaths(deviceAddress);
    if (paths.isNotEmpty) {
      gattCache.populatePathsOnly(deviceAddress, paths);
      BleLogger.d('gatt',
          'cached ${paths.length} characteristic paths for $deviceAddress');
    }
    return paths;
  }

  /// Resolve a characteristic UUID to its D-Bus path using the GATT cache.
  /// Returns null if not found or cache is empty for [deviceAddress].
  String? resolveCharPath(String deviceAddress, String charUuid) {
    _assertInitialized();
    return gattCache.resolvePath(deviceAddress, charUuid);
  }

  /// Populate the GATT cache with full UUID and flag information by calling
  /// [bluez_ble_get_char_info] for each characteristic path.
  ///
  /// This is the full alternative to [getCharacteristicPathsCached] — it makes
  /// one D-Bus property call per characteristic and returns a [GattServiceMap]
  /// with UUID, flags, `canRead`, `canNotify`, etc. populated.
  ///
  /// Tip: always call [waitServicesResolved] first to ensure BlueZ has
  /// completed GATT discovery.
  Future<GattServiceMap> populateGattCache(String deviceAddress) async {
    _assertInitialized();
    final paths = getCharacteristicPaths(deviceAddress);
    BleLogger.d('gatt',
        'populateGattCache: fetching info for ${paths.length} chars on $deviceAddress');

    return gattCache.populate(deviceAddress, paths, (charPath) async {
      return using((arena) {
        final pathPtr    = charPath.toNativeUtf8(allocator: arena).cast<Char>();
        final outUuid    = arena<Pointer<Char>>();
        final outSvcPath = arena<Pointer<Char>>();
        final outSvcUuid = arena<Pointer<Char>>();
        final outFlags   = arena<Pointer<Pointer<Char>>>();

        final rc = bluezBleGetCharInfo(
            pathPtr, outUuid, outSvcPath, outSvcUuid, outFlags);
        if (rc != 0) return null;

        final uuid    = outUuid.value    != nullptr
            ? outUuid.value.cast<Utf8>().toDartString() : '';
        final svcPath = outSvcPath.value != nullptr
            ? outSvcPath.value.cast<Utf8>().toDartString() : '';
        final svcUuid = outSvcUuid.value != nullptr
            ? outSvcUuid.value.cast<Utf8>().toDartString() : '';

        final flags = <String>[];
        if (outFlags.value != nullptr) {
          var fp = outFlags.value;
          while (fp.value != nullptr) {
            flags.add(fp.value.cast<Utf8>().toDartString());
            bluezBleFree(fp.value.cast<Void>());
            fp = Pointer.fromAddress(fp.address + sizeOf<Pointer>());
          }
          bluezBleFree(outFlags.value.cast<Void>());
        }

        // Free C strings
        if (outUuid.value    != nullptr) bluezBleFree(outUuid.value.cast<Void>());
        if (outSvcPath.value != nullptr) bluezBleFree(outSvcPath.value.cast<Void>());
        if (outSvcUuid.value != nullptr) bluezBleFree(outSvcUuid.value.cast<Void>());

        return CharInfo(
          uuid:              uuid,
          serviceObjectPath: svcPath,
          serviceUuid:       svcUuid,
          flags:             flags,
        );
      });
    });
  }

  /// Block (in a background isolate-friendly way) until BlueZ reports
  /// `ServicesResolved = true` for [deviceAddress], or [timeout] elapses.
  ///
  /// BlueZ performs GATT service discovery asynchronously after connection.
  /// Call this before [getCharacteristicPaths] / [populateGattCache] to
  /// ensure the object tree is populated.
  Future<void> waitServicesResolved(String deviceAddress,
      {Duration timeout = const Duration(seconds: 20)}) async {
    _assertInitialized();
    BleLogger.d('gatt', 'waiting for ServicesResolved on $deviceAddress …');
    // Offload the blocking poll to a separate isolate thread
    final result = await _runBlocking(() => using((arena) {
      final addrPtr = deviceAddress.toNativeUtf8(allocator: arena).cast<Char>();
      return bluezBleWaitServicesResolved(addrPtr, timeout.inMilliseconds);
    }));
    if (result != 0) {
      throw BleException(
          'ServicesResolved timeout for $deviceAddress '
          '(waited ${timeout.inSeconds} s)');
    }
    BleLogger.d('gatt', 'ServicesResolved confirmed for $deviceAddress');
  }

  /// Power the Bluetooth adapter on or off.
  int adapterSetPowered({required bool powered}) {
    _assertInitialized();
    return bluezBleAdapterSetPowered(powered ? 1 : 0);
  }

  // ── GATT read ─────────────────────────────────────────────────────────────

  /// Asynchronously read characteristic at [charPath].
  /// Returns a [Future] that completes with the value or throws [BleException].
  Future<Uint8List> readCharacteristic(String charPath) {
    _assertInitialized();
    final reqId = _nextRequestId++;
    final completer = Completer<BleCharEvent>();
    _pending[reqId] = completer;

    using((arena) {
      final rc = bluezBleCharRead(
        charPath.toNativeUtf8(allocator: arena).cast<Char>(),
        reqId,
      );
      if (rc != 0) {
        _pending.remove(reqId);
        completer.completeError(BleException('char_read failed ($rc)'));
      }
    });

    return completer.future.then((e) {
      if (!e.isSuccess) throw BleException('ReadValue error (${e.errorCode})');
      return e.data;
    });
  }

  // ── GATT write ────────────────────────────────────────────────────────────

  /// Write [data] to characteristic at [charPath] (write with response).
  Future<void> writeCharacteristic(String charPath, Uint8List data) {
    _assertInitialized();
    final reqId = _nextRequestId++;
    final completer = Completer<BleCharEvent>();
    _pending[reqId] = completer;

    using((arena) {
      final pathPtr  = charPath.toNativeUtf8(allocator: arena).cast<Char>();
      final dataPtr  = arena<Uint8>(data.length);
      for (var i = 0; i < data.length; i++) dataPtr[i] = data[i];

      final rc = bluezBleCharWrite(pathPtr, dataPtr, data.length, reqId);
      if (rc != 0) {
        _pending.remove(reqId);
        completer.completeError(BleException('char_write failed ($rc)'));
      }
    });

    return completer.future.then((e) {
      if (!e.isSuccess) throw BleException('WriteValue error (${e.errorCode})');
    });
  }

  /// Write [data] without response (fire-and-forget).
  int writeCharacteristicNoResponse(String charPath, Uint8List data) {
    _assertInitialized();
    return using((arena) {
      final pathPtr = charPath.toNativeUtf8(allocator: arena).cast<Char>();
      final dataPtr = arena<Uint8>(data.length);
      for (var i = 0; i < data.length; i++) dataPtr[i] = data[i];
      return bluezBleCharWriteNoResponse(pathPtr, dataPtr, data.length);
    });
  }

  // ── GATT subscribe ────────────────────────────────────────────────────────

  /// Subscribe to notifications from [charPath].
  /// Values arrive on [characteristicNotifications] filtered by [charPath].
  int subscribeToCharacteristic(String charPath) {
    _assertInitialized();
    return using((arena) {
      return bluezBleCharSubscribe(
          charPath.toNativeUtf8(allocator: arena).cast<Char>());
    });
  }

  /// Unsubscribe from [charPath] notifications.
  int unsubscribeFromCharacteristic(String charPath) {
    _assertInitialized();
    return using((arena) {
      return bluezBleCharUnsubscribe(
          charPath.toNativeUtf8(allocator: arena).cast<Char>());
    });
  }

  /// Convenience: return a stream that emits notification values for a
  /// single [charPath].  Subscribes on listen, unsubscribes on cancel.
  Stream<Uint8List> characteristicValueStream(String charPath) {
    _assertInitialized();
    late StreamController<Uint8List> ctrl;
    late StreamSubscription<Uint8List> sub;

    ctrl = StreamController<Uint8List>(
      onListen: () {
        subscribeToCharacteristic(charPath);
        sub = characteristicNotifications
            .where((e) => e.charPath == charPath)
            .map((e) => e.data)
            .listen(ctrl.add, onError: ctrl.addError);
      },
      onCancel: () {
        sub.cancel();
        unsubscribeFromCharacteristic(charPath);
      },
    );
    return ctrl.stream;
  }

  // ── High-frequency ring channel (Channel C) ───────────────────────────────

  /// Create a high-throughput notification ring for characteristics whose
  /// D-Bus path starts with [charPathPrefix] (or all if null).
  ///
  /// This bypasses the Dart scheduler overhead of the ReceivePort path and
  /// delivers values at full sensor rate (tested at >5 000 notifications/s
  /// with ~16 ns/slot on the ring, matching native_comms Channel C numbers).
  BleNotifRingChannel createNotifRing({
    String? charPathPrefix,
    int capacity = 128,
    Duration pollInterval = const Duration(milliseconds: 8),
  }) {
    _assertInitialized();
    final ring = BleNotifRingChannel.create(
      capacity: capacity,
      pollInterval: pollInterval,
    );
    ring.attach(charPathPrefix);
    return ring;
  }

  // ── Internal message handler ──────────────────────────────────────────────

  void _onNativeMessage(dynamic message) {
    if (_eventCtrl == null || _eventCtrl!.isClosed) {
      BleLogger.w('event', '_onNativeMessage: eventCtrl is null or closed, dropping');
      return;
    }

    // Channel B: C++ posts Uint8List (kExternalTypedData).
    // The backing store IS the C++ malloc allocation — zero copy.
    if (message is! Uint8List) {
      BleLogger.w('event', '_onNativeMessage: non-Uint8List message: ${message.runtimeType}');
      return;
    }

    BleLogger.d('event', '_onNativeMessage: received ${message.length} bytes, type=0x${message.isNotEmpty ? message[0].toRadixString(16) : "empty"}');

    final event = decodeBleEvent(message);
    if (event == null) {
      BleLogger.w('event', '_onNativeMessage: decodeBleEvent returned null for ${message.length} bytes');
      return;
    }

    BleLogger.d('event', '_onNativeMessage: decoded ${event.runtimeType}');

    // Invalidate GATT cache on disconnect
    if (event is BleConnectionEvent2) {
      final e = event.event;
      if (e.state == BleConnectionState.disconnected) {
        gattCache.invalidate(e.address);
        BleLogger.d('conn', 'disconnected ${e.address} — GATT cache cleared');
      } else if (e.state == BleConnectionState.connected) {
        BleLogger.d('conn', 'connected ${e.address}');
      }
    }

    // Route read/write replies to pending completers
    if (event is BleCharDataEvent) {
      final reqId = event.event.requestId;
      if (reqId != 0) {
        final completer = _pending.remove(reqId);
        if (completer != null) {
          completer.complete(event.event);
          return; // do not also emit on the public stream
        }
      }
    }

    if (event is BleErrorEvent) {
      BleLogger.e('native', event.error.message);
    }

    _eventCtrl!.add(event);
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError(
          'BluezBle is not initialized. Call await ble.initialize() first.');
    }
  }

  /// Run [fn] on a separate [Isolate] so the main isolate remains responsive
  /// during the blocking C++ call (e.g. `bluez_ble_wait_services_resolved`).
  static Future<T> _runBlocking<T>(T Function() fn) {
    final recv    = ReceivePort();
    final errRecv = ReceivePort();
    Isolate.spawn(_isolateEntry<T>,
        _IsolateMsg(fn, recv.sendPort),
        onError: errRecv.sendPort);
    final completer = Completer<T>();
    recv.listen((msg) {
      recv.close();
      errRecv.close();
      if (!completer.isCompleted) completer.complete(msg as T);
    });
    errRecv.listen((msg) {
      recv.close();
      errRecv.close();
      if (!completer.isCompleted) {
        final list = msg as List;
        completer.completeError(list[0] as Object,
            list[1] != null ? list[1] as StackTrace : null);
      }
    });
    return completer.future;
  }

  static void _isolateEntry<T>(_IsolateMsg<T> msg) {
    msg.replyPort.send(msg.fn());
  }
}

// ── Isolate helper ─────────────────────────────────────────────────────────

class _IsolateMsg<T> {
  const _IsolateMsg(this.fn, this.replyPort);
  final T Function() fn;
  final SendPort replyPort;
}

// BleException is defined in ble_types.dart and re-exported via this file.
