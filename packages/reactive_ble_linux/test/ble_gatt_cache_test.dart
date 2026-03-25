// test/ble_gatt_cache_test.dart — Unit tests for BleGattCache.
// No .so required.

import 'package:test/test.dart';
import 'package:reactive_ble_linux/src/bluez/ble_gatt_cache.dart';

void main() {
  const addr  = 'AA:BB:CC:DD:EE:FF';
  const path1 = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001/char0002';
  const path2 = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001/char0004';
  const path3 = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011';
  const uuid1 = '0000180d-0000-1000-8000-00805f9b34fb';
  const uuid2 = '00002a37-0000-1000-8000-00805f9b34fb';
  const uuid3 = '0000aa20-0000-1000-8000-00805f9b34fb';

  late BleGattCache cache;

  setUp(() => cache = BleGattCache());

  // ── populatePathsOnly ────────────────────────────────────────────────────
  group('populatePathsOnly', () {
    test('stores paths and reports isCached', () {
      expect(cache.isCached(addr), isFalse);
      cache.populatePathsOnly(addr, [path1, path2, path3]);
      expect(cache.isCached(addr), isTrue);
    });

    test('allPaths returns every path', () {
      cache.populatePathsOnly(addr, [path1, path2, path3]);
      final all = cache.allPaths(addr);
      expect(all, containsAll([path1, path2, path3]));
      expect(all.length, equals(3));
    });

    test('case-insensitive address lookup', () {
      cache.populatePathsOnly(addr.toLowerCase(), [path1]);
      expect(cache.isCached(addr.toUpperCase()), isTrue);
    });

    test('empty path list stores empty map', () {
      cache.populatePathsOnly(addr, []);
      expect(cache.isCached(addr), isTrue);
      expect(cache.allPaths(addr), isEmpty);
    });
  });

  // ── populate with full info ──────────────────────────────────────────────
  group('populate with GattCharacteristic info', () {
    late GattServiceMap map;

    setUp(() async {
      map = await cache.populate(
        addr,
        [path1, path2, path3],
        (charPath) async {
          return switch (charPath) {
            path1 => _charInfo(uuid1, svcUuid: uuid1,
                                svcPath: '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001',
                                flags: ['read', 'notify']),
            path2 => _charInfo(uuid2, svcUuid: uuid1,
                                svcPath: '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001',
                                flags: ['read', 'write', 'write-without-response']),
            path3 => _charInfo(uuid3, svcUuid: uuid3,
                                svcPath: '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010',
                                flags: ['write']),
            _     => null,
          };
        },
      );
    });

    test('byUuid finds char by UUID', () {
      expect(map.byUuid(uuid1), isNotNull);
      expect(map.byUuid(uuid1)?.objectPath, equals(path1));
      expect(map.byUuid(uuid1)?.flags, containsAll(['read', 'notify']));
    });

    test('byUuid is case-insensitive', () {
      expect(map.byUuid(uuid2.toUpperCase()), isNotNull);
    });

    test('byPath finds char by D-Bus path', () {
      expect(map.byPath(path2)?.uuid, equals(uuid2.toLowerCase()));
    });

    test('flags parsed correctly', () {
      final c1 = map.byUuid(uuid1)!;
      expect(c1.canRead,    isTrue);
      expect(c1.canNotify,  isTrue);
      expect(c1.canWrite,   isFalse);

      final c2 = map.byUuid(uuid2)!;
      expect(c2.canWrite,        isTrue);
      expect(c2.canWriteNoResp,  isTrue);
      expect(c2.canNotify,       isFalse);
    });

    test('serviceObjectPath and serviceUuid populated', () {
      final c = map.byUuid(uuid1)!;
      expect(c.serviceUuid, equals(uuid1.toLowerCase()));
      expect(c.serviceObjectPath, contains('service0001'));
    });
  });

  // ── resolvePath / resolveUuid ────────────────────────────────────────────
  group('resolvePath / resolveUuid', () {
    setUp(() async {
      await cache.populate(
        addr, [path1],
        (_) async => _charInfo(uuid1, svcUuid: uuid1,
            svcPath: '/svc', flags: ['read']),
      );
    });

    test('resolvePath returns correct D-Bus path', () {
      expect(cache.resolvePath(addr, uuid1), equals(path1));
    });

    test('resolvePath returns null for unknown UUID', () {
      expect(cache.resolvePath(addr, '00000000-0000-0000-0000-000000000000'),
             isNull);
    });

    test('resolvePath returns null for unknown device', () {
      expect(cache.resolvePath('11:22:33:44:55:66', uuid1), isNull);
    });

    test('resolveUuid returns UUID for known path', () {
      expect(cache.resolveUuid(addr, path1),
             equals(uuid1.toLowerCase()));
    });
  });

  // ── invalidate ───────────────────────────────────────────────────────────
  group('invalidate', () {
    test('invalidate removes single device', () {
      cache.populatePathsOnly(addr, [path1]);
      cache.populatePathsOnly('11:22:33:44:55:66', [path2]);
      cache.invalidate(addr);
      expect(cache.isCached(addr), isFalse);
      expect(cache.isCached('11:22:33:44:55:66'), isTrue);
    });

    test('invalidateAll clears everything', () {
      cache.populatePathsOnly(addr, [path1]);
      cache.populatePathsOnly('11:22:33:44:55:66', [path2]);
      cache.invalidateAll();
      expect(cache.cachedDeviceCount, equals(0));
    });

    test('allPaths returns empty after invalidate', () {
      cache.populatePathsOnly(addr, [path1]);
      cache.invalidate(addr);
      expect(cache.allPaths(addr), isEmpty);
    });
  });

  // ── GattServiceMap.isEmpty ───────────────────────────────────────────────
  test('isEmpty true when no characteristics', () {
    final m = cache.populatePathsOnly(addr, []);
    expect(m.isEmpty, isTrue);
  });

  // ── GattCharacteristic.toString() ────────────────────────────────────────
  test('GattCharacteristic.toString contains uuid and flags', () {
    final c = GattCharacteristic(
      objectPath:        path1,
      uuid:              uuid1,
      serviceObjectPath: '/svc',
      serviceUuid:       uuid1,
      flags:             const ['read', 'notify'],
    );
    expect(c.toString(), contains(uuid1));
    expect(c.toString(), contains('read'));
  });
}

// ── Helper ──────────────────────────────────────────────────────────────────

CharInfo _charInfo(String uuid,
    {required String svcUuid,
     required String svcPath,
     required List<String> flags}) =>
    CharInfo(uuid: uuid, serviceObjectPath: svcPath,
             serviceUuid: svcUuid, flags: flags);
