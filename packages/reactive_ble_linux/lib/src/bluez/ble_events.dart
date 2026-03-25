// lib/src/ble_events.dart — Pure-Dart decoder for the kExternalTypedData
// wire format defined in include/bluez_ble.h.
//
// Zero additional copies: decodes directly from the Uint8List whose backing
// store is the C++ malloc allocation (transferred to Dart via
// Dart_PostCObject_DL kExternalTypedData).

import 'dart:convert';
import 'dart:typed_data';
import 'ble_types.dart';

// ── Public decoder ────────────────────────────────────────────────────────

/// Decode a raw [Uint8List] posted by C++ into a [BleEvent].
/// Returns [null] for unknown or truncated payloads.
BleEvent? decodeBleEvent(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final type = bytes[0].asEventType;

  return switch (type) {
    BleEventType.adapterState => _decodeAdapterState(bytes),
    BleEventType.scanResult   => _decodeScanResult(bytes),
    BleEventType.connection   => _decodeConnection(bytes),
    BleEventType.charNotify   => _decodeCharData(bytes, BleEventType.charNotify),
    BleEventType.charRead     => _decodeCharData(bytes, BleEventType.charRead),
    BleEventType.charWrite    => _decodeCharWrite(bytes),
    BleEventType.error        => _decodeError(bytes),
    _                         => null,
  };
}

// ── Private decoders ───────────────────────────────────────────────────────

BleEvent? _decodeAdapterState(Uint8List b) {
  if (b.length < 4) return null;
  return BleAdapterStateEvent(BleAdapterState(
    powered:     b[1] != 0,
    discovering: b[2] != 0,
  ));
}

// BLE_EVT_SCAN_RESULT wire layout (variable):
//   [0]      type
//   [1..6]   BD address (6 bytes)
//   [7]      address_type
//   [8]      rssi (int8)
//   [9..10]  name_len (uint16 LE)
//   [11 .. 10+name_len]  name UTF-8
//   base = 11 + name_len
//   [base]      mfr_company_lo
//   [base+1]    mfr_company_hi
//   [base+2]    mfr_len
//   [base+3 .. base+2+mfr_len] mfr data
//   next = base+3+mfr_len
//   [next]      uuid_count
//   [next+1 ..] uuid_count * 16 bytes
BleEvent? _decodeScanResult(Uint8List b) {
  if (b.length < 11) return null;
  final bd = ByteData.sublistView(b);

  final addr = _formatAddr(b.sublist(1, 7));
  final addrType = b[7] == 0 ? BleAddressType.public : BleAddressType.random;
  final rssi = b[8].toSigned(8);

  final nameLen = bd.getUint16(9, Endian.little);
  if (b.length < 11 + nameLen) return null;
  final name = utf8.decode(b.sublist(11, 11 + nameLen));

  int off = 11 + nameLen;
  if (b.length < off + 3) return null;
  final mfrCompany = bd.getUint16(off, Endian.little);
  final mfrLen     = b[off + 2];
  off += 3;
  if (b.length < off + mfrLen) return null;
  final mfrData = Uint8List.fromList(b.sublist(off, off + mfrLen));
  off += mfrLen;

  if (b.length < off + 1) return null;
  final uuidCount = b[off++];
  if (b.length < off + uuidCount * 16) return null;

  final uuids = <String>[];
  for (var i = 0; i < uuidCount; i++) {
    uuids.add(_formatUuid128(b.sublist(off, off + 16)));
    off += 16;
  }

  return BleScanResultEvent(BleScanResult(
    address:               addr,
    addressType:           addrType,
    rssi:                  rssi,
    name:                  name,
    serviceUuids:          uuids,
    manufacturerCompanyId: mfrCompany,
    manufacturerData:      mfrData,
  ));
}

// BLE_EVT_CONNECTION (10 bytes)
BleEvent? _decodeConnection(Uint8List b) {
  if (b.length < 10) return null;
  final addr  = _formatAddr(b.sublist(1, 7));
  final state = switch (b[7]) {
    0 => BleConnectionState.disconnected,
    1 => BleConnectionState.connecting,
    2 => BleConnectionState.connected,
    3 => BleConnectionState.disconnecting,
    _ => BleConnectionState.disconnected,
  };
  return BleConnectionEvent2(BleConnectionEvent(
    address:   addr,
    state:     state,
    errorCode: b[8],
  ));
}

// BLE_EVT_CHAR_NOTIFY / BLE_EVT_CHAR_READ
// [0]      type
// [1..8]   request_id (int64 LE)
// [9]      error_code
// [10..11] char_path_len (uint16 LE)
// [12 .. 12+path_len-1] char_path
// [12+path_len .. 13+path_len] data_len (uint16 LE)
// [14+path_len ..] data
BleEvent? _decodeCharData(Uint8List b, BleEventType type) {
  if (b.length < 14) return null;
  final bd = ByteData.sublistView(b);

  final reqId    = bd.getInt64(1, Endian.little);
  final errCode  = b[9];
  final pathLen  = bd.getUint16(10, Endian.little);
  if (b.length < 12 + pathLen + 2) return null;
  final path     = utf8.decode(b.sublist(12, 12 + pathLen));
  final dataLen  = bd.getUint16(12 + pathLen, Endian.little);
  final dataOff  = 14 + pathLen;
  if (b.length < dataOff + dataLen) return null;
  final data     = Uint8List.fromList(b.sublist(dataOff, dataOff + dataLen));

  return BleCharDataEvent(BleCharEvent(
    eventType: type,
    requestId: reqId,
    charPath:  path,
    errorCode: errCode,
    data:      data,
  ));
}

// BLE_EVT_CHAR_WRITE
// [0]      type
// [1..8]   request_id (int64 LE)
// [9]      error_code
// [10..11] char_path_len (uint16 LE)
// [12 ..] char_path
BleEvent? _decodeCharWrite(Uint8List b) {
  if (b.length < 12) return null;
  final bd      = ByteData.sublistView(b);
  final reqId   = bd.getInt64(1, Endian.little);
  final errCode = b[9];
  final pathLen = bd.getUint16(10, Endian.little);
  if (b.length < 12 + pathLen) return null;
  final path    = utf8.decode(b.sublist(12, 12 + pathLen));

  return BleCharDataEvent(BleCharEvent(
    eventType: BleEventType.charWrite,
    requestId: reqId,
    charPath:  path,
    errorCode: errCode,
    data:      Uint8List(0),
  ));
}

// BLE_EVT_ERROR
BleEvent? _decodeError(Uint8List b) {
  if (b.length < 3) return null;
  final bd      = ByteData.sublistView(b);
  final msgLen  = bd.getUint16(1, Endian.little);
  if (b.length < 3 + msgLen) return null;
  final message = utf8.decode(b.sublist(3, 3 + msgLen));
  return BleErrorEvent(BleError(message));
}

// ── Formatting helpers ────────────────────────────────────────────────────

String _formatAddr(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

String _formatUuid128(List<int> b) {
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0,8)}-${hex.substring(8,12)}'
         '-${hex.substring(12,16)}-${hex.substring(16,20)}'
         '-${hex.substring(20)}';
}
