// dart_api_dl.h — Dynamic-linking Dart API declarations.
// Declares Dart_InitializeApiDL and the _DL function-pointer globals that
// become valid after a successful call to Dart_InitializeApiDL.
//
// Pattern from jwinarske/native_comms / Dart SDK.

#pragma once

#include "dart_api_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// ── Initialisation ────────────────────────────────────────────────────────
// Call once from Dart via:
//   comms_init(NativeApi.initializeApiDLData)
// Returns 0 on success, -1 on API version mismatch.
intptr_t Dart_InitializeApiDL(void* data);

// ── Function-pointer globals (set by Dart_InitializeApiDL) ───────────────
// Post a Dart_CObject to a port; safe from any thread after init.
typedef bool (*Dart_PostCObject_Type)(Dart_Port port_id, Dart_CObject* message);
extern Dart_PostCObject_Type Dart_PostCObject_DL;

typedef Dart_Port (*Dart_NewNativePort_Type)(const char*    name,
                                             void*          handler,
                                             bool           handle_concurrently);
extern Dart_NewNativePort_Type Dart_NewNativePort_DL;

typedef bool (*Dart_CloseNativePort_Type)(Dart_Port native_port_id);
extern Dart_CloseNativePort_Type Dart_CloseNativePort_DL;

#ifdef __cplusplus
}
#endif
