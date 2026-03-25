// lib/src/bindings.dart — FFI function pointer lookups for libbluez_ble.so.
//
// Pattern from jwinarske/native_comms lib/src/bindings.dart.

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'ffi_types.dart';

// ── Library loading ────────────────────────────────────────────────────────

String _packageRoot() {
  // Walk up from this file: lib/src/bluez/bindings.dart → package root
  var dir = File(Platform.script.toFilePath()).parent;
  // Try to find the package by looking for the linux/lib/ directory
  // relative to common locations
  for (var i = 0; i < 10; i++) {
    final candidate = File('${dir.path}/packages/reactive_ble_linux/linux/lib/libdart_bluez_ble.so');
    if (candidate.existsSync()) return candidate.path;
    final candidate2 = File('${dir.path}/linux/lib/libdart_bluez_ble.so');
    if (candidate2.existsSync()) return candidate2.path;
    dir = dir.parent;
  }
  return '';
}

DynamicLibrary _openLib() {
  // Allow explicit override via environment variable
  final envPath = Platform.environment['BLUEZ_BLE_LIB'];

  final candidates = [
    // Explicit environment override
    if (envPath != null) envPath,
    // System-installed or LD_LIBRARY_PATH
    'libdart_bluez_ble.so',
    // Built in-tree (CMake output), resolved from script location
    _packageRoot(),
    // Common relative paths from the working directory
    './lib/libdart_bluez_ble.so',
    './libdart_bluez_ble.so',
    'packages/reactive_ble_linux/linux/lib/libdart_bluez_ble.so',
    '../packages/reactive_ble_linux/linux/lib/libdart_bluez_ble.so',
  ];
  for (final path in candidates) {
    if (path.isEmpty) continue;
    try {
      return DynamicLibrary.open(path);
    } catch (_) {}
  }
  throw UnsupportedError(
    'Could not open libdart_bluez_ble.so. '
    'Build with: cd packages/reactive_ble_linux/linux && '
    'cmake -B build -G Ninja && cmake --build build',
  );
}

final DynamicLibrary _lib = _openLib();

// ── Lifecycle ─────────────────────────────────────────────────────────────

// int bluez_ble_init(void* dart_api_dl_data)
final _bluezBleInit = _lib.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>('bluez_ble_init');

int bluezBleInit(Pointer<Void> dlData) => _bluezBleInit(dlData);

// void bluez_ble_shutdown(void)
final _bluezBleShutdown = _lib.lookupFunction<
    Void Function(),
    void Function()>('bluez_ble_shutdown');

void bluezBleShutdown() => _bluezBleShutdown();

// int bluez_ble_register_event_port(int64_t port_id)
final _bluezBleRegisterEventPort = _lib.lookupFunction<
    Int32 Function(Int64),
    int Function(int)>('bluez_ble_register_event_port');

int bluezBleRegisterEventPort(int portId) => _bluezBleRegisterEventPort(portId);

// void bluez_ble_unregister_event_port(void)
final _bluezBleUnregisterEventPort = _lib.lookupFunction<
    Void Function(),
    void Function()>('bluez_ble_unregister_event_port');

void bluezBleUnregisterEventPort() => _bluezBleUnregisterEventPort();

// ── Adapter ───────────────────────────────────────────────────────────────

// int bluez_ble_adapter_state(void)
final _bluezBleAdapterState = _lib.lookupFunction<
    Int32 Function(),
    int Function()>('bluez_ble_adapter_state');

int bluezBleAdapterState() => _bluezBleAdapterState();

// int bluez_ble_start_scan(const char** filter_uuids, uint32_t timeout_ms)
final _bluezBleStartScan = _lib.lookupFunction<
    Int32 Function(Pointer<Pointer<Char>>, Uint32),
    int Function(Pointer<Pointer<Char>>, int)>('bluez_ble_start_scan');

int bluezBleStartScan(Pointer<Pointer<Char>> uuids, int timeoutMs) =>
    _bluezBleStartScan(uuids, timeoutMs);

// int bluez_ble_stop_scan(void)
final _bluezBleStopScan = _lib.lookupFunction<
    Int32 Function(),
    int Function()>('bluez_ble_stop_scan');

int bluezBleStopScan() => _bluezBleStopScan();

// ── Device ────────────────────────────────────────────────────────────────

// int bluez_ble_connect(const char* address)
final _bluezBleConnect = _lib.lookupFunction<
    Int32 Function(Pointer<Char>),
    int Function(Pointer<Char>)>('bluez_ble_connect');

int bluezBleConnect(Pointer<Char> address) => _bluezBleConnect(address);

// int bluez_ble_disconnect(const char* address)
final _bluezBleDisconnect = _lib.lookupFunction<
    Int32 Function(Pointer<Char>),
    int Function(Pointer<Char>)>('bluez_ble_disconnect');

int bluezBleDisconnect(Pointer<Char> address) => _bluezBleDisconnect(address);

// ── GATT ──────────────────────────────────────────────────────────────────

// int bluez_ble_char_read(const char* char_path, int64_t request_id)
final _bluezBleCharRead = _lib.lookupFunction<
    Int32 Function(Pointer<Char>, Int64),
    int Function(Pointer<Char>, int)>('bluez_ble_char_read');

int bluezBleCharRead(Pointer<Char> path, int reqId) =>
    _bluezBleCharRead(path, reqId);

// int bluez_ble_char_write(const char* path, const uint8_t* data, uint32_t len, int64_t req)
final _bluezBleCharWrite = _lib.lookupFunction<
    Int32 Function(Pointer<Char>, Pointer<Uint8>, Uint32, Int64),
    int Function(Pointer<Char>, Pointer<Uint8>, int, int)>('bluez_ble_char_write');

int bluezBleCharWrite(Pointer<Char> path, Pointer<Uint8> data, int len, int reqId) =>
    _bluezBleCharWrite(path, data, len, reqId);

// int bluez_ble_char_write_no_response(...)
final _bluezBleCharWriteNoResponse = _lib.lookupFunction<
    Int32 Function(Pointer<Char>, Pointer<Uint8>, Uint32),
    int Function(Pointer<Char>, Pointer<Uint8>, int)>('bluez_ble_char_write_no_response');

int bluezBleCharWriteNoResponse(Pointer<Char> path, Pointer<Uint8> data, int len) =>
    _bluezBleCharWriteNoResponse(path, data, len);

// int bluez_ble_char_subscribe(const char* char_path)
final _bluezBleCharSubscribe = _lib.lookupFunction<
    Int32 Function(Pointer<Char>),
    int Function(Pointer<Char>)>('bluez_ble_char_subscribe');

int bluezBleCharSubscribe(Pointer<Char> path) => _bluezBleCharSubscribe(path);

// int bluez_ble_char_unsubscribe(const char* char_path)
final _bluezBleCharUnsubscribe = _lib.lookupFunction<
    Int32 Function(Pointer<Char>),
    int Function(Pointer<Char>)>('bluez_ble_char_unsubscribe');

int bluezBleCharUnsubscribe(Pointer<Char> path) => _bluezBleCharUnsubscribe(path);

// ── Object path discovery ─────────────────────────────────────────────────

// char** bluez_ble_get_char_paths(const char* device_address)
final _bluezBleGetCharPaths = _lib.lookupFunction<
    Pointer<Pointer<Char>> Function(Pointer<Char>),
    Pointer<Pointer<Char>> Function(Pointer<Char>)>('bluez_ble_get_char_paths');

Pointer<Pointer<Char>> bluezBleGetCharPaths(Pointer<Char> address) =>
    _bluezBleGetCharPaths(address);

// void bluez_ble_free_string_list(char** list)
final _bluezBleFreeStringList = _lib.lookupFunction<
    Void Function(Pointer<Pointer<Char>>),
    void Function(Pointer<Pointer<Char>>)>('bluez_ble_free_string_list');

void bluezBleFreeStringList(Pointer<Pointer<Char>> list) =>
    _bluezBleFreeStringList(list);

// int bluez_ble_get_char_info(char_path, out_uuid, out_svc_path, out_svc_uuid, out_flags)
final _bluezBleGetCharInfo = _lib.lookupFunction<
    Int32 Function(Pointer<Char>,
                   Pointer<Pointer<Char>>,
                   Pointer<Pointer<Char>>,
                   Pointer<Pointer<Char>>,
                   Pointer<Pointer<Pointer<Char>>>),
    int Function(Pointer<Char>,
                 Pointer<Pointer<Char>>,
                 Pointer<Pointer<Char>>,
                 Pointer<Pointer<Char>>,
                 Pointer<Pointer<Pointer<Char>>>)>('bluez_ble_get_char_info');

int bluezBleGetCharInfo(
    Pointer<Char> charPath,
    Pointer<Pointer<Char>> outUuid,
    Pointer<Pointer<Char>> outSvcPath,
    Pointer<Pointer<Char>> outSvcUuid,
    Pointer<Pointer<Pointer<Char>>> outFlags) =>
    _bluezBleGetCharInfo(charPath, outUuid, outSvcPath, outSvcUuid, outFlags);

// int bluez_ble_wait_services_resolved(const char* address, uint32_t timeout_ms)
final _bluezBleWaitServicesResolved = _lib.lookupFunction<
    Int32 Function(Pointer<Char>, Uint32),
    int Function(Pointer<Char>, int)>('bluez_ble_wait_services_resolved');

int bluezBleWaitServicesResolved(Pointer<Char> address, int timeoutMs) =>
    _bluezBleWaitServicesResolved(address, timeoutMs);

// int bluez_ble_adapter_set_powered(int powered)
final _bluezBleAdapterSetPowered = _lib.lookupFunction<
    Int32 Function(Int32),
    int Function(int)>('bluez_ble_adapter_set_powered');

int bluezBleAdapterSetPowered(int powered) =>
    _bluezBleAdapterSetPowered(powered);

// ── SPSC Ring ─────────────────────────────────────────────────────────────

// BleNotifRing* bluez_ble_ring_create(uint32_t capacity)
final _bluezBleRingCreate = _lib.lookupFunction<
    Pointer<BleNotifRingOpaque> Function(Uint32),
    Pointer<BleNotifRingOpaque> Function(int)>('bluez_ble_ring_create');

Pointer<BleNotifRingOpaque> bluezBleRingCreate(int capacity) =>
    _bluezBleRingCreate(capacity);

// void bluez_ble_ring_destroy(BleNotifRing* ring)
final _bluezBleRingDestroy = _lib.lookupFunction<
    Void Function(Pointer<BleNotifRingOpaque>),
    void Function(Pointer<BleNotifRingOpaque>)>('bluez_ble_ring_destroy');

void bluezBleRingDestroy(Pointer<BleNotifRingOpaque> ring) =>
    _bluezBleRingDestroy(ring);

// bool bluez_ble_ring_push(ring, data, data_len, char_path)
final _bluezBleRingPush = _lib.lookupFunction<
    Bool Function(Pointer<BleNotifRingOpaque>, Pointer<Uint8>, Uint32, Pointer<Char>),
    bool Function(Pointer<BleNotifRingOpaque>, Pointer<Uint8>, int,    Pointer<Char>)>(
        'bluez_ble_ring_push');

bool bluezBleRingPush(Pointer<BleNotifRingOpaque> ring,
                      Pointer<Uint8> data, int len,
                      Pointer<Char> charPath) =>
    _bluezBleRingPush(ring, data, len, charPath);

// bool bluez_ble_ring_pop(ring, uint8_t** data, uint32_t* len, char** path)
final _bluezBleRingPop = _lib.lookupFunction<
    Bool Function(Pointer<BleNotifRingOpaque>,
                  Pointer<Pointer<Uint8>>,
                  Pointer<Uint32>,
                  Pointer<Pointer<Char>>),
    bool Function(Pointer<BleNotifRingOpaque>,
                  Pointer<Pointer<Uint8>>,
                  Pointer<Uint32>,
                  Pointer<Pointer<Char>>)>('bluez_ble_ring_pop');

bool bluezBleRingPop(Pointer<BleNotifRingOpaque> ring,
                     Pointer<Pointer<Uint8>> data,
                     Pointer<Uint32> len,
                     Pointer<Pointer<Char>> path) =>
    _bluezBleRingPop(ring, data, len, path);

// int bluez_ble_ring_size(BleNotifRing* ring)
final _bluezBleRingSize = _lib.lookupFunction<
    Int32 Function(Pointer<BleNotifRingOpaque>),
    int Function(Pointer<BleNotifRingOpaque>)>('bluez_ble_ring_size');

int bluezBleRingSize(Pointer<BleNotifRingOpaque> ring) =>
    _bluezBleRingSize(ring);

// int bluez_ble_ring_attach(const char* prefix, BleNotifRing* ring)
final _bluezBleRingAttach = _lib.lookupFunction<
    Int32 Function(Pointer<Char>, Pointer<BleNotifRingOpaque>),
    int Function(Pointer<Char>, Pointer<BleNotifRingOpaque>)>('bluez_ble_ring_attach');

int bluezBleRingAttach(Pointer<Char> prefix, Pointer<BleNotifRingOpaque> ring) =>
    _bluezBleRingAttach(prefix, ring);

// int bluez_ble_ring_detach(BleNotifRing* ring)
final _bluezBleRingDetach = _lib.lookupFunction<
    Int32 Function(Pointer<BleNotifRingOpaque>),
    int Function(Pointer<BleNotifRingOpaque>)>('bluez_ble_ring_detach');

int bluezBleRingDetach(Pointer<BleNotifRingOpaque> ring) =>
    _bluezBleRingDetach(ring);

// ── Utilities ─────────────────────────────────────────────────────────────

// const char* bluez_ble_version(void)
final _bluezBleVersion = _lib.lookupFunction<
    Pointer<Char> Function(),
    Pointer<Char> Function()>('bluez_ble_version');

String bluezBleVersion() => _bluezBleVersion().cast<Utf8>().toDartString();

// void bluez_ble_free(void* ptr)
final _bluezBleFree = _lib.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('bluez_ble_free');

void bluezBleFree(Pointer<Void> ptr) => _bluezBleFree(ptr);
