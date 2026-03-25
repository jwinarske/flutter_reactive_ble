// lib/src/ble_gatt_cache.dart — GATT characteristic path cache.
//
// `GetManagedObjects` is an expensive D-Bus round-trip that enumerates every
// object under org.bluez.  Calling it on every read/write/subscribe adds
// ~1–5 ms of latency per operation.  This cache stores the result per device
// and invalidates it on disconnect.
//
// Thread-safety: single Dart isolate — no locking needed.

import 'dart:async';

/// A single GATT characteristic entry.
final class GattCharacteristic {
  const GattCharacteristic({
    required this.objectPath,
    required this.uuid,
    required this.serviceObjectPath,
    required this.serviceUuid,
    required this.flags,
  });

  /// D-Bus object path, e.g.
  ///   `/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001/char0002`
  final String objectPath;

  /// 128-bit UUID string (lowercase, with dashes).
  final String uuid;

  /// Parent service object path.
  final String serviceObjectPath;

  /// Parent service UUID.
  final String serviceUuid;

  /// BlueZ characteristic flags: `["read", "write", "notify", ...]`.
  final List<String> flags;

  bool get canRead         => flags.contains('read');
  bool get canWrite        => flags.contains('write');
  bool get canWriteNoResp  => flags.contains('write-without-response');
  bool get canNotify       => flags.contains('notify');
  bool get canIndicate     => flags.contains('indicate');

  @override
  String toString() =>
      'GattChar(uuid=$uuid, flags=${flags.join('|')})';
}

/// Per-device GATT service map.
final class GattServiceMap {
  GattServiceMap({
    required this.deviceAddress,
    required this.characteristics,
    required this.fetchedAt,
  });

  final String                     deviceAddress;
  /// uuid → GattCharacteristic (first match wins if duplicates exist)
  final Map<String, GattCharacteristic> characteristics;
  final DateTime                   fetchedAt;

  /// All characteristic object paths under this device.
  Iterable<String> get allPaths => characteristics.values.map((c) => c.objectPath);

  /// Look up a characteristic by 128-bit UUID (case-insensitive).
  GattCharacteristic? byUuid(String uuid) =>
      characteristics[uuid.toLowerCase()];

  /// Look up a characteristic by its D-Bus object path.
  GattCharacteristic? byPath(String path) {
    for (final c in characteristics.values) {
      if (c.objectPath == path) return c;
    }
    return null;
  }

  bool get isEmpty => characteristics.isEmpty;
}

/// Cache of discovered GATT service maps, keyed by device address.
///
/// Usage:
/// ```dart
/// final cache = BleGattCache();
///
/// // Populate after connection
/// await cache.populate(ble, 'AA:BB:CC:DD:EE:FF');
///
/// // Resolve a characteristic UUID to its D-Bus path
/// final path = cache.resolvePath('AA:BB:CC:DD:EE:FF',
///                                 '0000aa20-0000-1000-8000-00805f9b34fb');
///
/// // Invalidate on disconnect
/// cache.invalidate('AA:BB:CC:DD:EE:FF');
/// ```
final class BleGattCache {
  final Map<String, GattServiceMap> _cache = {};

  // ── Population ──────────────────────────────────────────────────────────

  /// Populate the cache for [deviceAddress] using characteristic paths
  /// returned by [getCharacteristicPaths].
  ///
  /// [getCharacteristicPaths]: returns raw D-Bus object paths.
  /// [getCharacteristicInfo]: returns `(uuid, serviceUuid, serviceObjectPath, flags)`
  ///   for a given characteristic path — caller supplies by querying
  ///   `org.freedesktop.DBus.Properties.GetAll` on `org.bluez.GattCharacteristic1`.
  Future<GattServiceMap> populate(
    String deviceAddress,
    List<String> charPaths,
    Future<CharInfo?> Function(String charPath) getCharacteristicInfo,
  ) async {
    final chars = <String, GattCharacteristic>{};
    for (final path in charPaths) {
      final info = await getCharacteristicInfo(path);
      if (info == null) continue;
      final uuid = info.uuid.toLowerCase();
      chars[uuid] = GattCharacteristic(
        objectPath:        path,
        uuid:              uuid,
        serviceObjectPath: info.serviceObjectPath,
        serviceUuid:       info.serviceUuid.toLowerCase(),
        flags:             info.flags,
      );
    }
    final map = GattServiceMap(
      deviceAddress:   deviceAddress.toUpperCase(),
      characteristics: chars,
      fetchedAt:       DateTime.now(),
    );
    _cache[deviceAddress.toUpperCase()] = map;
    return map;
  }

  /// Populate the cache from a pre-built path list without querying
  /// characteristic properties (flags and UUIDs will be empty — sufficient
  /// for path-based lookup only).
  GattServiceMap populatePathsOnly(
      String deviceAddress, List<String> charPaths) {
    final chars = <String, GattCharacteristic>{};
    for (final path in charPaths) {
      // Derive a pseudo-UUID from the path's last segment so it's unique
      final pseudo = _pseudoUuid(path);
      chars[pseudo] = GattCharacteristic(
        objectPath:        path,
        uuid:              pseudo,
        serviceObjectPath: _parentPath(path),
        serviceUuid:       '',
        flags:             const [],
      );
    }
    final map = GattServiceMap(
      deviceAddress:   deviceAddress.toUpperCase(),
      characteristics: chars,
      fetchedAt:       DateTime.now(),
    );
    _cache[deviceAddress.toUpperCase()] = map;
    return map;
  }

  // ── Lookup ──────────────────────────────────────────────────────────────

  /// Return the [GattServiceMap] for [deviceAddress], or null if not cached.
  GattServiceMap? operator [](String deviceAddress) =>
      _cache[deviceAddress.toUpperCase()];

  bool isCached(String deviceAddress) =>
      _cache.containsKey(deviceAddress.toUpperCase());

  /// Resolve a characteristic UUID to its D-Bus object path.
  /// Returns null if not found.
  String? resolvePath(String deviceAddress, String charUuid) =>
      _cache[deviceAddress.toUpperCase()]
          ?.byUuid(charUuid)
          ?.objectPath;

  /// Resolve a D-Bus object path to its UUID.
  String? resolveUuid(String deviceAddress, String charPath) =>
      _cache[deviceAddress.toUpperCase()]
          ?.byPath(charPath)
          ?.uuid;

  /// Return all paths for [deviceAddress].
  List<String> allPaths(String deviceAddress) =>
      _cache[deviceAddress.toUpperCase()]
          ?.allPaths
          .toList() ??
      const [];

  // ── Lifecycle ──────────────────────────────────────────────────────────

  void invalidate(String deviceAddress) =>
      _cache.remove(deviceAddress.toUpperCase());

  void invalidateAll() => _cache.clear();

  int get cachedDeviceCount => _cache.length;

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Extract a pseudo-UUID from the tail of a D-Bus path for indexing.
  static String _pseudoUuid(String path) {
    // e.g. "…/service0001/char0002" → "00000000-0000-0000-0000-000000000002"
    final seg = path.split('/').lastWhere(
        (s) => s.startsWith('char'), orElse: () => path.split('/').last);
    final hex = seg.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').padLeft(32, '0');
    return '${hex.substring(0,8)}-${hex.substring(8,12)}'
           '-${hex.substring(12,16)}-${hex.substring(16,20)}'
           '-${hex.substring(20)}';
  }

  static String _parentPath(String path) {
    final segments = path.split('/');
    if (segments.length < 2) return path;
    return segments.sublist(0, segments.length - 1).join('/');
  }
}

/// Characteristic property data returned by the caller's info-fetcher.
/// Used as the callback result type in [BleGattCache.populate].
final class CharInfo {
  const CharInfo({
    required this.uuid,
    required this.serviceObjectPath,
    required this.serviceUuid,
    required this.flags,
  });
  final String       uuid;
  final String       serviceObjectPath;
  final String       serviceUuid;
  final List<String> flags;
}
