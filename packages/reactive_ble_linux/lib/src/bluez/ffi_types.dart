// lib/src/ffi_types.dart — Dart FFI Struct mirrors for bluez_ble.h types.
//
// Only opaque handles are needed here; the wire format is a Uint8List
// decoded in ble_events.dart, so no layout-sensitive Struct is required
// for the event payloads.

import 'dart:ffi';

// ── Opaque handles ────────────────────────────────────────────────────────

/// Opaque handle to the SPSC notification ring (BleNotifRing* in C++).
final class BleNotifRingOpaque extends Opaque {}

// ── BleNotifDesc (BleNotifRing slot returned by bluez_ble_ring_pop) ────────
// ring_pop fills three out-pointers; we model them as Pointer<Pointer<X>>.
// No Struct needed — the Dart wrappers allocate via arena.
