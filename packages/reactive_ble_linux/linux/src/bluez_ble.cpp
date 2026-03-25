// bluez_ble.cpp — Dart↔BlueZ BLE bridge using sdbus-cpp v2.x + C++23.
//
// Channels:
//   A: Dart → C++ FFI (sync):  scan, connect, read, write, subscribe
//   B: C++ → Dart async:       Dart_PostCObject_DL (kExternalTypedData events)
//   C: C++ → Dart ring:        SPSC lock-free ring for high-freq notifications
//
// Requires:
//   sdbus-cpp >= 2.0  (pkg-config sdbus-c++)
//   GCC 13+  (-std=c++23 -O2 -fvisibility=hidden)
//
// Follows patterns from:
//   jwinarske/native_comms     — zero-copy FFI bridge, dart_api_dl
//   jwinarske/sdbus-cpp-examples — sdbus-cpp v2 proxy usage

#include "../include/bluez_ble.h"
#include "../include/dart_api_dl.h"

#include <sdbus-c++/sdbus-c++.h>

#include <atomic>
#include <bit>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <expected>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

// ── Compile-time constants ─────────────────────────────────────────────────
static constexpr std::string_view kBluezService   = "org.bluez";
static constexpr std::string_view kObjectRoot      = "/";
static constexpr std::string_view kAdapterPath     = "/org/bluez/hci0";
static constexpr std::string_view kObjectManager   = "org.freedesktop.DBus.ObjectManager";
static constexpr std::string_view kProperties      = "org.freedesktop.DBus.Properties";
static constexpr std::string_view kAdapter1        = "org.bluez.Adapter1";
static constexpr std::string_view kDevice1         = "org.bluez.Device1";
static constexpr std::string_view kGattChar1       = "org.bluez.GattCharacteristic1";

static constexpr char kVersion[] = "dart_bluez_ble v1.0 (C++23, sdbus-cpp v2, dart_api_dl 2.x)";

// ── SPSC Ring — one-reader / one-writer, lock-free ─────────────────────────
//   Same cache-line separation strategy as native_comms SPSCRing.
struct alignas(64) BleNotifRing {
    static constexpr uint32_t kMagic = 0xB1E1B1E1u;

    struct Slot {
        uint8_t* data;       // malloc'd payload; consumer frees
        uint32_t data_len;
        char*    char_path;  // malloc'd copy; consumer frees
    };

    uint32_t magic;
    uint32_t capacity;
    uint32_t mask;
    std::string path_prefix;  // filter; empty = all

    alignas(64) std::atomic<uint32_t> head{0};  // producer writes
    alignas(64) std::atomic<uint32_t> tail{0};  // consumer reads

    // slots[] lives in the same allocation, just after this struct
    Slot* slots() noexcept {
        return reinterpret_cast<Slot*>(
            reinterpret_cast<char*>(this) + sizeof(BleNotifRing));
    }

    bool push(uint8_t* data, uint32_t len, const char* path) noexcept {
        uint32_t h    = head.load(std::memory_order_relaxed);
        uint32_t next = (h + 1u) & mask;
        if (next == tail.load(std::memory_order_acquire)) return false; // full
        slots()[h] = { data, len, path ? strdup(path) : nullptr };
        head.store(next, std::memory_order_release);
        return true;
    }

    bool pop(uint8_t** data, uint32_t* len, char** path) noexcept {
        uint32_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire)) return false; // empty
        auto& s = slots()[t];
        *data = s.data;  *len = s.data_len;  *path = s.char_path;
        tail.store((t + 1u) & mask, std::memory_order_release);
        return true;
    }

    int size() noexcept {
        uint32_t h = head.load(std::memory_order_acquire);
        uint32_t t = tail.load(std::memory_order_acquire);
        return static_cast<int>((h - t) & mask);
    }
};

// ── Event serialisers (Channel B — C++ → Dart) ────────────────────────────
// Each helper builds a heap buffer, wraps it as kExternalTypedData, posts it
// to the registered Dart ReceivePort, and transfers ownership to the GC.

static void ble_event_finalizer(void* /*isolate_data*/, void* peer) noexcept {
    ::free(peer);
}

// Post raw bytes to Dart.  Takes ownership of `buf` (malloc'd).
static bool post_event(Dart_Port port, uint8_t* buf, size_t len) noexcept {
    Dart_CObject obj{};
    obj.type                                      = Dart_CObject_kExternalTypedData;
    obj.value.as_external_typed_data.type         = Dart_TypedData_kUint8;
    obj.value.as_external_typed_data.length       = static_cast<intptr_t>(len);
    obj.value.as_external_typed_data.data         = buf;
    obj.value.as_external_typed_data.peer         = buf;
    obj.value.as_external_typed_data.callback     = ble_event_finalizer;
    if (!Dart_PostCObject_DL(port, &obj)) {
        ::free(buf);
        return false;
    }
    return true;
}

// BLE_EVT_ADAPTER_STATE (4 bytes)
static void post_adapter_state(Dart_Port port, bool powered, bool discovering) {
    auto* buf = static_cast<uint8_t*>(::malloc(4));
    if (!buf) return;
    buf[0] = BLE_EVT_ADAPTER_STATE;
    buf[1] = powered ? 1u : 0u;
    buf[2] = discovering ? 1u : 0u;
    buf[3] = 0u;
    post_event(port, buf, 4);
}

// BLE_EVT_CONNECTION (10 bytes)
static void post_connection(Dart_Port port,
                            const uint8_t addr[6], uint8_t state, uint8_t err) {
    auto* buf = static_cast<uint8_t*>(::malloc(10));
    if (!buf) return;
    buf[0] = BLE_EVT_CONNECTION;
    ::memcpy(buf + 1, addr, 6);
    buf[7] = state;
    buf[8] = err;
    buf[9] = 0u;
    post_event(port, buf, 10);
}

// Parse "XX:XX:XX:XX:XX:XX" into 6-byte array.
static bool parse_bd_addr(std::string_view s, uint8_t out[6]) noexcept {
    if (s.size() != 17) return false;
    for (int i = 0; i < 6; ++i) {
        char hi = s[i * 3], lo = s[i * 3 + 1];
        auto h = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            return -1;
        };
        int hv = h(hi), lv = h(lo);
        if (hv < 0 || lv < 0) return false;
        out[i] = static_cast<uint8_t>(hv << 4 | lv);
    }
    return true;
}

// BLE_EVT_SCAN_RESULT (variable)
static void post_scan_result(Dart_Port port,
                              const std::string& address,
                              int16_t rssi,
                              bool address_random,
                              const std::string& name,
                              const std::vector<uint8_t>& mfr_data,
                              uint16_t mfr_company,
                              const std::vector<std::string>& service_uuids) {
    uint8_t addr[6]{};
    parse_bd_addr(address, addr);

    uint16_t name_len = static_cast<uint16_t>(name.size());
    uint8_t  mfr_len  = static_cast<uint8_t>(
                            std::min<size_t>(mfr_data.size(), 255u));
    uint8_t  uuid_cnt = static_cast<uint8_t>(
                            std::min<size_t>(service_uuids.size(), 16u));

    // Calculate total size
    size_t total = 1       // type
                 + 6       // addr
                 + 1       // addr_type
                 + 1       // rssi
                 + 2       // name_len
                 + name_len
                 + 2       // mfr_company
                 + 1       // mfr_len
                 + mfr_len
                 + 1       // uuid_count
                 + uuid_cnt * 16u;

    auto* buf = static_cast<uint8_t*>(::malloc(total));
    if (!buf) return;

    size_t off = 0;
    buf[off++] = BLE_EVT_SCAN_RESULT;
    ::memcpy(buf + off, addr, 6); off += 6;
    buf[off++] = address_random ? 1u : 0u;
    buf[off++] = static_cast<uint8_t>(rssi);
    buf[off++] = static_cast<uint8_t>(name_len & 0xFF);
    buf[off++] = static_cast<uint8_t>(name_len >> 8);
    ::memcpy(buf + off, name.data(), name_len); off += name_len;
    buf[off++] = static_cast<uint8_t>(mfr_company & 0xFF);
    buf[off++] = static_cast<uint8_t>(mfr_company >> 8);
    buf[off++] = mfr_len;
    ::memcpy(buf + off, mfr_data.data(), mfr_len); off += mfr_len;
    buf[off++] = uuid_cnt;
    for (uint8_t i = 0; i < uuid_cnt; ++i) {
        // Service UUID: store the 16-byte canonical form (pad short UUIDs)
        uint8_t uuid_bytes[16]{};
        const auto& u = service_uuids[i];
        // BlueZ returns UUIDs as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        // Parse the hex digits, ignoring dashes
        size_t bi = 0;
        for (char c : u) {
            if (c == '-') continue;
            if (bi >= 32) break;
            int d = (c >= '0' && c <= '9') ? c - '0' :
                    (c >= 'a' && c <= 'f') ? c - 'a' + 10 :
                    (c >= 'A' && c <= 'F') ? c - 'A' + 10 : 0;
            if (bi % 2 == 0) uuid_bytes[bi/2]  = static_cast<uint8_t>(d << 4);
            else              uuid_bytes[bi/2] |= static_cast<uint8_t>(d);
            ++bi;
        }
        ::memcpy(buf + off, uuid_bytes, 16); off += 16;
    }

    post_event(port, buf, total);
}

// BLE_EVT_CHAR_NOTIFY / BLE_EVT_CHAR_READ (variable)
static void post_char_data(Dart_Port port, uint8_t event_type,
                            int64_t request_id, uint8_t error_code,
                            std::string_view char_path,
                            std::span<const uint8_t> data) {
    uint16_t path_len = static_cast<uint16_t>(char_path.size());
    uint16_t data_len = static_cast<uint16_t>(std::min<size_t>(data.size(), 0xFFFF));
    size_t total = 1 + 8 + 1 + 2 + path_len + 2 + data_len;

    auto* buf = static_cast<uint8_t*>(::malloc(total));
    if (!buf) return;

    size_t off = 0;
    buf[off++] = event_type;
    ::memcpy(buf + off, &request_id, 8); off += 8;   // LE on x86
    buf[off++] = error_code;
    buf[off++] = static_cast<uint8_t>(path_len & 0xFF);
    buf[off++] = static_cast<uint8_t>(path_len >> 8);
    ::memcpy(buf + off, char_path.data(), path_len); off += path_len;
    buf[off++] = static_cast<uint8_t>(data_len & 0xFF);
    buf[off++] = static_cast<uint8_t>(data_len >> 8);
    ::memcpy(buf + off, data.data(), data_len);

    post_event(port, buf, total);
}

// BLE_EVT_CHAR_WRITE (variable)
static void post_char_write_ack(Dart_Port port, int64_t request_id,
                                 uint8_t error_code, std::string_view char_path) {
    uint16_t path_len = static_cast<uint16_t>(char_path.size());
    size_t total = 1 + 8 + 1 + 2 + path_len;
    auto* buf = static_cast<uint8_t*>(::malloc(total));
    if (!buf) return;
    size_t off = 0;
    buf[off++] = BLE_EVT_CHAR_WRITE;
    ::memcpy(buf + off, &request_id, 8); off += 8;
    buf[off++] = error_code;
    buf[off++] = static_cast<uint8_t>(path_len & 0xFF);
    buf[off++] = static_cast<uint8_t>(path_len >> 8);
    ::memcpy(buf + off, char_path.data(), path_len);
    post_event(port, buf, total);
}

// BLE_EVT_ERROR
static void post_error(Dart_Port port, std::string_view msg) {
    uint16_t msg_len = static_cast<uint16_t>(std::min<size_t>(msg.size(), 0xFFFF));
    size_t total = 1 + 2 + msg_len;
    auto* buf = static_cast<uint8_t*>(::malloc(total));
    if (!buf) return;
    buf[0] = BLE_EVT_ERROR;
    buf[1] = static_cast<uint8_t>(msg_len & 0xFF);
    buf[2] = static_cast<uint8_t>(msg_len >> 8);
    ::memcpy(buf + 3, msg.data(), msg_len);
    post_event(port, buf, total);
}

// ── Global state ───────────────────────────────────────────────────────────
namespace {

struct BleState {
    std::unique_ptr<sdbus::IConnection> conn;
    std::jthread                        event_thread;

    std::atomic<Dart_Port>              event_port{0};

    // Subscribed notifications: char_path → subscribeSlot (sdbus slot)
    std::mutex                          subs_mu;
    std::unordered_map<std::string,
        std::unique_ptr<sdbus::IProxy>> char_proxies;

    // Rings: protected by rings_mu
    std::mutex rings_mu;
    struct RingEntry {
        std::string   prefix;
        BleNotifRing* ring;
    };
    std::vector<RingEntry> rings;

    // Request-id → pending (for correlating async replies)
    std::mutex                              pending_mu;
    std::unordered_map<int64_t, std::string> pending_char_path;

    std::atomic<bool> running{false};
};

static std::unique_ptr<BleState> g_state;

// Convenience: current event port
static Dart_Port event_port() noexcept {
    return g_state ? g_state->event_port.load(std::memory_order_relaxed) : 0;
}

// Route a notification to rings and/or event port
static void dispatch_notify(const std::string& char_path,
                             std::span<const uint8_t> value) {
    if (!g_state) return;

    // Try rings first (zero-copy path for high-freq data)
    {
        std::lock_guard lk(g_state->rings_mu);
        for (auto& re : g_state->rings) {
            if (re.prefix.empty() ||
                char_path.starts_with(re.prefix)) {
                auto* data = static_cast<uint8_t*>(::malloc(value.size()));
                if (data) {
                    ::memcpy(data, value.data(), value.size());
                    if (!re.ring->push(data, static_cast<uint32_t>(value.size()),
                                       char_path.c_str())) {
                        ::free(data); // ring full, fall through to port
                    } else {
                        return;
                    }
                }
            }
        }
    }

    // Fall back to event port
    Dart_Port port = event_port();
    if (port != 0) {
        post_char_data(port, BLE_EVT_CHAR_NOTIFY, 0, 0,
                       char_path, value);
    }
}

} // anonymous namespace

// ── Property helper ────────────────────────────────────────────────────────
template<typename T>
static std::optional<T> get_prop(sdbus::IProxy& proxy,
                                  std::string_view iface,
                                  std::string_view prop) noexcept {
    try {
        return proxy.getProperty(std::string(prop))
                    .onInterface(std::string(iface))
                    .template get<T>();
    } catch (...) {
        return std::nullopt;
    }
}

// ── ObjectManager helper ────────────────────────────────────────────────────
// Returns all objects+interfaces managed by org.bluez.
using ObjMap = std::map<sdbus::ObjectPath,
                  std::map<std::string, std::map<std::string, sdbus::Variant>>>;

static ObjMap get_managed_objects() {
    auto proxy = sdbus::createProxy(*g_state->conn,
                                     std::string(kBluezService),
                                     std::string(kObjectRoot));
    ObjMap result;
    proxy->callMethod("GetManagedObjects")
         .onInterface(std::string(kObjectManager))
         .storeResultsTo(result);
    return result;
}

// ── Properties-Changed signal handler ──────────────────────────────────────
static void on_properties_changed(const std::string& obj_path,
                                   const std::string& iface,
                                   const std::map<std::string, sdbus::Variant>& changed,
                                   const std::vector<std::string>& /*invalidated*/) {
    Dart_Port port = event_port();
    if (port == 0) return;

    if (iface == kAdapter1) {
        bool powered     = false;
        bool discovering = false;
        if (auto p = changed.find("Powered");    p != changed.end())
            powered     = p->second.get<bool>();
        if (auto d = changed.find("Discovering"); d != changed.end())
            discovering = d->second.get<bool>();
        post_adapter_state(port, powered, discovering);
        return;
    }

    if (iface == kDevice1) {
        if (auto it = changed.find("Connected"); it != changed.end()) {
            bool connected = it->second.get<bool>();
            // Extract address from path: /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
            std::string path = obj_path;
            auto pos = path.rfind("/dev_");
            if (pos != std::string::npos) {
                std::string dev = path.substr(pos + 5); // "AA_BB_CC_DD_EE_FF"
                for (char& c : dev) if (c == '_') c = ':';
                uint8_t addr[6]{};
                parse_bd_addr(dev, addr);
                post_connection(port, addr, connected ? 2u : 0u, 0u);
            }
        }
    }
}

// ── C ABI implementation ────────────────────────────────────────────────────

int bluez_ble_init(void* dart_api_dl_data) {
    if (Dart_InitializeApiDL(dart_api_dl_data) != 0) return -1;
    if (g_state) return 0; // already initialised

    g_state = std::make_unique<BleState>();
    try {
        g_state->conn = sdbus::createSystemBusConnection();
        g_state->running.store(true);

        // Run the sdbus event loop on a background jthread
        g_state->event_thread = std::jthread([](std::stop_token st) {
            while (!st.stop_requested()) {
                try {
                    g_state->conn->enterEventLoopAsync();
                    // enterEventLoopAsync returns immediately; we use
                    // the blocking form in a way that respects stop_token.
                    // Instead: use processPendingRequest in a poll loop.
                    while (!st.stop_requested()) {
                        g_state->conn->processPendingRequest();
                    }
                } catch (const sdbus::Error& e) {
                    Dart_Port port = event_port();
                    if (port) post_error(port, e.what());
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
            }
        });
    } catch (const std::exception& e) {
        g_state.reset();
        return -2;
    }
    return 0;
}

void bluez_ble_shutdown(void) {
    if (!g_state) return;
    g_state->event_thread.request_stop();
    if (g_state->conn) {
        try { g_state->conn->leaveEventLoop(); } catch (...) {}
    }
    g_state.reset();
}

int bluez_ble_register_event_port(int64_t port_id) {
    if (!g_state) return -1;
    g_state->event_port.store(static_cast<Dart_Port>(port_id),
                               std::memory_order_relaxed);
    return 0;
}

void bluez_ble_unregister_event_port(void) {
    if (g_state) g_state->event_port.store(0, std::memory_order_relaxed);
}

int bluez_ble_adapter_state(void) {
    if (!g_state) return -1;
    Dart_Port port = event_port();
    if (!port) return -1;
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(kAdapterPath));
        auto powered     = get_prop<bool>(*proxy, kAdapter1, "Powered");
        auto discovering = get_prop<bool>(*proxy, kAdapter1, "Discovering");
        post_adapter_state(port,
                           powered.value_or(false),
                           discovering.value_or(false));
        return 0;
    } catch (const std::exception& e) {
        post_error(port, e.what());
        return -1;
    }
}

int bluez_ble_start_scan(const char** filter_uuids, uint32_t timeout_ms) {
    if (!g_state) return -1;
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(kAdapterPath));

        // Subscribe to InterfacesAdded for new devices
        auto obj_proxy = sdbus::createProxy(*g_state->conn,
                                             std::string(kBluezService),
                                             std::string(kObjectRoot));
        obj_proxy->registerSignalHandler(
            std::string(kObjectManager), "InterfacesAdded",
            [](sdbus::Signal& sig) {
                sdbus::ObjectPath path;
                std::map<std::string, std::map<std::string, sdbus::Variant>> ifaces;
                sig >> path >> ifaces;

                auto it = ifaces.find(std::string(kDevice1));
                if (it == ifaces.end()) return;

                Dart_Port port = event_port();
                if (!port) return;

                auto& props = it->second;
                auto get = [&](const char* key) -> const sdbus::Variant* {
                    auto p = props.find(key);
                    return p != props.end() ? &p->second : nullptr;
                };

                std::string addr;
                if (auto* v = get("Address")) addr = v->get<std::string>();
                else return;

                int16_t rssi = 0;
                if (auto* v = get("RSSI")) rssi = v->get<int16_t>();

                bool addr_random = false;
                if (auto* v = get("AddressType"))
                    addr_random = (v->get<std::string>() == "random");

                std::string name;
                if (auto* v = get("Name"))  name = v->get<std::string>();
                else if (auto* v = get("Alias")) name = v->get<std::string>();

                std::vector<uint8_t> mfr_data;
                uint16_t mfr_company = 0xFFFF;
                if (auto* v = get("ManufacturerData")) {
                    try {
                        auto md = v->get<std::map<uint16_t, std::vector<uint8_t>>>();
                        if (!md.empty()) {
                            mfr_company = md.begin()->first;
                            mfr_data    = md.begin()->second;
                        }
                    } catch (...) {}
                }

                std::vector<std::string> uuids;
                if (auto* v = get("UUIDs")) {
                    try { uuids = v->get<std::vector<std::string>>(); }
                    catch (...) {}
                }

                post_scan_result(port, addr, rssi, addr_random,
                                 name, mfr_data, mfr_company, uuids);
            });
        obj_proxy->finishRegistration();

        // Also subscribe to PropertiesChanged on the adapter for RSSI updates
        proxy->registerSignalHandler(
            std::string(kProperties), "PropertiesChanged",
            [path = std::string(kAdapterPath)](sdbus::Signal& sig) {
                std::string iface;
                std::map<std::string, sdbus::Variant> changed;
                std::vector<std::string> invalidated;
                sig >> iface >> changed >> invalidated;
                on_properties_changed(path, iface, changed, invalidated);
            });
        proxy->finishRegistration();

        // Set discovery filter if UUIDs requested
        if (filter_uuids && *filter_uuids) {
            std::map<std::string, sdbus::Variant> filter;
            std::vector<std::string> uuids;
            for (const char** u = filter_uuids; *u; ++u)
                uuids.emplace_back(*u);
            filter.emplace("UUIDs",      sdbus::Variant(uuids));
            filter.emplace("Transport",  sdbus::Variant(std::string("le")));
            proxy->callMethod("SetDiscoveryFilter")
                 .onInterface(std::string(kAdapter1))
                 .withArguments(filter);
        }

        proxy->callMethod("StartDiscovery")
             .onInterface(std::string(kAdapter1));

        // Auto-stop after timeout_ms if non-zero
        if (timeout_ms > 0) {
            std::thread([ms = timeout_ms]() {
                std::this_thread::sleep_for(std::chrono::milliseconds(ms));
                bluez_ble_stop_scan();
            }).detach();
        }

        return 0;
    } catch (const sdbus::Error& e) {
        Dart_Port port = event_port();
        if (port) post_error(port, e.what());
        return -1;
    }
}

int bluez_ble_stop_scan(void) {
    if (!g_state) return -1;
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(kAdapterPath));
        proxy->callMethod("StopDiscovery")
             .onInterface(std::string(kAdapter1));
        return 0;
    } catch (const sdbus::Error& e) {
        Dart_Port port = event_port();
        if (port) post_error(port, e.what());
        return -1;
    }
}

// Build D-Bus object path for a device from its BD address
static std::string device_path(const char* address) {
    std::string p(kAdapterPath);
    p += "/dev_";
    for (const char* c = address; *c; ++c)
        p += (*c == ':') ? '_' : *c;
    return p;
}

int bluez_ble_connect(const char* address) {
    if (!g_state || !address) return -1;
    std::string path = device_path(address);
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService), path);

        // Subscribe to PropertiesChanged for connection state
        proxy->registerSignalHandler(
            std::string(kProperties), "PropertiesChanged",
            [path](sdbus::Signal& sig) {
                std::string iface;
                std::map<std::string, sdbus::Variant> changed;
                std::vector<std::string> invalidated;
                sig >> iface >> changed >> invalidated;
                on_properties_changed(path, iface, changed, invalidated);
            });
        proxy->finishRegistration();

        // Async connect
        proxy->callMethodAsync("Connect")
             .onInterface(std::string(kDevice1))
             .uponReplyInvoke([path, address = std::string(address)]
                              (const sdbus::Error* err) {
                 Dart_Port port = event_port();
                 if (!port) return;
                 uint8_t addr[6]{};
                 parse_bd_addr(address, addr);
                 if (err) {
                     post_connection(port, addr, 0u /*disconnected*/, 1u /*error*/);
                 } else {
                     post_connection(port, addr, 2u /*connected*/, 0u);
                 }
             });

        // Post "connecting" state immediately
        Dart_Port port = event_port();
        if (port) {
            uint8_t addr[6]{};
            parse_bd_addr(address, addr);
            post_connection(port, addr, 1u /*connecting*/, 0u);
        }
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port()) post_error(port, e.what());
        return -1;
    }
}

int bluez_ble_disconnect(const char* address) {
    if (!g_state || !address) return -1;
    std::string path = device_path(address);
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService), path);
        proxy->callMethod("Disconnect")
             .onInterface(std::string(kDevice1));

        Dart_Port port = event_port();
        if (port) {
            uint8_t addr[6]{};
            parse_bd_addr(address, addr);
            post_connection(port, addr, 3u /*disconnecting*/, 0u);
        }
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port()) post_error(port, e.what());
        return -1;
    }
}

int bluez_ble_char_read(const char* char_path, int64_t request_id) {
    if (!g_state || !char_path) return -1;
    std::string path(char_path);
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService), path);
        std::map<std::string, sdbus::Variant> options;
        proxy->callMethodAsync("ReadValue")
             .onInterface(std::string(kGattChar1))
             .withArguments(options)
             .uponReplyInvoke([path, request_id](const sdbus::Error* err,
                                                  const std::vector<uint8_t>& val) {
                 Dart_Port port = event_port();
                 if (!port) return;
                 if (err) {
                     post_char_data(port, BLE_EVT_CHAR_READ, request_id, 1u,
                                    path, {});
                 } else {
                     post_char_data(port, BLE_EVT_CHAR_READ, request_id, 0u,
                                    path, std::span(val));
                 }
             });
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port())
            post_char_data(port, BLE_EVT_CHAR_READ, request_id, 1u,
                           char_path, {});
        return -1;
    }
}

int bluez_ble_char_write(const char* char_path, const uint8_t* data,
                          uint32_t len, int64_t request_id) {
    if (!g_state || !char_path || !data) return -1;
    std::string path(char_path);
    std::vector<uint8_t> payload(data, data + len);
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService), path);
        std::map<std::string, sdbus::Variant> options;
        proxy->callMethodAsync("WriteValue")
             .onInterface(std::string(kGattChar1))
             .withArguments(payload, options)
             .uponReplyInvoke([path, request_id](const sdbus::Error* err) {
                 Dart_Port port = event_port();
                 if (!port) return;
                 post_char_write_ack(port, request_id,
                                     err ? 1u : 0u, path);
             });
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port())
            post_char_write_ack(port, request_id, 1u, char_path);
        return -1;
    }
}

int bluez_ble_char_write_no_response(const char* char_path,
                                      const uint8_t* data, uint32_t len) {
    if (!g_state || !char_path || !data) return -1;
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(char_path));
        std::vector<uint8_t> payload(data, data + len);
        std::map<std::string, sdbus::Variant> options;
        options.emplace("type", sdbus::Variant(std::string("command")));
        proxy->callMethod("WriteValue")
             .onInterface(std::string(kGattChar1))
             .withArguments(payload, options);
        return 0;
    } catch (...) { return -1; }
}

int bluez_ble_char_subscribe(const char* char_path) {
    if (!g_state || !char_path) return -1;
    std::string path(char_path);

    std::lock_guard lk(g_state->subs_mu);
    if (g_state->char_proxies.count(path)) return 0; // already subscribed

    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService), path);

        // Listen for PropertiesChanged to get Value updates
        proxy->registerSignalHandler(
            std::string(kProperties), "PropertiesChanged",
            [path](sdbus::Signal& sig) {
                std::string iface;
                std::map<std::string, sdbus::Variant> changed;
                std::vector<std::string> invalidated;
                sig >> iface >> changed >> invalidated;

                if (iface != kGattChar1) return;
                auto it = changed.find("Value");
                if (it == changed.end()) return;

                try {
                    auto val = it->second.get<std::vector<uint8_t>>();
                    dispatch_notify(path, std::span(val));
                } catch (...) {}
            });
        proxy->finishRegistration();

        proxy->callMethod("StartNotify")
             .onInterface(std::string(kGattChar1));

        g_state->char_proxies.emplace(path, std::move(proxy));
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port()) post_error(port, e.what());
        return -1;
    }
}

int bluez_ble_char_unsubscribe(const char* char_path) {
    if (!g_state || !char_path) return -1;
    std::string path(char_path);

    std::lock_guard lk(g_state->subs_mu);
    auto it = g_state->char_proxies.find(path);
    if (it == g_state->char_proxies.end()) return 0;

    try {
        it->second->callMethod("StopNotify")
                  .onInterface(std::string(kGattChar1));
    } catch (...) {}
    g_state->char_proxies.erase(it);
    return 0;
}

char** bluez_ble_get_char_paths(const char* device_address) {
    if (!g_state || !device_address) return nullptr;
    try {
        auto objects = get_managed_objects();
        std::string dev_path = device_path(device_address);

        std::vector<std::string> paths;
        for (auto& [path, ifaces] : objects) {
            if (ifaces.count(std::string(kGattChar1)) &&
                std::string(path).starts_with(dev_path)) {
                paths.emplace_back(path);
            }
        }

        char** result = static_cast<char**>(
            ::malloc((paths.size() + 1) * sizeof(char*)));
        if (!result) return nullptr;
        for (size_t i = 0; i < paths.size(); ++i)
            result[i] = ::strdup(paths[i].c_str());
        result[paths.size()] = nullptr;
        return result;
    } catch (...) { return nullptr; }
}

void bluez_ble_free_string_list(char** list) {
    if (!list) return;
    for (char** p = list; *p; ++p) ::free(*p);
    ::free(list);
}

BleNotifRing* bluez_ble_ring_create(uint32_t capacity) {
    if (!std::has_single_bit(capacity))
        capacity = std::bit_ceil(capacity);
    size_t total = sizeof(BleNotifRing)
                 + capacity * sizeof(BleNotifRing::Slot);
    void* mem = ::aligned_alloc(64, total);
    if (!mem) return nullptr;
    auto* ring = new (mem) BleNotifRing{};
    ring->magic    = BleNotifRing::kMagic;
    ring->capacity = capacity;
    ring->mask     = capacity - 1u;
    return ring;
}

void bluez_ble_ring_destroy(BleNotifRing* ring) {
    if (!ring) return;
    ring->~BleNotifRing();
    ::free(ring);
}

bool bluez_ble_ring_push(BleNotifRing* ring,
                          uint8_t* data, uint32_t data_len,
                          const char* char_path) {
    if (!ring || !data) return false;
    return ring->push(data, data_len, char_path);
}

bool bluez_ble_ring_pop(BleNotifRing* ring, uint8_t** data,
                         uint32_t* len, char** path) {
    if (!ring) return false;
    return ring->pop(data, len, path);
}

int bluez_ble_ring_size(BleNotifRing* ring) {
    return ring ? ring->size() : 0;
}

int bluez_ble_ring_attach(const char* char_path_prefix, BleNotifRing* ring) {
    if (!g_state || !ring) return -1;
    std::lock_guard lk(g_state->rings_mu);
    g_state->rings.push_back({
        char_path_prefix ? std::string(char_path_prefix) : std::string{},
        ring
    });
    return 0;
}

int bluez_ble_ring_detach(BleNotifRing* ring) {
    if (!g_state || !ring) return -1;
    std::lock_guard lk(g_state->rings_mu);
    auto& v = g_state->rings;
    v.erase(std::remove_if(v.begin(), v.end(),
                            [ring](auto& e){ return e.ring == ring; }),
            v.end());
    return 0;
}

int bluez_ble_get_char_info(const char*  char_path,
                             char**       out_uuid,
                             char**       out_service_path,
                             char**       out_service_uuid,
                             char***      out_flags) {
    if (!g_state || !char_path) return -1;

    // Initialise out params to safe defaults
    if (out_uuid)         *out_uuid         = nullptr;
    if (out_service_path) *out_service_path = nullptr;
    if (out_service_uuid) *out_service_uuid = nullptr;
    if (out_flags)        *out_flags        = nullptr;

    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(char_path));

        // UUID
        if (out_uuid) {
            auto v = get_prop<std::string>(*proxy, kGattChar1, "UUID");
            if (v) *out_uuid = ::strdup(v->c_str());
        }

        // Service (object path of parent)
        if (out_service_path || out_service_uuid) {
            auto svcPath = get_prop<sdbus::ObjectPath>(*proxy, kGattChar1, "Service");
            if (svcPath) {
                if (out_service_path) *out_service_path = ::strdup(svcPath->c_str());

                if (out_service_uuid) {
                    auto svcProxy = sdbus::createProxy(*g_state->conn,
                                                        std::string(kBluezService),
                                                        *svcPath);
                    auto svcUuid = get_prop<std::string>(
                        *svcProxy, "org.bluez.GattService1", "UUID");
                    if (svcUuid) *out_service_uuid = ::strdup(svcUuid->c_str());
                }
            }
        }

        // Flags — vector of strings → NULL-terminated char**
        if (out_flags) {
            auto flags = get_prop<std::vector<std::string>>(
                *proxy, kGattChar1, "Flags");
            if (flags) {
                auto** arr = static_cast<char**>(
                    ::malloc((flags->size() + 1) * sizeof(char*)));
                if (arr) {
                    for (size_t i = 0; i < flags->size(); ++i)
                        arr[i] = ::strdup((*flags)[i].c_str());
                    arr[flags->size()] = nullptr;
                    *out_flags = arr;
                }
            }
        }

        return 0;
    } catch (...) { return -1; }
}

int bluez_ble_wait_services_resolved(const char* address, uint32_t timeout_ms) {
    if (!g_state || !address) return -1;
    std::string path = device_path(address);

    auto check = [&]() -> bool {
        try {
            auto proxy = sdbus::createProxy(*g_state->conn,
                                             std::string(kBluezService), path);
            auto v = get_prop<bool>(*proxy, kDevice1, "ServicesResolved");
            return v.value_or(false);
        } catch (...) { return false; }
    };

    if (check()) return 0;
    if (timeout_ms == 0) return -1;

    // Poll every 100 ms up to timeout_ms
    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::milliseconds(timeout_ms);
    constexpr auto kPoll = std::chrono::milliseconds(100);

    while (std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(kPoll);
        if (check()) return 0;
    }
    return -1;
}

int bluez_ble_adapter_set_powered(int powered) {
    if (!g_state) return -1;
    try {
        auto proxy = sdbus::createProxy(*g_state->conn,
                                         std::string(kBluezService),
                                         std::string(kAdapterPath));
        sdbus::Variant val(powered != 0);
        proxy->callMethod("Set")
             .onInterface(std::string(kProperties))
             .withArguments(std::string(kAdapter1),
                            std::string("Powered"), val);
        return 0;
    } catch (const sdbus::Error& e) {
        if (Dart_Port port = event_port()) post_error(port, e.what());
        return -1;
    }
}

const char* bluez_ble_version(void) { return kVersion; }
void        bluez_ble_free(void* ptr) { ::free(ptr); }
