cmake_minimum_required(VERSION 3.20)
project(dart_bluez_ble VERSION 1.0.0 LANGUAGES C CXX)

# ── Compiler requirements ──────────────────────────────────────────────────
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Dependencies ───────────────────────────────────────────────────────────
find_package(PkgConfig REQUIRED)

# sdbus-cpp >= 2.0 (system install: libsdbus-c++-dev)
pkg_check_modules(SDBUS REQUIRED IMPORTED_TARGET sdbus-c++)

# Dart SDK headers (optional; bundled copies used if not found)
if(DEFINED DART_SDK)
  set(DART_INCLUDE_DIR "${DART_SDK}/include")
  message(STATUS "Using Dart SDK headers from ${DART_INCLUDE_DIR}")
else()
  set(DART_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")
  message(STATUS "Using bundled dart_api headers from ${DART_INCLUDE_DIR}")
endif()

# ── dart_api_dl.c — MUST be compiled as plain C ────────────────────────────
add_library(dart_api_dl_obj OBJECT src/dart_api_dl.c)
target_include_directories(dart_api_dl_obj PRIVATE ${DART_INCLUDE_DIR})
target_compile_options(dart_api_dl_obj PRIVATE -O2 -fPIC -Wall -Wextra)

# ── bluez_ble.cpp — C++23 ─────────────────────────────────────────────────
add_library(bluez_ble_obj OBJECT src/bluez_ble.cpp)
target_include_directories(bluez_ble_obj PRIVATE
    ${DART_INCLUDE_DIR}
    include
)
target_compile_options(bluez_ble_obj PRIVATE
    -O2
    -fPIC
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
)
# fcoroutines not needed for this file but harmless
target_compile_options(bluez_ble_obj PRIVATE -fcoroutines)
target_link_libraries(bluez_ble_obj PRIVATE PkgConfig::SDBUS)

# ── Shared library ─────────────────────────────────────────────────────────
add_library(dart_bluez_ble SHARED
    $<TARGET_OBJECTS:dart_api_dl_obj>
    $<TARGET_OBJECTS:bluez_ble_obj>
)
target_link_libraries(dart_bluez_ble PRIVATE
    PkgConfig::SDBUS
    pthread
)
set_target_properties(dart_bluez_ble PROPERTIES
    OUTPUT_NAME "dart_bluez_ble"
    SOVERSION 1
    # Ensure only extern "C" symbols are visible
    C_VISIBILITY_PRESET   hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    # Install .so next to the Dart lib/
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
)

# ── Verification target ────────────────────────────────────────────────────
add_custom_target(verify
    COMMAND nm -D --defined-only "$<TARGET_FILE:dart_bluez_ble>"
              | grep " T " | sort
    COMMAND size "$<TARGET_FILE:dart_bluez_ble>"
    DEPENDS dart_bluez_ble
    COMMENT "Exported symbols and section sizes"
    VERBATIM
)

# ── Install ────────────────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS dart_bluez_ble
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(FILES include/bluez_ble.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
