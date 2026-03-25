// Linux platform implementation of ReactiveBlePlatform using the
// dart_bluez_ble FFI bridge (BlueZ via sdbus-cpp, no dart:dbus).

import 'dart:async';
import 'dart:typed_data';

import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';

import 'bluez/bluez_ble.dart';

class ReactiveBlePlatformLinux extends ReactiveBlePlatform {
  ReactiveBlePlatformLinux({Logger? logger})
      : _ble = BluezBle(),
        _logger = logger;

  final BluezBle _ble;
  final Logger? _logger;
  bool _initialized = false;

  // Broadcast controllers that merge all device events into single streams
  // matching the platform interface contract.
  StreamController<ConnectionStateUpdate>? _connCtrl;
  StreamController<CharacteristicValue>? _charCtrl;
  StreamController<BleStatus>? _statusCtrl;
  BleStatus _lastStatus = BleStatus.unknown;
  StreamSubscription<BleConnectionEvent>? _connSub;
  StreamSubscription<BleCharEvent>? _notifSub;
  StreamSubscription<BleEvent>? _statusSub;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _logger?.log('Initialize BLE Linux platform');
    BleLogger.minimumLevel = BleLogLevel.debug;
    await _ble.initialize();
    _initialized = true;
    _setupEventBridge();
    _logger?.log('Initialize BLE Linux platform: done, event bridge set up');
  }

  @override
  Future<void> deinitialize() async {
    if (!_initialized) return;
    _logger?.log('Deinitialize BLE Linux platform');
    _initialized = false;
    await _connSub?.cancel();
    await _notifSub?.cancel();
    await _statusSub?.cancel();
    await _connCtrl?.close();
    await _charCtrl?.close();
    await _statusCtrl?.close();
    _connCtrl = null;
    _charCtrl = null;
    _statusCtrl = null;
    _connSub = null;
    _notifSub = null;
    _statusSub = null;
    await _ble.dispose();
  }

  Future<void> _ensureInit() async {
    if (!_initialized) await initialize();
  }

  void _setupEventBridge() {
    _connCtrl = StreamController<ConnectionStateUpdate>.broadcast();
    _charCtrl = StreamController<CharacteristicValue>.broadcast();
    _statusCtrl = StreamController<BleStatus>.broadcast();

    // Bridge adapter state → BleStatus
    //
    // Subscribe directly to the raw events stream so the subscription is
    // registered in the same synchronous call as the controller creation.
    // Using adapterStateStream creates a .where().map() transform that
    // may not be fully wired before the first event arrives.
    _statusSub = _ble.events.listen((event) {
      if (event is BleAdapterStateEvent) {
        final s = event.state;
        final status = s.powered ? BleStatus.ready : BleStatus.poweredOff;
        _logger?.log('bleStatusStream: adapter powered=${s.powered} → $status');
        _lastStatus = status;
        _statusCtrl?.add(status);
      }
    });
    // Request initial state now that subscription is active
    _ble.requestAdapterState();

    _connSub = _ble.connectionEvents.listen((e) {
      final state = switch (e.state) {
        BleConnectionState.connecting => DeviceConnectionState.connecting,
        BleConnectionState.connected => DeviceConnectionState.connected,
        BleConnectionState.disconnecting =>
          DeviceConnectionState.disconnecting,
        BleConnectionState.disconnected =>
          DeviceConnectionState.disconnected,
      };
      _connCtrl?.add(ConnectionStateUpdate(
        deviceId: e.address,
        connectionState: state,
        failure: e.hasError
            ? GenericFailure<ConnectionError>(
                code: ConnectionError.failedToConnect,
                message: 'Error code ${e.errorCode}',
              )
            : null,
      ));
    });

    _notifSub = _ble.characteristicNotifications.listen((e) {
      final charPath = e.charPath;
      final deviceAddress = _extractDeviceAddress(charPath);
      final charUuid = _ble.gattCache.resolveUuid(deviceAddress, charPath);

      _charCtrl?.add(CharacteristicValue(
        characteristic: CharacteristicInstance(
          characteristicId: charUuid != null
              ? Uuid.parse(charUuid)
              : Uuid.parse('00000000-0000-0000-0000-000000000000'),
          characteristicInstanceId: charPath,
          serviceId: Uuid.parse('00000000-0000-0000-0000-000000000000'),
          serviceInstanceId: '',
          deviceId: deviceAddress,
        ),
        result: Result.success(e.data.toList()),
      ));
    });
  }

  // ── Status stream ──────────────────────────────────────────────────────

  @override
  Stream<BleStatus> get bleStatusStream {
    if (_statusCtrl == null) {
      return const Stream<BleStatus>.empty();
    }
    // Replay the last known status immediately for late subscribers,
    // then forward live updates. This is needed because _statusCtrl is
    // a broadcast stream that doesn't buffer past events.
    final ctrl = StreamController<BleStatus>();
    ctrl.onListen = () {
      ctrl.add(_lastStatus);
      _statusCtrl!.stream.listen(
        ctrl.add,
        onError: ctrl.addError,
        onDone: ctrl.close,
      );
    };
    return ctrl.stream;
  }

  // ── Connection stream ──────────────────────────────────────────────────

  @override
  Stream<ConnectionStateUpdate> get connectionUpdateStream {
    if (_connCtrl == null) {
      return const Stream<ConnectionStateUpdate>.empty();
    }
    return _connCtrl!.stream;
  }

  // ── Characteristic value stream ────────────────────────────────────────

  @override
  Stream<CharacteristicValue> get charValueUpdateStream {
    if (_charCtrl == null) {
      return const Stream<CharacteristicValue>.empty();
    }
    return _charCtrl!.stream;
  }

  // ── Scan ───────────────────────────────────────────────────────────────

  @override
  Stream<ScanResult> get scanStream {
    late StreamController<ScanResult> ctrl;
    StreamSubscription<BleScanResult>? sub;

    ctrl = StreamController<ScanResult>(
      onListen: () async {
        await _ensureInit();
        _logger?.log('scanStream: subscribed to _ble.scanResults');
        sub = _ble.scanResults.listen((r) {
          _logger?.log('scanStream: got scan result ${r.address} ${r.name} rssi=${r.rssi}');
          final mfrData = r.manufacturerCompanyId != 0xFFFF
              ? _encodeMfrData(r.manufacturerCompanyId, r.manufacturerData)
              : Uint8List(0);

          ctrl.add(ScanResult(
            result: Result.success(DiscoveredDevice(
              id: r.address,
              name: r.name,
              rssi: r.rssi,
              serviceUuids: r.serviceUuids.map(Uuid.parse).toList(),
              serviceData: const {},
              manufacturerData: mfrData,
              connectable: Connectable.unknown,
            )),
          ));
        });
      },
      onCancel: () {
        sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  @override
  Stream<void> scanForDevices({
    required List<Uuid> withServices,
    required ScanMode scanMode,
    required bool requireLocationServicesEnabled,
  }) {
    _logger?.log(
      'Scan for devices with services: $withServices, scanMode: $scanMode',
    );
    return _startScan(withServices).asStream();
  }

  Future<void> _startScan(List<Uuid> withServices) async {
    await _ensureInit();
    final uuids = withServices.map((u) => u.toString()).toList();
    _logger?.log('_startScan: calling _ble.startScan(filterUuids=$uuids)');
    final rc = await _ble.startScan(filterUuids: uuids);
    _logger?.log('_startScan: startScan returned $rc');
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────

  @override
  Stream<void> connectToDevice(
    String id,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  ) {
    _logger?.log('Connect to device: $id');
    return _connectAndDiscover(id, connectionTimeout).asStream();
  }

  Future<void> _connectAndDiscover(
      String id, Duration? connectionTimeout) async {
    await _ensureInit();
    _ble.connectToDevice(id);
    await _ble.waitForConnection(id,
        timeout: connectionTimeout ?? const Duration(seconds: 30));

    // Wait for BlueZ GATT discovery and populate cache
    try {
      await _ble.waitServicesResolved(id,
          timeout: connectionTimeout ?? const Duration(seconds: 20));
      await _ble.populateGattCache(id);
    } catch (_) {
      // Best effort — cache paths even if full populate fails
      _ble.gattCache.populatePathsOnly(
          id, _ble.getCharacteristicPaths(id));
    }
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    _logger?.log('Disconnect device: $deviceId');
    await _ensureInit();
    _ble.disconnectDevice(deviceId);
  }

  // ── Service discovery ──────────────────────────────────────────────────

  @override
  Future<List<DiscoveredService>> discoverServices(String deviceId) async {
    await _ensureInit();
    return _buildDiscoveredServices(deviceId);
  }

  @override
  Future<List<DiscoveredService>> getDiscoverServices(String deviceId) async {
    await _ensureInit();
    return _buildDiscoveredServices(deviceId);
  }

  List<DiscoveredService> _buildDiscoveredServices(String deviceId) {
    final svcMap = _ble.gattCache[deviceId];
    if (svcMap == null || svcMap.isEmpty) return const [];

    // Group characteristics by service
    final byService = <String, List<GattCharacteristic>>{};
    for (final c in svcMap.characteristics.values) {
      byService.putIfAbsent(c.serviceObjectPath, () => []).add(c);
    }

    return byService.entries.map((entry) {
      final chars = entry.value;
      final svcUuid = chars.first.serviceUuid;
      final svcInstanceId = entry.key;

      return DiscoveredService(
        serviceId: svcUuid.isNotEmpty
            ? Uuid.parse(svcUuid)
            : Uuid.parse('00000000-0000-0000-0000-000000000000'),
        serviceInstanceId: svcInstanceId,
        characteristicIds:
            chars.map((c) => Uuid.parse(c.uuid)).toList(),
        characteristics: chars
            .map((c) => DiscoveredCharacteristic(
                  characteristicId: Uuid.parse(c.uuid),
                  characteristicInstanceId: c.objectPath,
                  serviceId: svcUuid.isNotEmpty
                      ? Uuid.parse(svcUuid)
                      : Uuid.parse('00000000-0000-0000-0000-000000000000'),
                  isReadable: c.canRead,
                  isWritableWithResponse: c.canWrite,
                  isWritableWithoutResponse: c.canWriteNoResp,
                  isNotifiable: c.canNotify,
                  isIndicatable: c.canIndicate,
                ))
            .toList(),
      );
    }).toList();
  }

  // ── Read characteristic ────────────────────────────────────────────────

  @override
  Stream<void> readCharacteristic(CharacteristicInstance characteristic) {
    _logger?.log('Read characteristic: $characteristic');
    return _doRead(characteristic).asStream();
  }

  Future<void> _doRead(CharacteristicInstance characteristic) async {
    await _ensureInit();
    final path = _resolveCharPath(characteristic);
    try {
      final data = await _ble.readCharacteristic(path);
      _charCtrl?.add(CharacteristicValue(
        characteristic: characteristic,
        result: Result.success(data.toList()),
      ));
    } on BleException catch (e) {
      _charCtrl?.add(CharacteristicValue(
        characteristic: characteristic,
        result: Result.failure(GenericFailure<CharacteristicValueUpdateError>(
          code: CharacteristicValueUpdateError.unknown,
          message: e.message,
        )),
      ));
    }
  }

  // ── Write characteristic ───────────────────────────────────────────────

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) async {
    _logger?.log('Write with response to $characteristic');
    await _ensureInit();
    final path = _resolveCharPath(characteristic);
    try {
      await _ble.writeCharacteristic(path, Uint8List.fromList(value));
      return WriteCharacteristicInfo(
        characteristic: characteristic,
        result: const Result.success(Unit()),
      );
    } on BleException catch (e) {
      return WriteCharacteristicInfo(
        characteristic: characteristic,
        result: Result.failure(GenericFailure<WriteCharacteristicFailure>(
          code: WriteCharacteristicFailure.unknown,
          message: e.message,
        )),
      );
    }
  }

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) async {
    _logger?.log('Write without response to $characteristic');
    await _ensureInit();
    final path = _resolveCharPath(characteristic);
    final rc =
        _ble.writeCharacteristicNoResponse(path, Uint8List.fromList(value));
    if (rc == 0) {
      return WriteCharacteristicInfo(
        characteristic: characteristic,
        result: const Result.success(Unit()),
      );
    }
    return WriteCharacteristicInfo(
      characteristic: characteristic,
      result: Result.failure(GenericFailure<WriteCharacteristicFailure>(
        code: WriteCharacteristicFailure.unknown,
        message: 'write_no_response failed ($rc)',
      )),
    );
  }

  // ── Subscribe to notifications ─────────────────────────────────────────

  @override
  Stream<void> subscribeToNotifications(
    CharacteristicInstance characteristic,
  ) {
    _logger?.log('Subscribe to notifications for $characteristic');
    return _doSubscribe(characteristic).asStream();
  }

  Future<void> _doSubscribe(CharacteristicInstance characteristic) async {
    await _ensureInit();
    final path = _resolveCharPath(characteristic);
    _ble.subscribeToCharacteristic(path);
  }

  @override
  Future<void> stopSubscribingToNotifications(
    CharacteristicInstance characteristic,
  ) async {
    _logger?.log('Stop subscribing to notifications for $characteristic');
    await _ensureInit();
    final path = _resolveCharPath(characteristic);
    _ble.unsubscribeFromCharacteristic(path);
  }

  // ── MTU ────────────────────────────────────────────────────────────────

  @override
  Future<int> requestMtuSize(String deviceId, int? mtu) async {
    // BlueZ auto-negotiates MTU; return requested value as best-effort.
    await _ensureInit();
    return mtu ?? 23;
  }

  // ── Connection priority (not applicable on Linux) ──────────────────────

  @override
  Future<ConnectionPriorityInfo> requestConnectionPriority(
      String deviceId, ConnectionPriority priority) async {
    return ConnectionPriorityInfo(
      result: Result.failure(GenericFailure<ConnectionPriorityFailure>(
        code: ConnectionPriorityFailure.unknown,
        message: 'Connection priority is not supported on Linux',
      )),
    );
  }

  // ── Clear GATT cache (not applicable on Linux) ─────────────────────────

  @override
  Future<Result<Unit, GenericFailure<ClearGattCacheError>?>> clearGattCache(
      String deviceId) async {
    // BlueZ does not have a GATT cache clear operation
    _ble.gattCache.invalidate(deviceId);
    return const Result.success(Unit());
  }

  // ── RSSI ───────────────────────────────────────────────────────────────

  @override
  Future<int> readRssi(String deviceId) async {
    // RSSI not available post-connection in BlueZ without HCI commands
    return 0;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Resolve a CharacteristicInstance to a BlueZ D-Bus object path.
  String _resolveCharPath(CharacteristicInstance c) {
    // If the instanceId is already a D-Bus path, use it directly
    if (c.characteristicInstanceId.startsWith('/org/bluez/')) {
      return c.characteristicInstanceId;
    }

    // Try resolving via UUID through the GATT cache
    final path = _ble.gattCache.resolvePath(
        c.deviceId, c.characteristicId.toString());
    if (path != null) return path;

    // Fall back to searching available paths
    final paths = _ble.getCharacteristicPaths(c.deviceId);
    final uuidLower =
        c.characteristicId.toString().toLowerCase().replaceAll('-', '');
    for (final p in paths) {
      if (p.toLowerCase().contains(uuidLower)) return p;
    }

    return paths.isNotEmpty ? paths.first : c.characteristicId.toString();
  }

  /// Extract device BD address from a BlueZ D-Bus object path.
  static String _extractDeviceAddress(String dbusPath) {
    // Path format: /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service.../char...
    final match =
        RegExp(r'dev_([0-9A-Fa-f_]{17})').firstMatch(dbusPath);
    if (match == null) return '';
    return match.group(1)!.replaceAll('_', ':').toUpperCase();
  }

  /// Encode manufacturer data with company ID prefix (matching Android format).
  static Uint8List _encodeMfrData(int companyId, Uint8List data) {
    final result = Uint8List(2 + data.length);
    result[0] = companyId & 0xFF;
    result[1] = (companyId >> 8) & 0xFF;
    result.setRange(2, 2 + data.length, data);
    return result;
  }
}

class ReactiveBlePlatformLinuxFactory {
  const ReactiveBlePlatformLinuxFactory();

  ReactiveBlePlatformLinux create({Logger? logger}) {
    return ReactiveBlePlatformLinux(logger: logger);
  }
}
