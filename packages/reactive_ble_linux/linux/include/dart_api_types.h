// dart_api_types.h — Minimal stable C ABI types from dart_api.h
// Layout-identical to Dart SDK 3.x.  Kept as plain C for inclusion from
// both dart_api_dl.c (compiled as C) and bluez_ble.cpp (compiled as C++23).
//
// Source: reproduced from jwinarske/native_comms / Dart SDK DART_API_DL_MAJOR_VERSION 2

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#if defined(__STDC__) || defined(__cplusplus)
#  define DART_EXTERN_C extern
#  ifdef __cplusplus
#    undef  DART_EXTERN_C
#    define DART_EXTERN_C extern "C"
#  endif
#endif

typedef int64_t  Dart_Port;
typedef uint64_t Dart_Port_DL;  // unused; keep for ABI parity

// ── Dart_CObject ──────────────────────────────────────────────────────────
typedef enum {
    Dart_CObject_kNull = 0,
    Dart_CObject_kBool,
    Dart_CObject_kInt32,
    Dart_CObject_kInt64,
    Dart_CObject_kDouble,
    Dart_CObject_kString,
    Dart_CObject_kArray,
    Dart_CObject_kTypedData,
    Dart_CObject_kExternalTypedData,
    Dart_CObject_kSendPort,
    Dart_CObject_kCapability,
    Dart_CObject_kNativePointer,
    Dart_CObject_kUnsupported = 16,
    Dart_CObject_kNumberOfTypes,
} Dart_CObject_Type;

typedef enum {
    Dart_TypedData_kByteData = 0,
    Dart_TypedData_kInt8,
    Dart_TypedData_kUint8,
    Dart_TypedData_kUint8Clamped,
    Dart_TypedData_kInt16,
    Dart_TypedData_kUint16,
    Dart_TypedData_kInt32,
    Dart_TypedData_kUint32,
    Dart_TypedData_kInt64,
    Dart_TypedData_kUint64,
    Dart_TypedData_kFloat32,
    Dart_TypedData_kFloat64,
    Dart_TypedData_kInt32x4,
    Dart_TypedData_kFloat32x4,
    Dart_TypedData_kFloat64x2,
    Dart_TypedData_kInvalid,
} Dart_TypedData_Type;

struct _Dart_CObject;
typedef struct _Dart_CObject Dart_CObject;

typedef void (*Dart_WeakPersistentHandleFinalizer)(void* isolate_callback_data,
                                                    void* peer);

struct _Dart_CObject {
    Dart_CObject_Type type;
    union {
        bool  as_bool;
        int32_t as_int32;
        int64_t as_int64;
        double  as_double;
        char*   as_string;

        struct {
            int          length;
            Dart_CObject** values;
        } as_array;

        struct {
            Dart_TypedData_Type type;
            intptr_t            length;  /* element count */
            uint8_t*            values;
        } as_typed_data;

        struct {
            Dart_TypedData_Type                type;
            intptr_t                           length;  /* element count */
            uint8_t*                           data;
            void*                              peer;
            Dart_WeakPersistentHandleFinalizer callback;
        } as_external_typed_data;

        struct {
            Dart_Port id;
            Dart_Port origin_id;
        } as_send_port;

        struct {
            int64_t id;
        } as_capability;

        struct {
            intptr_t                           ptr;
            intptr_t                           size;
            Dart_WeakPersistentHandleFinalizer callback;
        } as_native_pointer;
    } value;
};

// ── DartApi DL init ───────────────────────────────────────────────────────
#define DART_API_DL_MAJOR_VERSION 2
#define DART_API_DL_MINOR_VERSION 2

typedef struct {
    const char* name;
    void*       function;
} DartApiEntry;

typedef struct {
    uint32_t          major;
    uint32_t          minor;
    const DartApiEntry* functions;
} DartApi;
