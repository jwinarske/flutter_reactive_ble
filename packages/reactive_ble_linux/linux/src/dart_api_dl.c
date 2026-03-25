/* dart_api_dl.c — Dart_InitializeApiDL implementation.
 *
 * CRITICAL: compile as plain C (gcc), NOT as C++ (g++).  The Dart VM exports
 * the DartApi struct with C-linkage semantics; C++ name-mangling and stricter
 * aliasing rules around void* casts cause UB if compiled as C++.
 *
 * Pattern directly from jwinarske/native_comms / Dart SDK dart_api_dl.c.
 */

#include "../include/dart_api_dl.h"
#include <string.h>

/* ── Function-pointer globals ─────────────────────────────────────────── */
Dart_PostCObject_Type     Dart_PostCObject_DL     = NULL;
Dart_NewNativePort_Type   Dart_NewNativePort_DL   = NULL;
Dart_CloseNativePort_Type Dart_CloseNativePort_DL = NULL;

/* ── Symbol table — name must match the DartApiEntry.name string exactly ─ */
/* Parameter 'sym' avoids shadowing the entry->name struct field.            */
#define DART_API_DL_SYMBOLS(F)                  \
  F(Dart_PostCObject)                           \
  F(Dart_NewNativePort)                         \
  F(Dart_CloseNativePort)

/* Use memcpy to copy the function pointer — avoids the ISO C object-pointer
 * to function-pointer cast warning (-Wpedantic).  This is the same technique
 * used in POSIX dlsym() documentation and in libffi.                        */
#define DART_API_DL_ASSIGN(sym)                                         \
  if (strcmp(#sym, entry->name) == 0) {                                 \
      sym##_Type _tmp;                                                   \
      memcpy(&_tmp, &entry->function, sizeof(_tmp));                     \
      sym##_DL = _tmp;                                                   \
      continue;                                                          \
  }

intptr_t Dart_InitializeApiDL(void* data) {
    if (data == NULL) return -1;

    const DartApi* api = (const DartApi*)data;
    if (api->major != DART_API_DL_MAJOR_VERSION) return -1;

    for (const DartApiEntry* entry = api->functions;
         entry->name != NULL;
         ++entry) {
        DART_API_DL_SYMBOLS(DART_API_DL_ASSIGN)
    }

    if (Dart_PostCObject_DL     == NULL) return -1;
    if (Dart_NewNativePort_DL   == NULL) return -1;
    if (Dart_CloseNativePort_DL == NULL) return -1;

    return 0;
}
