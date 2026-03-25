# Makefile — dart_bluez_ble shared library
# Mirrors the pattern from jwinarske/native_comms.
#
# Usage:
#   make                     # build lib/libdart_bluez_ble.so
#   make DART_SDK=/usr/lib/dart   # use official Dart SDK headers
#   make verify              # show exported symbols + section sizes
#   make clean

CXX      ?= g++
CC       ?= gcc
DART_SDK ?=

CFLAGS   = -O2 -fPIC -Wall -Wextra
CXXFLAGS = -std=c++23 -O2 -fPIC -fvisibility=hidden \
           -Wall -Wextra -Wpedantic -Wno-unused-parameter \
           -fcoroutines

# Prefer system sdbus-c++; fall back to bundled submodule
SDBUS_CFLAGS  := $(shell pkg-config --cflags sdbus-c++ 2>/dev/null)
SDBUS_LIBS    := $(shell pkg-config --libs   sdbus-c++ 2>/dev/null)

ifeq ($(SDBUS_LIBS),)
  $(info System sdbus-c++ not found — using bundled submodule. Run CMake for full submodule build.)
  SDBUS_SUBMOD  = third_party/sdbus-cpp
  SDBUS_CFLAGS  = -I$(SDBUS_SUBMOD)/include
  # When using the submodule, CMake must be used to build sdbus-cpp first.
  # The Makefile will compile bluez_ble.cpp with the submodule headers but
  # linking requires the static lib built by CMake.
  SDBUS_LIBS    = -L$(SDBUS_SUBMOD)/build -lsdbus-c++ -lsystemd
endif

ifneq ($(DART_SDK),)
DART_INC = -I$(DART_SDK)/include
else
DART_INC = -Iinclude
endif

INCLUDES = $(DART_INC) -Iinclude $(SDBUS_CFLAGS)

OBJS = build/dart_api_dl.o build/bluez_ble.o
LIB  = lib/libdart_bluez_ble.so

.PHONY: all verify clean

all: $(LIB)

build/dart_api_dl.o: src/dart_api_dl.c include/dart_api_dl.h include/dart_api_types.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(DART_INC) -Iinclude -c $< -o $@

build/bluez_ble.o: src/bluez_ble.cpp include/bluez_ble.h include/dart_api_dl.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(LIB): $(OBJS)
	@mkdir -p lib
	$(CXX) -shared -pthread $(SDBUS_LIBS) -o $@ $(OBJS)
	@echo "Built: $@"

verify: $(LIB)
	@echo "=== Exported symbols ==="
	@nm -D --defined-only $(LIB) | grep " T " | sort
	@echo ""
	@echo "=== Section sizes ==="
	@size $(LIB)

clean:
	rm -rf build lib/libdart_bluez_ble.so
