// test/ble_events_test.dart — Pure-Dart unit tests for the wire-protocol
// decoder in lib/src/ble_events.dart.
//
// These tests run without the native .so — they only exercise the Dart-side
// ByteData parsing logic (decodeBleEvent).
//
// Run:
//   dart test test/ble_events_test.dart

import 'dart:typed_data';
import 'package:test/test.dart';

// Import the library under test directly via relative path so the test
// can run without building the shared library.
import 'package:reactive_ble_linux/src/bluez/ble_events.dart';
import 'package:reactive_ble_linux/src/bluez/ble_types.dart';

void main() {
  group('decodeBleEvent', () {
    // ── BLE_EVT_ADAPTER_STATE ───────────────────────────────────────────
    group('adapterState', () {
      test('powered=true discovering=false', () {
        final bytes = Uint8List.fromList([0x01, 0x01, 0x00, 0x00]);
        final event = decodeBleEvent(bytes);
        expect(event, isA<BleAdapterStateEvent>());
        final e = event as BleAdapterStateEvent;
        expect(e.state.powered, isTrue);
        expect(e.state.discovering, isFalse);
      });

      test('powered=false discovering=true', () {
        final bytes = Uint8List.fromList([0x01, 0x00, 0x01, 0x00]);
        final event = decodeBleEvent(bytes)! as BleAdapterStateEvent;
        expect(event.state.powered, isFalse);
        expect(event.state.discovering, isTrue);
      });

      test('truncated returns null', () {
        expect(decodeBleEvent(Uint8List.fromList([0x01, 0x01])), isNull);
      });
    });

    // ── BLE_EVT_CONNECTION ──────────────────────────────────────────────
    group('connection', () {
      test('connected state', () {
        final addr  = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];
        final bytes = Uint8List.fromList(
            [0x03, ...addr, 2 /*connected*/, 0 /*no error*/, 0]);
        final event = decodeBleEvent(bytes)! as BleConnectionEvent2;
        expect(event.event.address,   equals('AA:BB:CC:DD:EE:FF'));
        expect(event.event.state,     equals(BleConnectionState.connected));
        expect(event.event.errorCode, equals(0));
        expect(event.event.isConnected, isTrue);
      });

      test('disconnected with error', () {
        final addr  = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66];
        final bytes = Uint8List.fromList(
            [0x03, ...addr, 0 /*disconnected*/, 1 /*timeout*/, 0]);
        final event = decodeBleEvent(bytes)! as BleConnectionEvent2;
        expect(event.event.state,     equals(BleConnectionState.disconnected));
        expect(event.event.hasError,  isTrue);
      });
    });

    // ── BLE_EVT_SCAN_RESULT ─────────────────────────────────────────────
    group('scanResult', () {
      Uint8List buildScanResult({
        List<int> addr = const [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
        int addrType   = 0,
        int rssi       = 0xC8, // -56 as signed int8
        String name    = 'TestDevice',
        int mfrCompany = 0x004C,
        List<int> mfrData = const [0x01, 0x02],
        List<String> uuids = const [],
      }) {
        final nameBytes = name.codeUnits;
        final mfrLen    = mfrData.length;
        final uuidCount = uuids.length;

        final buf = <int>[
          0x02,                         // type
          ...addr,                      // [1..6]
          addrType,                     // [7]
          rssi,                         // [8]
          nameBytes.length & 0xFF,      // [9]  name_len lo
          nameBytes.length >> 8,        // [10] name_len hi
          ...nameBytes,
          mfrCompany & 0xFF,
          mfrCompany >> 8,
          mfrLen,
          ...mfrData,
          uuidCount,
        ];

        for (final uuid in uuids) {
          // Pack UUID string into 16 bytes
          final hex = uuid.replaceAll('-', '');
          for (var i = 0; i < 16; i++) {
            final hi = _hexNibble(hex[i * 2]);
            final lo = _hexNibble(hex[i * 2 + 1]);
            buf.add((hi << 4) | lo);
          }
        }

        return Uint8List.fromList(buf);
      }

      test('basic scan result with name and mfr data', () {
        final bytes = buildScanResult();
        final event = decodeBleEvent(bytes)! as BleScanResultEvent;
        expect(event.result.address, equals('01:02:03:04:05:06'));
        expect(event.result.name,    equals('TestDevice'));
        expect(event.result.rssi,    equals(-56)); // 0xC8 as int8
        expect(event.result.manufacturerCompanyId, equals(0x004C));
        expect(event.result.manufacturerData, equals([0x01, 0x02]));
        expect(event.result.serviceUuids, isEmpty);
      });

      test('address type random', () {
        final bytes = buildScanResult(addrType: 1);
        final event = decodeBleEvent(bytes)! as BleScanResultEvent;
        expect(event.result.addressType, equals(BleAddressType.random));
      });

      test('with service UUID', () {
        const uuid = '0000180d-0000-1000-8000-00805f9b34fb';
        final bytes = buildScanResult(uuids: [uuid]);
        final event = decodeBleEvent(bytes)! as BleScanResultEvent;
        expect(event.result.serviceUuids.length, equals(1));
        expect(event.result.serviceUuids.first.toLowerCase(),
               equals(uuid));
      });

      test('empty name', () {
        final bytes = buildScanResult(name: '');
        final event = decodeBleEvent(bytes)! as BleScanResultEvent;
        expect(event.result.name, isEmpty);
      });

      test('truncated returns null', () {
        expect(decodeBleEvent(Uint8List.fromList([0x02, 0x01])), isNull);
      });
    });

    // ── BLE_EVT_CHAR_NOTIFY ─────────────────────────────────────────────
    group('charNotify', () {
      Uint8List buildCharData(int type, int reqId, String path,
                               List<int> data, int errCode) {
        final pathBytes = path.codeUnits;
        final buf = <int>[
          type,
          // reqId little-endian 8 bytes
          reqId & 0xFF, (reqId >> 8) & 0xFF, (reqId >> 16) & 0xFF,
          (reqId >> 24) & 0xFF, 0, 0, 0, 0,
          errCode,
          pathBytes.length & 0xFF, pathBytes.length >> 8,
          ...pathBytes,
          data.length & 0xFF, data.length >> 8,
          ...data,
        ];
        return Uint8List.fromList(buf);
      }

      test('unsolicited notification (reqId=0)', () {
        const path = '/org/bluez/hci0/dev_AA_BB_CC/service0001/char0002';
        final bytes = buildCharData(0x04, 0, path, [0xDE, 0xAD], 0);
        final event = decodeBleEvent(bytes)! as BleCharDataEvent;
        expect(event.event.eventType, equals(BleEventType.charNotify));
        expect(event.event.requestId, equals(0));
        expect(event.event.charPath,  equals(path));
        expect(event.event.errorCode, equals(0));
        expect(event.event.data,      equals([0xDE, 0xAD]));
      });

      test('read result with non-zero requestId', () {
        const path = '/org/bluez/hci0/dev_AA/char0001';
        final bytes = buildCharData(0x05, 42, path, [0xFF], 0);
        final event = decodeBleEvent(bytes)! as BleCharDataEvent;
        expect(event.event.eventType, equals(BleEventType.charRead));
        expect(event.event.requestId, equals(42));
        expect(event.event.isSuccess, isTrue);
      });

      test('read error', () {
        const path = '/org/bluez/hci0/dev_AA/char0001';
        final bytes = buildCharData(0x05, 7, path, [], 1);
        final event = decodeBleEvent(bytes)! as BleCharDataEvent;
        expect(event.event.isSuccess, isFalse);
        expect(event.event.errorCode, equals(1));
        expect(event.event.data,      isEmpty);
      });
    });

    // ── BLE_EVT_CHAR_WRITE ──────────────────────────────────────────────
    group('charWrite', () {
      test('write ack success', () {
        const path      = '/org/bluez/hci0/dev_CC/char0003';
        final pathBytes = path.codeUnits;
        final buf = <int>[
          0x06,
          99, 0, 0, 0, 0, 0, 0, 0,  // reqId = 99
          0,                         // errCode = 0
          pathBytes.length & 0xFF, pathBytes.length >> 8,
          ...pathBytes,
        ];
        final event = decodeBleEvent(Uint8List.fromList(buf))! as BleCharDataEvent;
        expect(event.event.eventType, equals(BleEventType.charWrite));
        expect(event.event.requestId, equals(99));
        expect(event.event.isSuccess, isTrue);
        expect(event.event.charPath,  equals(path));
      });
    });

    // ── BLE_EVT_ERROR ───────────────────────────────────────────────────
    group('error', () {
      test('error message decoded', () {
        const msg   = 'org.bluez.Error.NotReady';
        final msgB  = msg.codeUnits;
        final buf   = <int>[
          0xFF,
          msgB.length & 0xFF, msgB.length >> 8,
          ...msgB,
        ];
        final event = decodeBleEvent(Uint8List.fromList(buf))! as BleErrorEvent;
        expect(event.error.message, equals(msg));
      });

      test('empty message', () {
        final buf   = <int>[0xFF, 0x00, 0x00];
        final event = decodeBleEvent(Uint8List.fromList(buf))! as BleErrorEvent;
        expect(event.error.message, isEmpty);
      });
    });

    // ── Edge cases ──────────────────────────────────────────────────────
    group('edge cases', () {
      test('empty bytes returns null', () {
        expect(decodeBleEvent(Uint8List(0)), isNull);
      });

      test('unknown type byte returns null', () {
        expect(decodeBleEvent(Uint8List.fromList([0x77])), isNull);
      });
    });
  });
}

// ── helpers ───────────────────────────────────────────────────────────────
int _hexNibble(String c) {
  final code = c.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return 0;
}
