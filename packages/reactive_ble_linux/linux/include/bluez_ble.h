// bluez_ble.h — C ABI for the Dart↔BlueZ BLE bridge.
//
// Architecture:
//   Dart (ffi) ──── Channel A ────▶ C++ (sync call: scan start/stop,
//                                        connect, read, write, subscribe)
//   C++ ────────── Channel B ────▶ Dart (async events via
//                                        Dart_PostCObject_DL kExternalTypedData)
//   C++ ────────── Channel C ────▶ Dart (high-frequency GATT notifications
//                                        via SPSC ring, Dart polls via timer)
//
// All event payloads are malloc'd by C++ and freed by the Dart GC via the
// kExternalTypedData finalizer (ble_event_finalizer).  Zero copy.
//
// Build: CMake (preferred) or Makefile.  Requires sdbus-cpp >= 2.0 and
// GCC 13+ (-std=c++23 -fcoroutines).

#pragma once

#include <stdint.h>
#include <stddef.h>

// Symbol visibility: export all C ABI functions even with -fvisibility=hidden
#if defined(__GNUC__) || defined(__clang__)
  #define BLE_EXPORT __attribute__((visibility("default")))
#else
  #define BLE_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ── Wire types ────────────────────────────────────────────────────────────
// Every event is a kExternalTypedData Uint8List posted to the Dart event
// port.  The first byte identifies the event type.

#define BLE_EVT_ADAPTER_STATE  0x01u  // adapter powered / discovering
#define BLE_EVT_SCAN_RESULT    0x02u  // device advertised
#define BLE_EVT_CONNECTION     0x03u  // connection state change
#define BLE_EVT_CHAR_NOTIFY    0x04u  // GATT characteristic notification
#define BLE_EVT_CHAR_READ      0x05u  // ReadValue result
#define BLE_EVT_CHAR_WRITE     0x06u  // WriteValue ack
#define BLE_EVT_ERROR          0xFFu  // unrecoverable error

// BLE_EVT_ADAPTER_STATE layout (fixed 4 bytes):
//   [0]   BLE_EVT_ADAPTER_STATE
//   [1]   powered   : 0|1
//   [2]   discovering : 0|1
//   [3]   reserved

// BLE_EVT_SCAN_RESULT layout (variable):
//   [0]      BLE_EVT_SCAN_RESULT
//   [1..6]   BD address (6 bytes, byte order as received from BlueZ)
//   [7]      address_type  (0=public, 1=random)
//   [8]      rssi (int8 cast to uint8)
//   [9..10]  name_len (uint16_t LE)
//   [11 .. 10+name_len]  name UTF-8
//   base = 11 + name_len
//   [base]      mfr_data_company_lo (uint8)
//   [base+1]    mfr_data_company_hi (uint8)  -- 0xFF 0xFF if absent
//   [base+2]    mfr_data_len (uint8)
//   [base+3 .. base+2+mfr_data_len]  manufacturer specific data
//   next = base+3+mfr_data_len
//   [next]      service_uuid_count (uint8)
//   [next+1 .. ] service_uuid_count * 16 bytes (128-bit UUIDs, LE)

// BLE_EVT_CONNECTION layout (fixed 10 bytes):
//   [0]    BLE_EVT_CONNECTION
//   [1..6] BD address
//   [7]    state: 0=disconnected, 1=connecting, 2=connected, 3=disconnecting
//   [8]    error_code  (0=none, 1=timeout, 2=refused, 3=unknown)
//   [9]    reserved

// BLE_EVT_CHAR_NOTIFY layout (variable):
//   [0]      BLE_EVT_CHAR_NOTIFY
//   [1..8]   request_id (int64_t LE; 0 for unsolicited notifications)
//   [9]      error_code (0=none)
//   [10..11] char_path_len (uint16_t LE) — D-Bus object path length
//   [12 .. 12+char_path_len-1]  char_path (no NUL terminator)
//   [12+char_path_len .. 13+char_path_len]  data_len (uint16_t LE)
//   [14+char_path_len .. ] data bytes

// BLE_EVT_CHAR_READ:  same layout as BLE_EVT_CHAR_NOTIFY
// BLE_EVT_CHAR_WRITE:
//   [0]      BLE_EVT_CHAR_WRITE
//   [1..8]   request_id (int64_t LE)
//   [9]      error_code (0=none)
//   [10..11] char_path_len (uint16_t LE)
//   [12 .. 12+char_path_len-1]  char_path

// BLE_EVT_ERROR layout (variable):
//   [0]    BLE_EVT_ERROR
//   [1..2] message_len (uint16_t LE)
//   [3..]  message UTF-8

// ── SPSC ring ─────────────────────────────────────────────────────────────
// For high-frequency GATT notifications (e.g. continuous sensors) the
// caller may use the SPSC ring directly.  Each slot holds a BleNotifDesc
// whose data* points to a C-heap allocation freed by the consumer via
// bluez_ble_free().

typedef struct {
    uint8_t* data;        // malloc'd; consumer must call bluez_ble_free()
    uint32_t data_len;
    uint32_t _pad;
    // char_path follows immediately after struct as inline string
    // (not a pointer — the allocation is sizeof+char_path_len bytes)
} BleNotifDesc;

// Opaque SPSC ring handle (same as native_comms SPSCRing pattern)
typedef struct BleNotifRing BleNotifRing;

BLE_EXPORT BleNotifRing* bluez_ble_ring_create(uint32_t capacity);  // power-of-two
BLE_EXPORT void          bluez_ble_ring_destroy(BleNotifRing* ring);
// push: takes ownership of data (caller must malloc; ring consumer frees via bluez_ble_free).
// char_path is copied internally; caller retains ownership.
// Returns true if the slot was accepted, false if the ring is full.
BLE_EXPORT bool          bluez_ble_ring_push(BleNotifRing* ring,
                                   uint8_t* data, uint32_t data_len,
                                   const char* char_path);
BLE_EXPORT bool          bluez_ble_ring_pop(BleNotifRing* ring, uint8_t** out_data,
                                  uint32_t* out_len,
                                  char** out_path);   // caller frees each
BLE_EXPORT int           bluez_ble_ring_size(BleNotifRing* ring);

// Attach a ring so C++ pushes notifications there instead of
// (or in addition to) posting them to the event port.
// char_path_prefix: only push notifs from paths starting with this prefix,
//                   or NULL for all.
BLE_EXPORT int bluez_ble_ring_attach(const char* char_path_prefix, BleNotifRing* ring);
BLE_EXPORT int bluez_ble_ring_detach(BleNotifRing* ring);

// ── Lifecycle ─────────────────────────────────────────────────────────────
// Initialize dart_api_dl bindings.  Must be called once from Dart:
//   _init(NativeApi.initializeApiDLData)
BLE_EXPORT int  bluez_ble_init(void* dart_api_dl_data);

// Shut down the D-Bus event loop, close all connections, free resources.
BLE_EXPORT void bluez_ble_shutdown(void);

// Register the Dart RawReceivePort nativePort to receive BLE events.
// Subsequent calls replace the registered port.
BLE_EXPORT int  bluez_ble_register_event_port(int64_t port_id);
BLE_EXPORT void bluez_ble_unregister_event_port(void);

// ── Adapter ───────────────────────────────────────────────────────────────
// Query whether adapter is powered; result posted as BLE_EVT_ADAPTER_STATE.
BLE_EXPORT int bluez_ble_adapter_state(void);

// Start scanning.  filter_uuids: NULL-terminated array of UUID strings or
// NULL (→ accept all).  timeout_ms: 0 = scan indefinitely.
// Returns 0 on success; scan results flow via the event port.
BLE_EXPORT int  bluez_ble_start_scan(const char** filter_uuids, uint32_t timeout_ms);
BLE_EXPORT int  bluez_ble_stop_scan(void);

// ── Device ────────────────────────────────────────────────────────────────
// address: "XX:XX:XX:XX:XX:XX"
// Connection state changes flow via the event port.
BLE_EXPORT int  bluez_ble_connect(const char* address);
BLE_EXPORT int  bluez_ble_disconnect(const char* address);

// ── GATT ──────────────────────────────────────────────────────────────────
// char_path: D-Bus object path, e.g.
//   "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0001/char0002"
// request_id: caller-chosen correlation token, echoed in the response event.

// Async read — result posted as BLE_EVT_CHAR_READ.
BLE_EXPORT int  bluez_ble_char_read(const char* char_path, int64_t request_id);

// Async write — ack posted as BLE_EVT_CHAR_WRITE.
BLE_EXPORT int  bluez_ble_char_write(const char* char_path, const uint8_t* data,
                          uint32_t len, int64_t request_id);

// Write without response (fire-and-forget, no event posted).
BLE_EXPORT int  bluez_ble_char_write_no_response(const char* char_path,
                                      const uint8_t* data, uint32_t len);

// Subscribe to notifications; values arrive as BLE_EVT_CHAR_NOTIFY.
BLE_EXPORT int  bluez_ble_char_subscribe(const char* char_path);
BLE_EXPORT int  bluez_ble_char_unsubscribe(const char* char_path);

// ── Object path discovery ─────────────────────────────────────────────────
// Enumerate all GATT characteristic object paths for a device.
// Returns a newly malloc'd NULL-terminated array of malloc'd strings.
// Caller frees with bluez_ble_free_string_list().
BLE_EXPORT char** bluez_ble_get_char_paths(const char* device_address);
BLE_EXPORT void   bluez_ble_free_string_list(char** list);

// Synchronously read UUID, service path, service UUID, and flags for a single
// characteristic.  All out-parameters are newly malloc'd strings / arrays
// that the caller frees:
//   *out_uuid          — "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (or NULL)
//   *out_service_path  — D-Bus object path of parent service (or NULL)
//   *out_service_uuid  — UUID of parent service (or NULL)
//   *out_flags         — NULL-terminated array of malloc'd flag strings
//                        e.g. {"read","notify",NULL}  (or NULL on error)
// Returns 0 on success, -1 if the path is not found or BlueZ returns an error.
BLE_EXPORT int bluez_ble_get_char_info(const char*  char_path,
                             char**       out_uuid,
                             char**       out_service_path,
                             char**       out_service_uuid,
                             char***      out_flags);

// Block until org.bluez.Device1.ServicesResolved becomes true for [address],
// or until [timeout_ms] elapses.  Returns 0 when resolved, -1 on timeout.
// Pass timeout_ms=0 to return immediately (non-blocking poll).
BLE_EXPORT int bluez_ble_wait_services_resolved(const char* address, uint32_t timeout_ms);

// Set adapter Powered property.  powered=1 turns on, 0 turns off.
BLE_EXPORT int bluez_ble_adapter_set_powered(int powered);

// Read the last known RSSI for a device.  Returns 0 if unavailable.
BLE_EXPORT int bluez_ble_read_rssi(const char* address);

// ── Utilities ─────────────────────────────────────────────────────────────
BLE_EXPORT const char* bluez_ble_version(void);
BLE_EXPORT void        bluez_ble_free(void* ptr);  // wraps free()

#ifdef __cplusplus
}
#endif
