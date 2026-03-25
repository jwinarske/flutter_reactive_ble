// lib/src/ble_types.dart — BLE domain types for the Dart public API.

import 'dart:typed_data';

// ── Enumerations ─────────────────────────────────────────────────────────

enum BleConnectionState { disconnected, connecting, connected, disconnecting }

enum BleAddressType { public, random }

enum BleEventType {
  adapterState, // BLE_EVT_ADAPTER_STATE
  scanResult,   // BLE_EVT_SCAN_RESULT
  connection,   // BLE_EVT_CONNECTION
  charNotify,   // BLE_EVT_CHAR_NOTIFY
  charRead,     // BLE_EVT_CHAR_READ
  charWrite,    // BLE_EVT_CHAR_WRITE
  error,        // BLE_EVT_ERROR
  unknown,
}

extension BleEventTypeX on int {
  BleEventType get asEventType => switch (this) {
    0x01 => BleEventType.adapterState,
    0x02 => BleEventType.scanResult,
    0x03 => BleEventType.connection,
    0x04 => BleEventType.charNotify,
    0x05 => BleEventType.charRead,
    0x06 => BleEventType.charWrite,
    0xFF => BleEventType.error,
    _    => BleEventType.unknown,
  };
}

// ── Domain classes ────────────────────────────────────────────────────────

/// A Bluetooth Low Energy device discovered during scanning.
final class BleScanResult {
  const BleScanResult({
    required this.address,
    required this.addressType,
    required this.rssi,
    required this.name,
    required this.serviceUuids,
    required this.manufacturerCompanyId,
    required this.manufacturerData,
  });

  final String          address;            // "XX:XX:XX:XX:XX:XX"
  final BleAddressType  addressType;
  final int             rssi;               // dBm
  final String          name;               // may be empty
  final List<String>    serviceUuids;       // 128-bit UUID strings
  final int             manufacturerCompanyId; // 0xFFFF if absent
  final Uint8List       manufacturerData;

  @override
  String toString() =>
      'BleScanResult(addr=$address, name=${name.isEmpty ? "<anon>" : name}, '
      'rssi=$rssi dBm, uuids=${serviceUuids.length})';
}

/// Connection state event for a device.
final class BleConnectionEvent {
  const BleConnectionEvent({
    required this.address,
    required this.state,
    required this.errorCode,
  });

  final String            address;
  final BleConnectionState state;
  final int               errorCode; // 0 = none

  bool get isConnected    => state == BleConnectionState.connected;
  bool get isDisconnected => state == BleConnectionState.disconnected;
  bool get hasError       => errorCode != 0;

  @override
  String toString() =>
      'BleConnectionEvent(addr=$address, state=$state, err=$errorCode)';
}

/// Adapter power/discovery state.
final class BleAdapterState {
  const BleAdapterState({
    required this.powered,
    required this.discovering,
  });

  final bool powered;
  final bool discovering;

  @override
  String toString() =>
      'BleAdapterState(powered=$powered, discovering=$discovering)';
}

/// A GATT characteristic data event (notification, indication, or read result).
final class BleCharEvent {
  const BleCharEvent({
    required this.eventType,
    required this.requestId,
    required this.charPath,
    required this.errorCode,
    required this.data,
  });

  final BleEventType eventType; // charNotify | charRead | charWrite
  final int          requestId; // 0 for unsolicited notifications
  final String       charPath;  // D-Bus object path
  final int          errorCode; // 0 = success
  final Uint8List    data;      // empty for charWrite ack

  bool get isSuccess => errorCode == 0;

  @override
  String toString() =>
      'BleCharEvent($eventType, path=$charPath, '
      'req=$requestId, err=$errorCode, ${data.length} bytes)';
}

/// Unrecoverable error from the C++ layer.
final class BleError {
  const BleError(this.message);
  final String message;
  @override
  String toString() => 'BleError($message)';
}

/// Union of all possible event types posted via the event port.
sealed class BleEvent {}

final class BleAdapterStateEvent extends BleEvent {
  BleAdapterStateEvent(this.state);
  final BleAdapterState state;
}

final class BleScanResultEvent extends BleEvent {
  BleScanResultEvent(this.result);
  final BleScanResult result;
}

final class BleConnectionEvent2 extends BleEvent {
  BleConnectionEvent2(this.event);
  final BleConnectionEvent event;
}

final class BleCharDataEvent extends BleEvent {
  BleCharDataEvent(this.event);
  final BleCharEvent event;
}

final class BleErrorEvent extends BleEvent {
  BleErrorEvent(this.error);
  final BleError error;
}

// ── BleException ─────────────────────────────────────────────────────────

class BleException implements Exception {
  const BleException(this.message);
  final String message;
  @override
  String toString() => 'BleException: $message';
}
