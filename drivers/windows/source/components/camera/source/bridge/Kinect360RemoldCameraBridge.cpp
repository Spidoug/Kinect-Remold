#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <winusb.h>
#include <usb.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <functional>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <iomanip>
#include <sstream>
#include <fstream>
#include <cwctype>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <set>
#include <thread>
#include <system_error>
#include <vector>

#include "..\..\shared\Kinect360RemoldFrameTransport.h"
#include "..\..\shared\Kinect360RemoldScannerPort.h"
#include "..\..\..\device\shared\Kinect360RemoldControlProtocol.h"
#include "..\..\..\device\shared\Kinect360RemoldDeviceIdentity.h"
#include "..\..\..\device\shared\Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "winusb.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
using namespace Kinect360RemoldFrameTransport;
namespace Control = Kinect360RemoldControl;
namespace ScannerPort = Kinect360RemoldScannerPort;
namespace Hardware = Kinect360RemoldHardware;
namespace CameraUsb = Kinect360RemoldHardware::Camera;

constexpr ULONG kRgbRawFrameBytes = 640u * 480u;                 // medium Bayer
constexpr ULONG kRgbHqRawFrameBytes = 1280u * 1024u;              // high Bayer, about 10 fps
constexpr ULONG kIrRawFrameBytes = 640u * 488u * 10u / 8u;      // medium IR, packed 10-bit
constexpr ULONG kDepthRawFrameBytes = 640u * 480u * 11u / 8u;   // medium depth, packed 11-bit
constexpr uint8_t kVideoFlag = 0x80;
constexpr uint8_t kDepthFlag = 0x70;
constexpr DWORD kControlReplyDeadlineMs = 2000;
constexpr DWORD kIsoWaitMs = 1000;
constexpr DWORD kIsoCancelDeadlineMs = 750;
constexpr DWORD kVideoFrameTimeoutMs = 3500;
constexpr DWORD kRgbHqFrameTimeoutMs = 6000;
constexpr DWORD kDepthFrameTimeoutMs = 3500;
constexpr int kMaxIsoTimeouts = 3;
constexpr DWORD kScannerStatePollMs = 25;
constexpr uint8_t kMaxRecoverablePacketLoss = 5;

std::atomic<bool> g_run{true};
HANDLE g_stopEvent = nullptr;
SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};

HRESULT HrLastError() {
    DWORD e = GetLastError();
    return HRESULT_FROM_WIN32(e ? e : ERROR_GEN_FAILURE);
}

void Log(const wchar_t* text) {
    if (!text) return;
    OutputDebugStringW(text);
    OutputDebugStringW(L"\n");
    if (GetConsoleWindow()) std::fwprintf(stderr, L"%ls\n", text);

    // The bridge normally runs as a service, where OutputDebugString is not
    // available to the user. Keep a small, actionable log in ProgramData.
    static std::mutex logMutex;
    std::lock_guard<std::mutex> lock(logMutex);
    wchar_t programData[MAX_PATH]{};
    const DWORD length = GetEnvironmentVariableW(L"ProgramData", programData, MAX_PATH);
    if (!length || length >= MAX_PATH) return;
    std::error_code ec;
    const std::filesystem::path directory =
        std::filesystem::path(programData) / L"Kinect360Remold";
    std::filesystem::create_directories(directory, ec);
    if (ec) return;
    std::wofstream stream(directory / L"camera-bridge.log", std::ios::app);
    if (!stream) return;
    SYSTEMTIME now{};
    GetLocalTime(&now);
    stream << std::setfill(L'0')
           << L'[' << std::setw(4) << now.wYear << L'-'
           << std::setw(2) << now.wMonth << L'-' << std::setw(2) << now.wDay
           << L' ' << std::setw(2) << now.wHour << L':' << std::setw(2) << now.wMinute
           << L':' << std::setw(2) << now.wSecond << L'.' << std::setw(3) << now.wMilliseconds
           << L"] " << text << L'\n';
}

void LogHr(const wchar_t* what, HRESULT hr) {
    wchar_t buf[256]{};
    swprintf_s(buf, L"%ls: 0x%08X", what, static_cast<unsigned>(hr));
    Log(buf);
}

bool BrokerExchange(Control::Command command, int32_t value, Control::Reply& reply, const std::string& deviceId, DWORD waitMs = 100) {
    reply = {};
    if (!WaitNamedPipeW(Control::kPipeName, waitMs)) return false;
    HANDLE pipe = CreateFileW(Control::kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_MESSAGE;
    (void)SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

    Control::Request request{};
    request.command = command;
    request.value = value;
    if (!deviceId.empty()) strncpy_s(request.deviceId, deviceId.c_str(), _TRUNCATE);
    DWORD written = 0, read = 0;
    const bool ok = WriteFile(pipe, &request, sizeof(request), &written, nullptr) &&
                    written == sizeof(request) &&
                    ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) &&
                    read == sizeof(reply);
    CloseHandle(pipe);
    return ok && reply.magic == Control::kMagic && reply.version == Control::kVersion &&
           SUCCEEDED(static_cast<HRESULT>(reply.result));
}

bool QueryBrokerMotion(const std::string& deviceId, ScannerPort::MotionSample& motion) {
    motion = {};
    Control::Reply reply{};
    if (!BrokerExchange(Control::Command::Status, 0, reply, deviceId, 0) ||
        reply.transport != Control::Transport::PhysicalMotor) return false;

    motion.flags = ScannerPort::MotionAccelerometerValid | ScannerPort::MotionTiltValid;
    motion.accelX = reply.accelX;
    motion.accelY = reply.accelY;
    motion.accelZ = reply.accelZ;
    motion.tiltTenths = reply.tiltTenths;
    motion.tickMs = GetTickCount64();
    return true;
}

bool PrepareCameraControl(const std::string& deviceId) {
    Control::Reply reply{};
    return BrokerExchange(Control::Command::PrepareCamera, 0, reply, deviceId, 0);
}

#pragma pack(push, 1)
struct CameraCommandHeader {
    uint8_t magic[2];
    uint16_t lengthWords;
    uint16_t command;
    uint16_t tag;
};
struct VideoPacketHeader {
    uint8_t magic[2];
    uint8_t pad;
    uint8_t flag;
    uint8_t unknown1;
    uint8_t sequence;
    uint8_t unknown2;
    uint8_t unknown3;
    uint32_t timestamp;
};
#pragma pack(pop)
static_assert(sizeof(CameraCommandHeader) == 8, "camera command header");
static_assert(sizeof(VideoPacketHeader) == 12, "video packet header");

class SharedFramePublisher {
public:
    ~SharedFramePublisher() { Close(); }

    HRESULT Open(const std::string& deviceId) {
        Close();
        PSECURITY_DESCRIPTOR sd = nullptr;
        // The physical bridge is the only writer. Windows Frame Server and app
        // containers are read-only consumers; they can never select a sensor mode.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GR;;;LS)(A;;GR;;;BA)(A;;GR;;;AC)",
                SDDL_REVISION_1, &sd, nullptr)) {
            return HrLastError();
        }
        SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
        const std::wstring mappingName = MappingName(deviceId);
        m_mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
                                       0, kMappingBytes, mappingName.c_str());
        LocalFree(sd);
        if (!m_mapping) return HrLastError();
        m_base = MapViewOfFile(m_mapping, FILE_MAP_ALL_ACCESS, 0, 0, kMappingBytes);
        if (!m_base) {
            const HRESULT hr = HrLastError();
            Close();
            return hr;
        }
        m_header = static_cast<SharedHeader*>(m_base);

        OpenConsumerLease(deviceId);

        InterlockedExchange(&m_header->colorSequence, 1);
        MemoryBarrier();
        m_header->magic = kMagic;
        m_header->version = kVersion;
        m_header->width = kWidth;
        m_header->height = kHeight;
        m_header->fourcc = kNv12Fourcc;
        m_header->stride = kWidth;
        m_header->frameBytes = kNv12Bytes;
        m_header->slotCount = kSlotCount;
        m_header->activeSlot = 0;
        m_header->online = 0;
        // Software consumers have no physical-mode request fields in the current protocol.
        std::memset(m_header->slot, 0, sizeof(m_header->slot));
        std::memset(SlotAddress(m_base, 0), 0, static_cast<size_t>(kHqNv12Bytes) * kSlotCount);
        MemoryBarrier();
        InterlockedExchange(&m_header->colorSequence, 2);
        return S_OK;
    }

    void SetOnline(bool online) {
        if (!m_header) return;
        InterlockedIncrement(&m_header->colorSequence);
        InterlockedExchange(&m_header->online, online ? 1 : 0);
        MemoryBarrier();
        InterlockedIncrement(&m_header->colorSequence);
    }

    void SubmitVga(const uint8_t* nv12, size_t bytes, uint64_t tickMs,
                   const ScannerPort::MotionSample& motion) {
        if (!nv12 || bytes != kNv12Bytes) return;
        PublishFrame(nv12, bytes, kWidth, kHeight, tickMs, 0u, motion);
    }

    void SubmitHq(const uint8_t* nv12, size_t bytes, uint64_t tickMs, bool virtualRgbHq,
                  const ScannerPort::MotionSample& motion) {
        if (!nv12 || bytes != kHqNv12Bytes) return;
        if (virtualRgbHq) {
            PublishFrame(nv12, bytes, kHqWidth, kHqHeight, tickMs, 1u, motion);
            return;
        }
        std::vector<uint8_t> vga(kNv12Bytes);
        DownsampleHqToVga(nv12, vga.data());
        PublishFrame(vga.data(), vga.size(), kWidth, kHeight, tickMs, 1u, motion);
    }

    // Frame consumers (virtual camera, IP camera) renew this lease while they
    // use frames; it is the only object consumers may write. The lease only
    // gates motion sampling, so a failure is logged and never blocks frames.
    void OpenConsumerLease(const std::string& deviceId) {
        PSECURITY_DESCRIPTOR sd = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;LS)(A;;GRGW;;;BA)(A;;GRGW;;;AC)",
                SDDL_REVISION_1, &sd, nullptr)) {
            LogHr(L"Frame consumer lease security descriptor failed", HrLastError());
            return;
        }
        SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
        m_leaseMapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
                                            0, sizeof(ConsumerLease), LeaseName(deviceId).c_str());
        const HRESULT createHr = m_leaseMapping ? S_OK : HrLastError();
        LocalFree(sd);
        if (m_leaseMapping)
            m_lease = static_cast<ConsumerLease*>(MapViewOfFile(m_leaseMapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(ConsumerLease)));
        if (!m_lease) {
            LogHr(L"Frame consumer lease unavailable; virtual/IP camera frames continue without motion sampling",
                  m_leaseMapping ? HrLastError() : createHr);
            if (m_leaseMapping) CloseHandle(m_leaseMapping);
            m_leaseMapping = nullptr;
            return;
        }
        InterlockedExchange64(&m_lease->renewedTickMs, 0);
    }

    bool ConsumerLeaseActive() const noexcept {
        if (!m_lease) return false;
        const auto renewed = static_cast<ULONGLONG>(InterlockedCompareExchange64(&m_lease->renewedTickMs, 0, 0));
        return renewed != 0 && GetTickCount64() - renewed <= kConsumerLeaseMs;
    }

private:
    HANDLE m_mapping = nullptr;
    void* m_base = nullptr;
    SharedHeader* m_header = nullptr;
    HANDLE m_leaseMapping = nullptr;
    ConsumerLease* m_lease = nullptr;
    uint64_t m_frameNumber = 0;

    static void DownsampleHqToVga(const uint8_t* source, uint8_t* target) noexcept {
        if (!source || !target) return;
        const uint8_t* sy = source;
        const uint8_t* suv = source + static_cast<size_t>(kHqWidth) * kHqHeight;
        uint8_t* dy = target;
        uint8_t* duv = target + static_cast<size_t>(kWidth) * kHeight;
        for (uint32_t y = 0; y < kHeight; ++y) {
            const uint32_t yy = std::min(kHqHeight - 1u,
                static_cast<uint32_t>((static_cast<uint64_t>(y) * kHqHeight) / kHeight));
            for (uint32_t x = 0; x < kWidth; ++x) {
                const uint32_t xx = std::min(kHqWidth - 1u,
                    static_cast<uint32_t>((static_cast<uint64_t>(x) * kHqWidth) / kWidth));
                dy[static_cast<size_t>(y) * kWidth + x] = sy[static_cast<size_t>(yy) * kHqWidth + xx];
            }
        }
        for (uint32_t y = 0; y < kHeight / 2u; ++y) {
            const uint32_t yy = std::min(kHqHeight / 2u - 1u,
                static_cast<uint32_t>((static_cast<uint64_t>(y) * (kHqHeight / 2u)) / (kHeight / 2u)));
            for (uint32_t x = 0; x < kWidth; x += 2u) {
                uint32_t xx = std::min(kHqWidth - 2u,
                    static_cast<uint32_t>((static_cast<uint64_t>(x) * kHqWidth) / kWidth));
                xx &= ~1u;
                const size_t sp = static_cast<size_t>(yy) * kHqWidth + xx;
                const size_t dp = static_cast<size_t>(y) * kWidth + x;
                duv[dp] = suv[sp];
                duv[dp + 1u] = suv[sp + 1u];
            }
        }
    }

    void PublishFrame(const uint8_t* nv12, size_t bytes, uint32_t width, uint32_t height,
                      uint64_t tickMs, uint32_t flags, const ScannerPort::MotionSample& motion) {
        if (!m_header || !nv12) return;
        const uint32_t expected = width * height * 3u / 2u;
        if (bytes != expected || bytes > kHqNv12Bytes) return;
        InterlockedIncrement(&m_header->colorSequence);
        const LONG current = InterlockedCompareExchange(&m_header->activeSlot, 0, 0);
        const uint32_t next = current == 0 ? 1u : 0u;
        std::memcpy(SlotAddress(m_base, next), nv12, bytes);
        m_header->width = width;
        m_header->height = height;
        m_header->stride = width;
        m_header->frameBytes = expected;
        m_header->slot[next].frameNumber = ++m_frameNumber;
        m_header->slot[next].tickMs = tickMs ? tickMs : GetTickCount64();
        m_header->slot[next].bytes = expected;
        m_header->slot[next].flags = flags;
        m_header->slot[next].motion = motion;
        MemoryBarrier();
        InterlockedExchange(&m_header->activeSlot, static_cast<LONG>(next));
        InterlockedExchange(&m_header->online, 1);
        MemoryBarrier();
        InterlockedIncrement(&m_header->colorSequence);
    }

    void Close() {
        if (m_header) SetOnline(false);
        if (m_base) UnmapViewOfFile(m_base);
        if (m_mapping) CloseHandle(m_mapping);
        if (m_lease) UnmapViewOfFile(m_lease);
        if (m_leaseMapping) CloseHandle(m_leaseMapping);
        m_mapping = nullptr;
        m_base = nullptr;
        m_header = nullptr;
        m_leaseMapping = nullptr;
        m_lease = nullptr;
    }
};

struct DepthCalibration {
    bool valid = false;
    double constShift = 0.0;
    double dcmosEmitterDist = 0.0;
    double referenceDistance = 0.0;
    double referencePixelSize = 0.0;
};

class ScannerPortServer {
public:
    explicit ScannerPortServer(std::wstring pipeName, std::string deviceId)
        : m_pipeName(std::move(pipeName)), m_deviceId(std::move(deviceId)) {
        LoadDriverSettings();
    }
    ~ScannerPortServer() { Stop(); }

    HRESULT Start() {
        if (m_thread.joinable()) return S_OK;
        m_stopping.store(false, std::memory_order_release);
        m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stopEvent) return HrLastError();
        try {
            m_thread = std::thread([this] { ServerLoop(); });
        } catch (const std::system_error&) {
            CloseHandle(m_stopEvent);
            m_stopEvent = nullptr;
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Stop() {
        if (m_stopping.exchange(true, std::memory_order_acq_rel)) return;
        if (m_stopEvent) SetEvent(m_stopEvent);
        std::vector<std::shared_ptr<ClientSession>> clients;
        { std::lock_guard<std::mutex> guard(m_clientsLock); clients = m_clients; }
        for (const auto& client : clients) {
            std::lock_guard<std::mutex> q(client->lock);
            client->stopping = true;
            client->queue.clear();
            client->cv.notify_all();
        }
        if (m_thread.joinable()) m_thread.join();
        {
            std::lock_guard<std::mutex> guard(m_clientThreadsLock);
            for (auto& thread : m_clientThreads) if (thread.joinable()) thread.join();
            m_clientThreads.clear();
        }
        {
            std::lock_guard<std::mutex> guard(m_clientsLock);
            m_clients.clear();
            m_streamMask.store(0, std::memory_order_release);
        }
        if (m_stopEvent) CloseHandle(m_stopEvent);
        m_stopEvent = nullptr;
    }

    uint32_t RequestedMask() const noexcept { return m_streamMask.load(std::memory_order_acquire); }
    bool ClientActive() const noexcept { return RequestedMask() != 0; }
    bool Wants(ScannerPort::StreamMode mode) const noexcept { return (RequestedMask() & ScannerPort::MaskFor(mode)) != 0; }
    bool NeedsProjector() const noexcept { return (RequestedMask() & (ScannerPort::StreamInfrared | ScannerPort::StreamDepth)) != 0; }
    bool VirtualRgbHqEnabled() const noexcept {
        return (DriverSettings() & ScannerPort::DriverSettingRgbHighQuality) != 0;
    }
    // Effective settings: the persisted request minus RGB HQ when this sensor
    // proved it cannot deliver HQ frames on the current connection.
    uint32_t DriverSettings() const noexcept {
        const uint32_t settings = m_driverSettings.load(std::memory_order_acquire);
        return RgbHqAvailable() ? settings : (settings & ~ScannerPort::DriverSettingRgbHighQuality);
    }
    bool RgbHqAvailable() const noexcept { return !m_rgbHqUnavailable.load(std::memory_order_acquire); }
    // Same policy as the Linux camera service: a sensor that never completes an
    // RGB HQ frame falls back to VGA for this connection instead of restarting
    // forever. HQ subscribers are released so they renegotiate VGA.
    void MarkRgbHqUnavailable() {
        m_rgbHqUnavailable.store(true, std::memory_order_release);
        std::vector<std::shared_ptr<ClientSession>> released;
        {
            std::lock_guard<std::mutex> guard(m_clientsLock);
            for (auto it = m_clients.begin(); it != m_clients.end();) {
                if (((*it)->mask & ScannerPort::StreamRgbHighQuality) == 0) { ++it; continue; }
                released.push_back(*it);
                it = m_clients.erase(it);
            }
            RecomputeMaskLocked();
        }
        for (const auto& client : released) {
            std::lock_guard<std::mutex> q(client->lock);
            client->stopping = true;
            client->queue.clear();
            client->cv.notify_all();
        }
    }
    HRESULT SetDriverSettings(uint32_t settings) {
        if ((settings & ~ScannerPort::DriverSettingSupported) != 0) return E_INVALIDARG;
        const HRESULT hr = SaveDriverSettings(settings);
        if (FAILED(hr)) return hr;
        m_driverSettings.store(settings, std::memory_order_release);
        return S_OK;
    }
    void SetDepthCalibration(const DepthCalibration& calibration) noexcept {
        std::lock_guard<std::mutex> guard(m_calibrationLock);
        m_depthCalibration = calibration;
    }
    void Publish(ScannerPort::StreamMode mode, ScannerPort::PixelFormat pixelFormat,
                 const void* payload, size_t bytes, uint64_t captureTickMs,
                 const ScannerPort::MotionSample& motion) {
        const uint32_t modeMask = ScannerPort::MaskFor(mode);
        if (!payload || !bytes || !(RequestedMask() & modeMask)) return;
        const size_t index = static_cast<size_t>(mode);
        if (index >= m_frameNumbers.size()) return;

        auto frame = std::make_shared<QueuedFrame>();
        frame->header = ScannerPort::FrameHeader{};
        frame->header.mode = mode;
        frame->header.width = mode == ScannerPort::StreamMode::RgbHighQuality ? ScannerPort::kRgbHqWidth : ScannerPort::kWidth;
        frame->header.height = mode == ScannerPort::StreamMode::RgbHighQuality ? ScannerPort::kRgbHqHeight
            : (mode == ScannerPort::StreamMode::Infrared && pixelFormat == ScannerPort::PixelFormat::IrRaw10Packed
                ? ScannerPort::kIrRawHeight : ScannerPort::kHeight);
        frame->header.pixelFormat = pixelFormat;
        frame->header.payloadBytes = static_cast<uint32_t>(bytes);
        frame->header.frameNumber = ++m_frameNumbers[index];
        frame->header.tickMs = captureTickMs ? captureTickMs : GetTickCount64();
        frame->header.motion = motion;
        frame->payload.resize(bytes);
        std::memcpy(frame->payload.data(), payload, bytes);

        std::vector<std::shared_ptr<ClientSession>> clients;
        {
            std::lock_guard<std::mutex> guard(m_clientsLock);
            if (m_stopping.load(std::memory_order_acquire)) return;
            for (const auto& client : m_clients) if (client->mask & modeMask) clients.push_back(client);
        }
        // Three RGBD pairs are enough to absorb a short scheduler delay. A
        // deeper queue turns a transient delay into visible catch-up stutter.
        constexpr size_t kMaxQueuedFramesPerClient = 6;
        for (const auto& client : clients) {
            std::lock_guard<std::mutex> guard(client->lock);
            if (client->stopping) continue;
            while (client->queue.size() >= kMaxQueuedFramesPerClient) client->queue.pop_front();
            client->queue.push_back(frame);
            client->cv.notify_one();
        }
    }

private:
    struct QueuedFrame {
        ScannerPort::FrameHeader header{};
        std::vector<uint8_t> payload;
    };
    struct ClientSession {
        ClientSession(uint32_t requested, ULONG processId) : mask(requested), pid(processId) {}
        uint32_t mask = 0;
        ULONG pid = 0;
        std::mutex lock;
        std::condition_variable cv;
        std::deque<std::shared_ptr<QueuedFrame>> queue;
        bool stopping = false;
    };

    std::wstring m_pipeName;
    std::string m_deviceId;
    std::thread m_thread;
    HANDLE m_stopEvent = nullptr;
    std::array<std::atomic<uint64_t>, 4> m_frameNumbers{};
    std::atomic<bool> m_stopping{false};
    std::atomic<uint32_t> m_streamMask{0};
    std::atomic<uint32_t> m_driverSettings{0};
    std::atomic<bool> m_rgbHqUnavailable{false};
    mutable std::mutex m_clientsLock;
    std::vector<std::shared_ptr<ClientSession>> m_clients;
    std::mutex m_clientThreadsLock;
    std::vector<std::thread> m_clientThreads;
    mutable std::mutex m_calibrationLock;
    DepthCalibration m_depthCalibration{};

    std::wstring SettingsRegistryPath() const {
        std::wstring id(m_deviceId.begin(), m_deviceId.end());
        return std::wstring(L"SOFTWARE\\Kinect360Remold\\Devices\\") + id;
    }

    void LoadDriverSettings() {
        DWORD value = 0;
        DWORD bytes = sizeof(value);
        const LONG rc = RegGetValueW(
            HKEY_LOCAL_MACHINE,
            SettingsRegistryPath().c_str(),
            L"VirtualRgbHq",
            RRF_RT_REG_DWORD | RRF_SUBKEY_WOW6464KEY,
            nullptr,
            &value,
            &bytes);
        if (rc == ERROR_SUCCESS && value != 0) {
            m_driverSettings.store(ScannerPort::DriverSettingRgbHighQuality, std::memory_order_release);
        }
    }

    HRESULT SaveDriverSettings(uint32_t settings) const {
        HKEY key = nullptr;
        const LONG openRc = RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            SettingsRegistryPath().c_str(),
            0,
            nullptr,
            0,
            KEY_SET_VALUE | KEY_WOW64_64KEY,
            nullptr,
            &key,
            nullptr);
        if (openRc != ERROR_SUCCESS) return HRESULT_FROM_WIN32(openRc);
        const DWORD enabled = (settings & ScannerPort::DriverSettingRgbHighQuality) != 0 ? 1u : 0u;
        const LONG setRc = RegSetValueExW(
            key,
            L"VirtualRgbHq",
            0,
            REG_DWORD,
            reinterpret_cast<const BYTE*>(&enabled),
            sizeof(enabled));
        RegCloseKey(key);
        return setRc == ERROR_SUCCESS ? S_OK : HRESULT_FROM_WIN32(setRc);
    }

    void RecomputeMaskLocked() {
        uint32_t aggregate = 0;
        for (const auto& client : m_clients) aggregate |= client->mask;
        m_streamMask.store(aggregate, std::memory_order_release);
    }

    bool TryAddClient(const std::shared_ptr<ClientSession>& client) {
        std::vector<std::shared_ptr<ClientSession>> superseded;
        {
            std::lock_guard<std::mutex> guard(m_clientsLock);
            if (m_stopping.load(std::memory_order_acquire)) return false;

            // A Studio tab switch creates a new pipe before Java/Windows has
            // necessarily released the superseded RandomAccessFile handle. Treat the
            // newest session from the same process as authoritative instead of
            // letting a stale RGB/IR owner block the next module forever.
            uint32_t aggregate = 0;
            for (const auto& existing : m_clients) {
                if (client->pid != 0 && existing->pid == client->pid) continue;
                aggregate |= existing->mask;
            }
            constexpr uint32_t colorMask = ScannerPort::StreamRgb | ScannerPort::StreamRgbHighQuality;
            if ((client->mask & colorMask) && (aggregate & ScannerPort::StreamInfrared)) return false;
            if ((client->mask & ScannerPort::StreamInfrared) && (aggregate & colorMask)) return false;

            if (client->pid != 0) {
                for (auto it = m_clients.begin(); it != m_clients.end();) {
                    if ((*it)->pid == client->pid) {
                        superseded.push_back(*it);
                        it = m_clients.erase(it);
                    } else {
                        ++it;
                    }
                }
            }
            m_clients.push_back(client);
            RecomputeMaskLocked();
        }
        for (const auto& old : superseded) {
            std::lock_guard<std::mutex> q(old->lock);
            old->stopping = true;
            old->queue.clear();
            old->cv.notify_all();
        }
        return true;
    }

    void RemoveClient(const std::shared_ptr<ClientSession>& client) {
        {
            std::lock_guard<std::mutex> q(client->lock);
            client->stopping = true;
            client->queue.clear();
            client->cv.notify_all();
        }
        std::lock_guard<std::mutex> guard(m_clientsLock);
        m_clients.erase(std::remove(m_clients.begin(), m_clients.end(), client), m_clients.end());
        RecomputeMaskLocked();
    }

    bool StopRequested() const noexcept {
        return !g_run.load() || m_stopping.load(std::memory_order_acquire) ||
               (m_stopEvent && WaitForSingleObject(m_stopEvent, 0) == WAIT_OBJECT_0);
    }

    DWORD WaitIo(HANDLE ioEvent, DWORD timeout) const {
        HANDLE handles[3]{}; DWORD count = 0;
        if (m_stopEvent) handles[count++] = m_stopEvent;
        if (g_stopEvent) handles[count++] = g_stopEvent;
        handles[count++] = ioEvent;
        return WaitForMultipleObjects(count, handles, FALSE, timeout);
    }

    bool TransferExact(HANDLE pipe, void* buffer, DWORD bytes, bool write, DWORD timeoutMs) {
        uint8_t* cursor = static_cast<uint8_t*>(buffer); DWORD total = 0;
        while (total < bytes && !StopRequested()) {
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) return false;
            OVERLAPPED ov{}; ov.hEvent = event; DWORD done = 0;
            BOOL ok = write ? WriteFile(pipe, cursor + total, bytes - total, &done, &ov)
                            : ReadFile(pipe, cursor + total, bytes - total, &done, &ov);
            if (!ok && GetLastError() == ERROR_IO_PENDING) {
                const DWORD wait = WaitIo(event, timeoutMs);
                const DWORD stopCount = (m_stopEvent ? 1u : 0u) + (g_stopEvent ? 1u : 0u);
                if (wait < WAIT_OBJECT_0 + stopCount || wait == WAIT_TIMEOUT) {
                    (void)CancelIoEx(pipe, &ov); (void)GetOverlappedResult(pipe, &ov, &done, TRUE); CloseHandle(event); return false;
                }
                ok = GetOverlappedResult(pipe, &ov, &done, FALSE);
            }
            CloseHandle(event);
            if (!ok || done == 0) return false;
            total += done;
        }
        return total == bytes;
    }

    bool WriteFrame(HANDLE pipe, const QueuedFrame& frame) {
        if (!TransferExact(pipe, const_cast<ScannerPort::FrameHeader*>(&frame.header), static_cast<DWORD>(sizeof(frame.header)), true, 2000)) return false;
        return frame.payload.empty() || TransferExact(pipe, const_cast<uint8_t*>(frame.payload.data()), static_cast<DWORD>(frame.payload.size()), true, 2000);
    }

    bool ClientStillConnected(HANDLE pipe) const noexcept {
        DWORD available = 0;
        if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
            const DWORD e = GetLastError();
            if (e == ERROR_BROKEN_PIPE || e == ERROR_PIPE_NOT_CONNECTED || e == ERROR_NO_DATA) return false;
        }
        ULONG clientPid = 0;
        if (GetNamedPipeClientProcessId(pipe, &clientPid) && clientPid != 0) {
            HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, clientPid);
            if (process) { const DWORD state = WaitForSingleObject(process, 0); CloseHandle(process); if (state == WAIT_OBJECT_0) return false; }
        }
        return true;
    }

    void ServeClient(HANDLE pipe) {
        ScannerPort::Request request{};
        if (!TransferExact(pipe, &request, sizeof(request), false, 5000)) return;
        ScannerPort::Reply reply{};
        if (request.magic != ScannerPort::kMagic || request.version != ScannerPort::kVersion) {
            reply.result = static_cast<int32_t>(HRESULT_FROM_WIN32(ERROR_INVALID_DATA));
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        if (request.command == ScannerPort::Command::GetDriverSettings) {
            reply.acceptedMask = DriverSettings();
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        if (request.command == ScannerPort::Command::SetDriverSettings) {
            const HRESULT settingsHr = SetDriverSettings(request.streamMask);
            reply.result = static_cast<int32_t>(settingsHr);
            reply.acceptedMask = DriverSettings();
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        const uint32_t accepted = request.streamMask & ScannerPort::StreamSupported;
        if (request.command != ScannerPort::Command::SubscribeStreams || !ScannerPort::IsValidStreamMask(request.streamMask)) {
            reply.result = static_cast<int32_t>(E_INVALIDARG);
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        if (!RgbHqAvailable()) {
            reply.capabilities &= ~ScannerPort::CapabilityRgbHighQuality;
            if ((accepted & ScannerPort::StreamRgbHighQuality) != 0) {
                reply.result = static_cast<int32_t>(HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED));
                (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
                return;
            }
        }
        ULONG clientPid = 0;
        (void)GetNamedPipeClientProcessId(pipe, &clientPid);
        auto client = std::make_shared<ClientSession>(accepted, clientPid);
        if (!TryAddClient(client)) {
            reply.result = static_cast<int32_t>(HRESULT_FROM_WIN32(ERROR_BUSY));
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000); return;
        }
        reply.acceptedMask = accepted;
        {
            std::lock_guard<std::mutex> calibrationGuard(m_calibrationLock);
            reply.depthCalibrationValid = m_depthCalibration.valid ? 1u : 0u;
            reply.depthConstShift = m_depthCalibration.constShift;
            reply.depthEmitterDistance = m_depthCalibration.dcmosEmitterDist;
            reply.depthReferenceDistance = m_depthCalibration.referenceDistance;
            reply.depthReferencePixelSize = m_depthCalibration.referencePixelSize;
        }
        if (!TransferExact(pipe, &reply, sizeof(reply), true, 1000)) { RemoveClient(client); return; }

        while (!StopRequested()) {
            std::shared_ptr<QueuedFrame> frame;
            {
                std::unique_lock<std::mutex> lock(client->lock);
                client->cv.wait_for(lock, std::chrono::milliseconds(100), [&] { return client->stopping || !client->queue.empty() || StopRequested(); });
                if (client->stopping || StopRequested()) break;
                if (!ClientStillConnected(pipe)) break;
                if (client->queue.empty()) continue;
                frame = std::move(client->queue.front()); client->queue.pop_front();
            }
            if (frame && !WriteFrame(pipe, *frame)) break;
        }
        RemoveClient(client);
    }

    void ServerLoop() {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        SECURITY_ATTRIBUTES security{}; security.nLength = sizeof(security);
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1, &descriptor, nullptr)) {
            security.lpSecurityDescriptor = descriptor;
        }
        while (!StopRequested()) {
            HANDLE pipe = CreateNamedPipeW(
                m_pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                static_cast<DWORD>(sizeof(ScannerPort::FrameHeader) + ScannerPort::kMaxPayloadBytes),
                static_cast<DWORD>(sizeof(ScannerPort::Request)), 0,
                security.lpSecurityDescriptor ? &security : nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) { CloseHandle(pipe); break; }
            OVERLAPPED ov{}; ov.hEvent = event;
            BOOL connected = ConnectNamedPipe(pipe, &ov);
            if (!connected) {
                const DWORD e = GetLastError();
                if (e == ERROR_PIPE_CONNECTED) connected = TRUE;
                else if (e == ERROR_IO_PENDING) {
                    HANDLE waits[3]{m_stopEvent, g_stopEvent, event};
                    const DWORD wait = WaitForMultipleObjects(3, waits, FALSE, INFINITE);
                    if (wait == WAIT_OBJECT_0 + 2) { DWORD ignored = 0; connected = GetOverlappedResult(pipe, &ov, &ignored, FALSE); }
                    else { (void)CancelIoEx(pipe, &ov); DWORD ignored = 0; (void)GetOverlappedResult(pipe, &ov, &ignored, TRUE); }
                }
            }
            CloseHandle(event);
            if (connected && !StopRequested()) {
                std::lock_guard<std::mutex> guard(m_clientThreadsLock);
                m_clientThreads.emplace_back([this, pipe] {
                    ServeClient(pipe);
                    (void)CancelIoEx(pipe, nullptr); (void)DisconnectNamedPipe(pipe); CloseHandle(pipe);
                });
            } else {
                (void)CancelIoEx(pipe, nullptr); (void)DisconnectNamedPipe(pipe); CloseHandle(pipe);
            }
        }
        if (descriptor) LocalFree(descriptor);
    }
};

// Sole periodic owner of the broker Status request for one physical Kinect.
// Polling runs only while the camera session is online and a frame consumer is
// active. Current() never returns a sample older than the shared validity
// window. Every published frame carries Current() taken at frame completion.
class MotionSampler {
public:
    MotionSampler(std::string deviceId, std::function<bool()> consumerActive)
        : m_deviceId(std::move(deviceId)), m_consumerActive(std::move(consumerActive)) {}
    ~MotionSampler() { Stop(); }
    MotionSampler(const MotionSampler&) = delete;
    MotionSampler& operator=(const MotionSampler&) = delete;

    HRESULT Start() {
        if (m_thread.joinable()) return S_OK;
        m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stopEvent) return HrLastError();
        try {
            m_thread = std::thread([this] { Loop(); });
        } catch (const std::system_error&) {
            CloseHandle(m_stopEvent);
            m_stopEvent = nullptr;
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Stop() {
        if (m_stopEvent) SetEvent(m_stopEvent);
        if (m_thread.joinable()) m_thread.join();
        if (m_stopEvent) CloseHandle(m_stopEvent);
        m_stopEvent = nullptr;
        Clear();
    }

    void Enable(Hardware::Model model) noexcept {
        const Hardware::MotionPolicy policy = Hardware::MotionPolicyFor(model);
        m_pollPeriodMs.store(policy.pollPeriodMs, std::memory_order_release);
        m_staleAfterMs.store(policy.staleAfterMs, std::memory_order_release);
        m_enabled.store(true, std::memory_order_release);
    }

    void Disable() noexcept {
        m_enabled.store(false, std::memory_order_release);
        Clear();
    }

    ScannerPort::MotionSample Current() const {
        std::lock_guard<std::mutex> guard(m_lock);
        if (m_sample.flags == 0 ||
            GetTickCount64() - m_sample.tickMs > m_staleAfterMs.load(std::memory_order_acquire)) return {};
        return m_sample;
    }

private:
    static constexpr DWORD kIdleWaitMs = 50;
    std::string m_deviceId;
    std::function<bool()> m_consumerActive;
    HANDLE m_stopEvent = nullptr;
    std::thread m_thread;
    std::atomic<bool> m_enabled{false};
    std::atomic<uint32_t> m_pollPeriodMs{Hardware::MotionPolicyFor(Hardware::Model::Unknown).pollPeriodMs};
    std::atomic<uint32_t> m_staleAfterMs{Hardware::MotionPolicyFor(Hardware::Model::Unknown).staleAfterMs};
    mutable std::mutex m_lock;
    ScannerPort::MotionSample m_sample{};

    void Clear() {
        std::lock_guard<std::mutex> guard(m_lock);
        m_sample = {};
    }

    void Loop() {
        while (g_run.load()) {
            DWORD waitMs = kIdleWaitMs;
            if (m_enabled.load(std::memory_order_acquire) && m_consumerActive()) {
                ScannerPort::MotionSample sample{};
                if (QueryBrokerMotion(m_deviceId, sample)) {
                    std::lock_guard<std::mutex> guard(m_lock);
                    m_sample = sample;
                }
                waitMs = m_pollPeriodMs.load(std::memory_order_acquire);
            } else {
                Clear();
            }
            if (WaitForSingleObject(m_stopEvent, waitMs) == WAIT_OBJECT_0) break;
        }
    }
};

struct Rgb { int r; int g; int b; };

inline int Clamp8(int v) { return std::clamp(v, 0, 255); }

Rgb DemosaicAt(const uint8_t* bayer, int width, int height, int x, int y) {
    auto at = [&](int sx, int sy) -> int {
        sx = std::clamp(sx, 0, width - 1);
        sy = std::clamp(sy, 0, height - 1);
        return bayer[static_cast<size_t>(sy) * static_cast<size_t>(width) + static_cast<size_t>(sx)];
    };
    const bool yOdd = (y & 1) != 0;
    const bool xOdd = (x & 1) != 0;
    Rgb p{};
    if (!yOdd && !xOdd) { // G R / B G : green on red row
        p.g = at(x,y);
        p.r = (at(x-1,y) + at(x+1,y)) / 2;
        p.b = (at(x,y-1) + at(x,y+1)) / 2;
    } else if (!yOdd && xOdd) { // red
        p.r = at(x,y);
        p.g = (at(x-1,y) + at(x+1,y) + at(x,y-1) + at(x,y+1)) / 4;
        p.b = (at(x-1,y-1) + at(x+1,y-1) + at(x-1,y+1) + at(x+1,y+1)) / 4;
    } else if (yOdd && !xOdd) { // blue
        p.b = at(x,y);
        p.g = (at(x-1,y) + at(x+1,y) + at(x,y-1) + at(x,y+1)) / 4;
        p.r = (at(x-1,y-1) + at(x+1,y-1) + at(x-1,y+1) + at(x+1,y+1)) / 4;
    } else { // green on blue row
        p.g = at(x,y);
        p.r = (at(x,y-1) + at(x,y+1)) / 2;
        p.b = (at(x-1,y) + at(x+1,y)) / 2;
    }
    return p;
}

inline uint8_t RgbToY(const Rgb& p) {
    return static_cast<uint8_t>(Clamp8(((66 * p.r + 129 * p.g + 25 * p.b + 128) >> 8) + 16));
}

void BayerToNv12(const uint8_t* bayer, int srcWidth, int srcHeight,
                 int dstWidth, int dstHeight, uint8_t* nv12) {
    uint8_t* yPlane = nv12;
    uint8_t* uvPlane = nv12 + static_cast<size_t>(dstWidth) * dstHeight;
    for (int y = 0; y < dstHeight; y += 2) {
        for (int x = 0; x < dstWidth; x += 2) {
            auto sample = [&](int dx, int dy) {
                const int sx = std::clamp(static_cast<int>((static_cast<double>(x + dx) + 0.5) * srcWidth / dstWidth), 0, srcWidth - 1);
                const int sy = std::clamp(static_cast<int>((static_cast<double>(y + dy) + 0.5) * srcHeight / dstHeight), 0, srcHeight - 1);
                return DemosaicAt(bayer, srcWidth, srcHeight, sx, sy);
            };
            const Rgb p0 = sample(0,0), p1 = sample(1,0), p2 = sample(0,1), p3 = sample(1,1);
            const size_t y0 = static_cast<size_t>(y) * dstWidth + static_cast<size_t>(x);
            const size_t y1 = y0 + dstWidth;
            yPlane[y0] = RgbToY(p0); yPlane[y0 + 1] = RgbToY(p1);
            if (y + 1 < dstHeight) { yPlane[y1] = RgbToY(p2); yPlane[y1 + 1] = RgbToY(p3); }
            const int r = (p0.r + p1.r + p2.r + p3.r) / 4;
            const int g = (p0.g + p1.g + p2.g + p3.g) / 4;
            const int b = (p0.b + p1.b + p2.b + p3.b) / 4;
            const size_t uv = static_cast<size_t>(y / 2) * dstWidth + static_cast<size_t>(x);
            uvPlane[uv] = static_cast<uint8_t>(Clamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128));
            uvPlane[uv + 1] = static_cast<uint8_t>(Clamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128));
        }
    }
}



// Produce a VGA Bayer frame without demosaicing. The odd/even source coordinate
// is deliberately preserved for every destination pixel, so the GRBG phase stays
// valid while the 1280x1024 sensor image is center-cropped vertically to 960 rows.
// This lets SynKinect Studio own RGB reconstruction instead of the USB bridge.
void DownsampleHqBayerToVga(const uint8_t* source, uint8_t* destination) {
    for (uint32_t y = 0; y < kHeight; ++y) {
        const uint32_t sy = 32u + 4u * (y / 2u) + (y & 1u);
        for (uint32_t x = 0; x < kWidth; ++x) {
            const uint32_t sx = 4u * (x / 2u) + (x & 1u);
            destination[static_cast<size_t>(y) * kWidth + x] =
                source[static_cast<size_t>(sy) * ScannerPort::kRgbHqWidth + sx];
        }
    }
}


class FrameConversionWorker {
public:
    FrameConversionWorker(SharedFramePublisher& publisher,
                          ScannerPortServer& scannerPort,
                          ScannerPort::StreamMode mode,
                          size_t rawBytes)
        : m_publisher(publisher), m_scannerPort(scannerPort),
          m_mode(mode), m_rawBytes(rawBytes),
          m_rawA(rawBytes), m_rawB(rawBytes), m_work(rawBytes),
          m_nv12(kHqNv12Bytes), m_vgaBayer(ScannerPort::kRgbRawPayloadBytes) {}

    ~FrameConversionWorker() { Stop(); }

    HRESULT Start() {
        try {
            m_thread = std::thread([this] { Run(); });
        } catch (const std::system_error&) {
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Submit(const std::vector<uint8_t>& raw, uint64_t captureTickMs,
                const ScannerPort::MotionSample& motion) {
        if (raw.size() != m_rawBytes) return;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            // Latest-frame semantics: overwrite the pending slot instead of
            // letting a slow CPU conversion build an unbounded queue.
            std::vector<uint8_t>& target = m_writeA ? m_rawA : m_rawB;
            std::memcpy(target.data(), raw.data(), m_rawBytes);
            if (m_writeA) { m_captureTickA = captureTickMs; m_motionA = motion; }
            else { m_captureTickB = captureTickMs; m_motionB = motion; }
            m_pendingA = m_writeA;
            m_writeA = !m_writeA;
            m_hasPending = true;
        }
        m_cv.notify_one();
    }

    void Stop() {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_stopping = true;
        }
        m_cv.notify_all();
        if (m_thread.joinable()) m_thread.join();
    }

private:
    SharedFramePublisher& m_publisher;
    ScannerPortServer& m_scannerPort;
    ScannerPort::StreamMode m_mode;
    size_t m_rawBytes;
    std::mutex m_lock;
    std::condition_variable m_cv;
    std::thread m_thread;
    std::vector<uint8_t> m_rawA;
    std::vector<uint8_t> m_rawB;
    std::vector<uint8_t> m_work;
    std::vector<uint8_t> m_nv12;
    std::vector<uint8_t> m_vgaBayer;
    uint64_t m_captureTickA = 0;
    uint64_t m_captureTickB = 0;
    uint64_t m_workCaptureTickMs = 0;
    ScannerPort::MotionSample m_motionA{};
    ScannerPort::MotionSample m_motionB{};
    ScannerPort::MotionSample m_workMotion{};
    bool m_writeA = true;
    bool m_pendingA = true;
    bool m_hasPending = false;
    bool m_stopping = false;

    void Run() {
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(m_lock);
                m_cv.wait(lock, [this] { return m_stopping || m_hasPending; });
                if (m_stopping) break;
                const std::vector<uint8_t>& source = m_pendingA ? m_rawA : m_rawB;
                std::memcpy(m_work.data(), source.data(), m_rawBytes);
                m_workCaptureTickMs = m_pendingA ? m_captureTickA : m_captureTickB;
                m_workMotion = m_pendingA ? m_motionA : m_motionB;
                m_hasPending = false;
            }

            switch (m_mode) {
                case ScannerPort::StreamMode::Rgb: {
                    // Scanner gets the sensor-native GRBG8 frame. Only the Windows
                    // Media Foundation virtual camera needs NV12, so its conversion
                    // stays here while SynKinect Studio reconstructs RGB in user-space.
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::BayerGrbg8,
                                          m_work.data(), m_work.size(), m_workCaptureTickMs, m_workMotion);
                    BayerToNv12(m_work.data(), static_cast<int>(kWidth), static_cast<int>(kHeight),
                                 static_cast<int>(kWidth), static_cast<int>(kHeight), m_nv12.data());
                    m_publisher.SubmitVga(m_nv12.data(), kNv12Bytes, m_workCaptureTickMs, m_workMotion);
                    break;
                }
                case ScannerPort::StreamMode::RgbHighQuality: {
                    // Scanner HQ is lossless sensor Bayer. The virtual camera remains
                    // NV12 for the Windows camera contract. If Scanner also needs the
                    // VGA stream, downsample Bayer while preserving the GRBG phase.
                    m_scannerPort.Publish(ScannerPort::StreamMode::RgbHighQuality, ScannerPort::PixelFormat::BayerGrbg8,
                                          m_work.data(), m_work.size(), m_workCaptureTickMs, m_workMotion);
                    BayerToNv12(m_work.data(), static_cast<int>(ScannerPort::kRgbHqWidth), static_cast<int>(ScannerPort::kRgbHqHeight),
                                 static_cast<int>(kHqWidth), static_cast<int>(kHqHeight), m_nv12.data());
                    m_publisher.SubmitHq(
                        m_nv12.data(), kHqNv12Bytes, m_workCaptureTickMs,
                        m_scannerPort.VirtualRgbHqEnabled(), m_workMotion);
                    if (m_scannerPort.Wants(ScannerPort::StreamMode::Rgb)) {
                        DownsampleHqBayerToVga(m_work.data(), m_vgaBayer.data());
                        m_scannerPort.Publish(ScannerPort::StreamMode::Rgb, ScannerPort::PixelFormat::BayerGrbg8,
                                              m_vgaBayer.data(), m_vgaBayer.size(), m_workCaptureTickMs, m_workMotion);
                    }
                    break;
                }
                case ScannerPort::StreamMode::Infrared:
                    // Keep the native packed 10-bit 640x488 payload intact. Cropping
                    // and unpacking now belong to SynKinect Studio.
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::IrRaw10Packed,
                                          m_work.data(), m_work.size(), m_workCaptureTickMs, m_workMotion);
                    break;
                case ScannerPort::StreamMode::Depth:
                    // Depth has exactly one data path: packed 11-bit sensor data
                    // through ScannerPort. Metric reconstruction belongs to Studio.
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::DepthRaw11Packed,
                                          m_work.data(), m_work.size(), m_workCaptureTickMs, m_workMotion);
                    break;
                default:
                    continue;
            }
            // If Submit() arrived during conversion, m_hasPending is true and
            // the next loop iteration consumes only the newest complete frame.
        }
    }
};

class FrameAssembler {
public:
    FrameAssembler(size_t frameBytes, ULONG packetBytes, uint8_t streamFlag)
        : m_raw(frameBytes),
          m_packetDataBytes(packetBytes > sizeof(VideoPacketHeader)
              ? packetBytes - static_cast<ULONG>(sizeof(VideoPacketHeader)) : 0),
          m_streamFlag(streamFlag) {
        if (m_packetDataBytes) {
            m_packetsPerFrame = static_cast<ULONG>((frameBytes + m_packetDataBytes - 1) / m_packetDataBytes);
            m_lastPacketDataBytes = static_cast<ULONG>(frameBytes -
                static_cast<size_t>(m_packetsPerFrame - 1u) * m_packetDataBytes);
        }
    }

    bool IsValid() const noexcept {
        return !m_raw.empty() && m_packetDataBytes && m_packetsPerFrame && m_lastPacketDataBytes;
    }

    // Isochronous framing counters since the stream last restarted.
    struct Stats {
        uint64_t packets = 0;     // packets with a valid RB header
        uint64_t frames = 0;      // complete frames delivered
        uint64_t syncLosses = 0;  // frames abandoned by framing/sequence errors
    };
    const Stats& GetStats() const noexcept { return m_stats; }

    void Reset() noexcept { ResetSync(); m_stats = {}; }

    bool Push(const uint8_t* packet, ULONG length, std::vector<uint8_t>& completed,
              uint64_t& captureTickMs) {
        if (!IsValid() || !packet || length < sizeof(VideoPacketHeader)) return false;
        VideoPacketHeader h{};
        std::memcpy(&h, packet, sizeof(h));
        if (h.magic[0] != 'R' || h.magic[1] != 'B') return false;
        ++m_stats.packets;
        const uint8_t sof = m_streamFlag | 1;
        const uint8_t mof = m_streamFlag | 2;
        const uint8_t eof = m_streamFlag | 5;

        if (h.flag == sof) {
            m_synced = true;
            m_offset = 0;
            m_packetIndex = 0;
            m_expectedSequence = h.sequence;
            // Timestamp at USB start-of-frame, before RGB demosaic/depth conversion.
            // Both physical endpoints share this host monotonic clock so pairing
            // is independent of conversion cost.
            m_captureTickMs = GetTickCount64();
        } else if (!m_synced) {
            return false;
        }
        if (h.sequence != m_expectedSequence) {
            // Recover a bounded number of lost isochronous packets while keeping
            // fixed-size frames synchronized. This preserves RGB, IR and Depth
            // frame completion on a busy USB 2 host.
            const uint8_t lost = static_cast<uint8_t>(h.sequence - m_expectedSequence);
            if (lost == 0 || lost > kMaxRecoverablePacketLoss ||
                m_packetIndex + lost >= m_packetsPerFrame) {
                ++m_stats.syncLosses;
                ResetSync();
                if (h.flag != sof) return false;
                m_synced = true;
                m_captureTickMs = GetTickCount64();
                m_expectedSequence = h.sequence;
            } else {
                for (uint8_t i = 0; i < lost; ++i) {
                    const ULONG missingBytes = (m_packetIndex == m_packetsPerFrame - 1u)
                        ? m_lastPacketDataBytes : m_packetDataBytes;
                    if (m_offset + missingBytes > m_raw.size()) { ++m_stats.syncLosses; ResetSync(); return false; }
                    std::memset(m_raw.data() + m_offset, 0, missingBytes);
                    m_offset += missingBytes;
                    ++m_packetIndex;
                }
                m_expectedSequence = h.sequence;
            }
        }

        const bool first = (m_packetIndex == 0);
        const bool last = (m_packetIndex == m_packetsPerFrame - 1u);
        const uint8_t expectedFlag = first ? sof : (last ? eof : mof);
        if (h.flag != expectedFlag) {
            ++m_stats.syncLosses;
            ResetSync();
            return false;
        }

        const ULONG payload = length - static_cast<ULONG>(sizeof(VideoPacketHeader));
        const ULONG expectedPayload = last ? m_lastPacketDataBytes : m_packetDataBytes;
        if (payload > expectedPayload || m_offset + expectedPayload > m_raw.size()) {
            ++m_stats.syncLosses;
            ResetSync();
            return false;
        }

        std::memcpy(m_raw.data() + m_offset, packet + sizeof(VideoPacketHeader), payload);
        if (payload < expectedPayload)
            std::memset(m_raw.data() + m_offset + payload, 0, expectedPayload - payload);
        m_offset += expectedPayload;
        ++m_packetIndex;
        m_expectedSequence = static_cast<uint8_t>(h.sequence + 1);

        if (last) {
            const bool complete = (m_packetIndex == m_packetsPerFrame && m_offset == m_raw.size());
            const uint64_t completedCaptureTickMs = m_captureTickMs;
            ResetSync();
            if (complete) {
                ++m_stats.frames;
                completed.assign(m_raw.begin(), m_raw.end());
                captureTickMs = completedCaptureTickMs;
                return true;
            }
        }
        return false;
    }

private:
    std::vector<uint8_t> m_raw;
    ULONG m_packetDataBytes = 0;
    ULONG m_packetsPerFrame = 0;
    ULONG m_lastPacketDataBytes = 0;
    uint8_t m_streamFlag = 0;
    size_t m_offset = 0;
    ULONG m_packetIndex = 0;
    uint8_t m_expectedSequence = 0;
    bool m_synced = false;
    uint64_t m_captureTickMs = 0;
    Stats m_stats{};

    void ResetSync() noexcept {
        m_synced = false;
        m_captureTickMs = 0;
        m_offset = 0;
        m_packetIndex = 0;
    }
};

struct CameraInterfaceInfo {
    std::string id;
    std::string label;
    std::wstring path;
};

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<size_t>(bytes), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), out.data(), bytes, nullptr, nullptr)) return {};
    return out;
}

std::vector<CameraInterfaceInfo> EnumerateCameraInterfaces() {
    std::vector<CameraInterfaceInfo> out;
    HDEVINFO info = SetupDiGetClassDevsW(&Hardware::kCameraTransportGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (info == INVALID_HANDLE_VALUE) return out;
    for (DWORD i = 0;; ++i) {
        SP_DEVICE_INTERFACE_DATA iface{}; iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(info, nullptr, &Hardware::kCameraTransportGuid, i, &iface)) break;
        DWORD needed = 0;
        SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
        (void)SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &needed, nullptr);
        if (needed < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(needed);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data()); detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, needed, nullptr, &dev)) continue;
        // Prefer the physical USB location path for identity. Kinect 1473
        // cameras advertise the placeholder serial 0000000000000000, so hashing
        // the instance ID can collide across sensors or change after PnP
        // re-enumeration. LocationPaths stays unique per attached USB port and
        // matches the installer's port-scoped identity policy for bcdDevice 02.05.
        std::string stableId = Kinect360RemoldIdentity::DeviceId(info, dev);
        if (stableId.empty()) {
            stableId = Kinect360RemoldIdentity::DeviceIdFromLocation(detail->DevicePath);
        }
        CameraInterfaceInfo item;
        item.id = stableId;
        // Same display name as Linux: the model; the stable ID is a separate field.
        const Hardware::Model model = Kinect360RemoldIdentity::ModelFromHardwareIds(info, dev);
        item.label = model == Hardware::Model::Unknown ? std::string("Kinect") : std::string("Kinect ") + Hardware::ModelName(model);
        item.path = detail->DevicePath;
        out.push_back(std::move(item));
    }
    SetupDiDestroyDeviceInfoList(info);
    std::sort(out.begin(), out.end(), [](const CameraInterfaceInfo& a, const CameraInterfaceInfo& b) { return a.id < b.id; });
    return out;
}


class CameraUsbTransport {
public:
    ~CameraUsbTransport() { Close(); }

    HRESULT Open(const std::wstring& devicePath, const std::string& deviceId, bool startupOpen) {
        Close();
        m_deviceId = deviceId;
        m_file = CreateFileW(devicePath.c_str(), GENERIC_READ | GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                             FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (m_file == INVALID_HANDLE_VALUE) return HrLastError();
        if (!WinUsb_Initialize(m_file, &m_usb)) { const HRESULT hr = HrLastError(); Close(); return hr; }
        DetectHardwareModel();

        const unsigned attempts = startupOpen ? 20u : 1u;
        bool prepared = false;
        for (unsigned attempt = 0; attempt < attempts && g_run.load(); ++attempt) {
            if (PrepareCameraControl(m_deviceId)) { prepared = true; break; }
            if (attempt + 1u < attempts) Sleep(250);
        }
        if (!prepared && startupOpen)
            Log(L"Kinect physical control preparation is unavailable; continuing with the camera transport.");

        HRESULT result = FindCommonIsoPipes();
        if (FAILED(result)) { Close(); return result; }
        const HRESULT calibrationHr = FetchDepthCalibration(m_depthCalibration);
        if (FAILED(calibrationHr)) {
            LogHr(L"Factory depth calibration query failed; raw depth remains available but Studio metric depth is unavailable", calibrationHr);
            m_depthCalibration = DepthCalibration{};
        }
        return S_OK;
    }

    Hardware::Model HardwareModel() const noexcept { return m_model; }

    HRESULT Run(SharedFramePublisher& publisher, ScannerPortServer& scannerPort,
                const MotionSampler& motion, const std::atomic<bool>* ownerRun) {
        if (!m_usb || !m_video.maxBytes || !m_depth.maxBytes) return E_HANDLE;
        m_ownerRun = ownerRun;

        // virtual camera is RGB-only. Endpoint 0x81 is one exclusive video engine:
        // it runs RGB by default and switches to IR only while a scanner client explicitly
        // requests IR. Endpoint 0x82 carries Depth independently and can run concurrently
        // with the selected 0x81 mode. Every completed frame carries the
        // latest MotionSampler sample, exactly like the Linux ScannerPort.
        scannerPort.SetDepthCalibration(m_depthCalibration);
        FrameConversionWorker rgbWorker(publisher, scannerPort,
                                        ScannerPort::StreamMode::Rgb, kRgbRawFrameBytes);
        FrameConversionWorker rgbHqWorker(publisher, scannerPort,
                                          ScannerPort::StreamMode::RgbHighQuality, kRgbHqRawFrameBytes);
        FrameConversionWorker irWorker(publisher, scannerPort,
                                       ScannerPort::StreamMode::Infrared, kIrRawFrameBytes);
        FrameConversionWorker depthWorker(publisher, scannerPort,
                                          ScannerPort::StreamMode::Depth, kDepthRawFrameBytes);
        HRESULT hr = rgbWorker.Start();
        if (FAILED(hr)) return hr;
        hr = rgbHqWorker.Start();
        if (FAILED(hr)) { rgbWorker.Stop(); return hr; }
        hr = irWorker.Start();
        if (FAILED(hr)) { rgbHqWorker.Stop(); rgbWorker.Stop(); return hr; }
        hr = depthWorker.Start();
        if (FAILED(hr)) { irWorker.Stop(); rgbHqWorker.Stop(); rgbWorker.Stop(); return hr; }

        m_sessionRun.store(true, std::memory_order_release);
        std::thread depthThread;
        try {
            depthThread = std::thread([this, &scannerPort, &motion, &depthWorker] {
                DepthLoop(scannerPort, motion, depthWorker);
            });
        } catch (const std::system_error&) {
            m_sessionRun.store(false, std::memory_order_release);
            depthWorker.Stop(); irWorker.Stop(); rgbHqWorker.Stop(); rgbWorker.Stop();
            return E_OUTOFMEMORY;
        }

        // A broken video engine invalidates the current WinUSB camera session.
        // Return to CameraNode so only this physical Kinect is closed and
        // reopened from a fresh handle.
        hr = StreamVideo(publisher, scannerPort, motion, rgbWorker, rgbHqWorker, irWorker);
        m_sessionRun.store(false, std::memory_order_release);
        if (depthThread.joinable()) depthThread.join();

        (void)SetProjector(false);
        (void)StopVideoCapture();
        depthWorker.Stop();
        irWorker.Stop();
        rgbHqWorker.Stop();
        rgbWorker.Stop();
        m_ownerRun = nullptr;
        return hr;
    }

private:
    struct IsoSlot { OVERLAPPED ov{}; HANDLE event = nullptr; bool pending = false; };
    struct PipeGeometry { UCHAR pipeId = 0; ULONG maxBytes = 0; UCHAR interval = 0; };

    HANDLE m_file = INVALID_HANDLE_VALUE;
    std::string m_deviceId;
    WINUSB_INTERFACE_HANDLE m_usb = nullptr;
    PipeGeometry m_video{};
    PipeGeometry m_depth{};
    uint16_t m_tag = 0;
    std::mutex m_controlLock;
    std::atomic<bool> m_sessionRun{false};
    const std::atomic<bool>* m_ownerRun = nullptr;
    bool m_projectorOn = false; // guarded by m_controlLock
    Hardware::Model m_model = Hardware::Model::Unknown;
    DepthCalibration m_depthCalibration{};

    bool SessionRunning() const noexcept {
        return g_run.load() && m_sessionRun.load(std::memory_order_acquire) &&
               (!m_ownerRun || m_ownerRun->load(std::memory_order_acquire));
    }

    void Close() {
        if (m_usb) {
            (void)SetProjector(false);
            WinUsb_Free(m_usb);
            m_usb = nullptr;
        }
        if (m_file != INVALID_HANDLE_VALUE) { CloseHandle(m_file); m_file = INVALID_HANDLE_VALUE; }
        m_video = PipeGeometry{};
        m_depth = PipeGeometry{};
        m_tag = 0;
        m_projectorOn = false;
        m_model = Hardware::Model::Unknown;
        m_depthCalibration = DepthCalibration{};
    }

    void LogStream(const wchar_t* what, const FrameAssembler::Stats& stats, ULONGLONG elapsedMs) const {
        wchar_t message[320]{};
        swprintf_s(message, L"Camera %hs (%hs): %ls - %llu ms, %llu packets, %llu frames, %llu sync losses.",
                   m_deviceId.c_str(), Hardware::ModelName(m_model), what,
                   static_cast<unsigned long long>(elapsedMs), static_cast<unsigned long long>(stats.packets),
                   static_cast<unsigned long long>(stats.frames), static_cast<unsigned long long>(stats.syncLosses));
        Log(message);
    }

    void DetectHardwareModel() {
        m_model = Hardware::Model::Unknown;
        if (!m_usb) return;
        USB_DEVICE_DESCRIPTOR descriptor{};
        ULONG transferred = 0;
        if (!WinUsb_GetDescriptor(m_usb, USB_DEVICE_DESCRIPTOR_TYPE, 0, 0,
                                  reinterpret_cast<PUCHAR>(&descriptor), sizeof(descriptor), &transferred) ||
            transferred < sizeof(descriptor) || descriptor.idVendor != Hardware::kVendorId) return;
        m_model = Hardware::ModelFromCamera(descriptor.idProduct, descriptor.bcdDevice);
        const Hardware::MotionPolicy policy = Hardware::MotionPolicyFor(m_model);
        wchar_t message[192]{};
        swprintf_s(message, L"Kinect %hs camera profile (02AE bcdDevice=%x.%02x): motion poll %u ms, stale after %u ms.",
                   Hardware::ModelName(m_model), (descriptor.bcdDevice >> 8) & 0xff, descriptor.bcdDevice & 0xff,
                   policy.pollPeriodMs, policy.staleAfterMs);
        Log(message);
    }

    static void CloseSlots(std::vector<IsoSlot>& slots) {
        for (auto& slot : slots) {
            if (slot.event) CloseHandle(slot.event);
            slot.event = nullptr;
            slot.pending = false;
        }
    }

    HRESULT CancelPendingIsoReads(const PipeGeometry& pipe, std::vector<IsoSlot>& slots,
                                  bool forcePipeRecovery) {
        if (!m_usb || !pipe.pipeId) return E_HANDLE;
        HRESULT cancelHr = S_OK;
        for (auto& slot : slots) {
            if (slot.pending) (void)CancelIoEx(m_file, &slot.ov);
        }

        const ULONGLONG deadline = GetTickCount64() + kIsoCancelDeadlineMs;
        bool needAbort = false;
        for (auto& slot : slots) {
            if (!slot.pending) continue;
            const ULONGLONG now = GetTickCount64();
            const DWORD remaining = now < deadline
                ? static_cast<DWORD>((std::min)(deadline - now, static_cast<ULONGLONG>(kIsoCancelDeadlineMs)))
                : 0u;
            const DWORD wait = WaitForSingleObject(slot.event, remaining);
            if (wait != WAIT_OBJECT_0) {
                needAbort = true;
                if (wait == WAIT_FAILED && SUCCEEDED(cancelHr)) cancelHr = HrLastError();
                continue;
            }
            DWORD ignored = 0;
            if (!WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, FALSE)) {
                const DWORD error = GetLastError();
                if (error != ERROR_OPERATION_ABORTED && error != ERROR_CANCELLED && SUCCEEDED(cancelHr))
                    cancelHr = HRESULT_FROM_WIN32(error);
            }
            slot.pending = false;
        }

        if (needAbort) {
            (void)WinUsb_AbortPipe(m_usb, pipe.pipeId);
            for (auto& slot : slots) {
                if (!slot.pending) continue;
                DWORD ignored = 0;
                (void)WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, TRUE);
                slot.pending = false;
            }
        }

        if ((forcePipeRecovery || needAbort) &&
            !WinUsb_ResetPipe(m_usb, pipe.pipeId) && SUCCEEDED(cancelHr))
            cancelHr = HrLastError();
        return cancelHr;
    }

    HRESULT FindCommonIsoPipes() {
        // Both isochronous endpoints must be available under the same alternate
        // setting so WinUSB can keep the video and Depth endpoints registered concurrently.
        for (UCHAR alt = 0; alt < 16; ++alt) {
            USB_INTERFACE_DESCRIPTOR iface{};
            if (!WinUsb_QueryInterfaceSettings(m_usb, alt, &iface)) {
                const DWORD e = GetLastError();
                if (e == ERROR_NO_MORE_ITEMS || e == ERROR_INVALID_PARAMETER) break;
                continue;
            }
            PipeGeometry video{CameraUsb::kVideoInEndpoint, 0, 0};
            PipeGeometry depth{CameraUsb::kDepthInEndpoint, 0, 0};
            for (UCHAR i = 0; i < iface.bNumEndpoints; ++i) {
                WINUSB_PIPE_INFORMATION_EX ex{};
                if (WinUsb_QueryPipeEx(m_usb, alt, i, &ex)) {
                    if (ex.PipeType != UsbdPipeTypeIsochronous) continue;
                    PipeGeometry* target = ex.PipeId == CameraUsb::kVideoInEndpoint ? &video : (ex.PipeId == CameraUsb::kDepthInEndpoint ? &depth : nullptr);
                    if (!target) continue;
                    target->maxBytes = ex.MaximumBytesPerInterval ? ex.MaximumBytesPerInterval : ex.MaximumPacketSize;
                    target->interval = ex.Interval;
                } else {
                    WINUSB_PIPE_INFORMATION basic{};
                    if (!WinUsb_QueryPipe(m_usb, alt, i, &basic) || basic.PipeType != UsbdPipeTypeIsochronous) continue;
                    PipeGeometry* target = basic.PipeId == CameraUsb::kVideoInEndpoint ? &video : (basic.PipeId == CameraUsb::kDepthInEndpoint ? &depth : nullptr);
                    if (!target) continue;
                    target->maxBytes = basic.MaximumPacketSize;
                    target->interval = basic.Interval;
                }
            }
            if (!video.maxBytes || !video.interval || !depth.maxBytes || !depth.interval) continue;
            if (alt != 0 && !WinUsb_SetCurrentAlternateSetting(m_usb, alt)) return HrLastError();
            m_video = video;
            m_depth = depth;
            wchar_t message[192]{};
            swprintf_s(message,
                       L"ISO interface selected: alt=%u video(max=%lu interval=%u) depth(max=%lu interval=%u), batch=%lu.",
                       alt, video.maxBytes, video.interval, depth.maxBytes, depth.interval,
                       CameraUsb::kIsoPacketsPerTransfer);
            Log(message);
            return S_OK;
        }
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    static bool ComputeIsoGeometry(const PipeGeometry& pipe, ULONG& transferBytes, ULONG& packetCount) {
        // WinUSB exposes the effective high-speed polling period here (1, 2,
        // 4 or 8 microframes). A transfer must contain complete USB frames.
        if (!pipe.maxBytes || !pipe.interval || pipe.interval > 8 ||
            (8u % pipe.interval) != 0) return false;
        const ULONG packetsPerUsbFrame = 8u / pipe.interval;
        packetCount = CameraUsb::kIsoPacketsPerTransfer;
        if ((packetCount % packetsPerUsbFrame) != 0) return false;
        if (pipe.maxBytes > std::numeric_limits<ULONG>::max() / packetCount) return false;
        transferBytes = pipe.maxBytes * packetCount;
        return true;
    }

    HRESULT SendCommandUnlocked(uint16_t command, const void* payload, USHORT payloadBytes,
                                void* reply, USHORT replyCapacity, USHORT& replyBytes) {
        replyBytes = 0;
        if ((payloadBytes & 1u) || payloadBytes > 0x3F8u) return E_INVALIDARG;
        std::array<uint8_t, 0x400> out{};
        CameraCommandHeader h{{0x47,0x4d}, static_cast<uint16_t>(payloadBytes/2), command, m_tag};
        std::memcpy(out.data(), &h, sizeof(h));
        if (payloadBytes) std::memcpy(out.data()+sizeof(h), payload, payloadBytes);
        WINUSB_SETUP_PACKET setupOut{0x40,0,0,0,static_cast<USHORT>(sizeof(h)+payloadBytes)};
        ULONG sent = 0;
        if (!WinUsb_ControlTransfer(m_usb, setupOut, out.data(), setupOut.Length, &sent, nullptr)) return HrLastError();
        if (sent != setupOut.Length) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);

        std::array<uint8_t, 0x200> in{};
        ULONG got = 0;
        const ULONGLONG deadline = GetTickCount64() + kControlReplyDeadlineMs;
        for (;;) {
            WINUSB_SETUP_PACKET setupIn{0xC0,0,0,0,static_cast<USHORT>(in.size())};
            if (!WinUsb_ControlTransfer(m_usb, setupIn, in.data(), static_cast<ULONG>(in.size()), &got, nullptr))
                return HrLastError();
            if (got != 0 && got != in.size()) break;
            if (GetTickCount64() >= deadline) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
            Sleep(1);
        }
        if (got < sizeof(CameraCommandHeader)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        CameraCommandHeader rh{};
        std::memcpy(&rh, in.data(), sizeof(rh));
        if (rh.magic[0] != 0x52 || rh.magic[1] != 0x42 || rh.command != command || rh.tag != m_tag)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        const ULONG dataBytes = got - sizeof(rh);
        if (rh.lengthWords != dataBytes/2 || dataBytes > replyCapacity)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (dataBytes && reply) std::memcpy(reply, in.data()+sizeof(rh), dataBytes);
        replyBytes = static_cast<USHORT>(dataBytes);
        ++m_tag;
        return S_OK;
    }

    HRESULT WriteRegisterUnlocked(uint16_t reg, uint16_t value) {
        uint16_t cmd[2]{reg,value};
        uint16_t reply[2]{};
        USHORT bytes = 0;
        HRESULT hr = SendCommandUnlocked(0x03, cmd, sizeof(cmd), reply, sizeof(reply), bytes);
        if (FAILED(hr)) return hr;
        return bytes < sizeof(uint16_t) ? HRESULT_FROM_WIN32(ERROR_INVALID_DATA) : S_OK;
    }

    HRESULT SetProjector(bool on) {
        std::lock_guard<std::mutex> guard(m_controlLock);
        if (!m_usb) return E_HANDLE;
        if (m_projectorOn == on) return S_OK;
        const HRESULT hr = WriteRegisterUnlocked(0x06, on ? 0x02 : 0x00);
        if (SUCCEEDED(hr)) m_projectorOn = on;
        return hr;
    }

    HRESULT ConfigureVideoModeRegisters(ScannerPort::StreamMode mode) {
        if (mode != ScannerPort::StreamMode::Rgb &&
            mode != ScannerPort::StreamMode::RgbHighQuality &&
            mode != ScannerPort::StreamMode::Infrared) return E_INVALIDARG;
        std::lock_guard<std::mutex> guard(m_controlLock);
        HRESULT hr = S_OK;
        // Endpoint 0x81 is stopped while mode registers are changed. RGB and
        // RGB HQ share the same Bayer path; only resolution and frame rate differ.
        if (mode == ScannerPort::StreamMode::Rgb ||
            mode == ScannerPort::StreamMode::RgbHighQuality) {
            hr = WriteRegisterUnlocked(0x0c, 0x00);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(
                0x0d, mode == ScannerPort::StreamMode::RgbHighQuality ? 0x02 : 0x01);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(
                0x0e, mode == ScannerPort::StreamMode::RgbHighQuality ? 0x0f : 0x1e);
            return hr;
        }

        hr = WriteRegisterUnlocked(0x19, 0x00);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x1a, 0x01);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x1b, 0x1e);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x105, 0x00);
        return hr;
    }

    HRESULT StartVideoCapture(ScannerPort::StreamMode mode) {
        std::lock_guard<std::mutex> guard(m_controlLock);
        if (!m_usb) return E_HANDLE;
        HRESULT hr = WriteRegisterUnlocked(0x05,
            mode == ScannerPort::StreamMode::Infrared ? 0x03 : 0x01);
        if (FAILED(hr)) return hr;
        return WriteRegisterUnlocked(
            mode == ScannerPort::StreamMode::Infrared ? 0x48 : 0x47, 0x00);
    }

    HRESULT StopVideoCapture() {
        std::lock_guard<std::mutex> guard(m_controlLock);
        return m_usb ? WriteRegisterUnlocked(0x05, 0x00) : E_HANDLE;
    }

    HRESULT ConfigureDepthPath() {
        std::lock_guard<std::mutex> guard(m_controlLock);
        // Start every depth endpoint session from a known OFF state so a timed-out
        // session cannot leave software state ahead of the physical depth engine.
        HRESULT hr = WriteRegisterUnlocked(0x105, 0x00);
        if (SUCCEEDED(hr)) {
            hr = WriteRegisterUnlocked(0x06, 0x00);
            if (SUCCEEDED(hr)) m_projectorOn = false;
        }
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x12, 0x03);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x13, 0x01);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x14, 0x1e);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x17, 0x00);
        return hr;
    }

    HRESULT FetchDepthCalibration(DepthCalibration& calibration) {
        std::lock_guard<std::mutex> guard(m_controlLock);
        calibration = DepthCalibration{};
        uint16_t fixedRequest[5]{};
        std::array<uint8_t, 0x200> fixedReply{};
        USHORT fixedBytes = 0;
        HRESULT hr = SendCommandUnlocked(0x04, fixedRequest, sizeof(fixedRequest),
                                         fixedReply.data(), static_cast<USHORT>(fixedReply.size()), fixedBytes);
        if (FAILED(hr)) return hr;
        if (fixedBytes < 94u + 4u * sizeof(float)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        float values[4]{};
        std::memcpy(values, fixedReply.data() + 94, sizeof(values));
        const float emitter = values[0];
        const float referenceDistance = values[2];
        const float referencePixelSize = values[3];
        if (!std::isfinite(emitter) || !std::isfinite(referenceDistance) || !std::isfinite(referencePixelSize) ||
            emitter <= 0.0f || referenceDistance <= 0.0f || referencePixelSize <= 0.0f)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        uint16_t shiftRequest[5]{0x0000, 0x0000, 0x0001, 0x001e, 0x0000};
        std::array<uint8_t, 8> shiftReply{};
        USHORT shiftBytes = 0;
        hr = SendCommandUnlocked(0x16, shiftRequest, sizeof(shiftRequest),
                                 shiftReply.data(), static_cast<USHORT>(shiftReply.size()), shiftBytes);
        if (FAILED(hr)) return hr;
        if (shiftBytes < 4) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        uint16_t shift = 0;
        std::memcpy(&shift, shiftReply.data() + 2, sizeof(shift));
        if (!shift) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        calibration.constShift = static_cast<double>(shift);
        calibration.dcmosEmitterDist = static_cast<double>(emitter);
        calibration.referenceDistance = static_cast<double>(referenceDistance);
        calibration.referencePixelSize = static_cast<double>(referencePixelSize);
        calibration.valid = true;
        return S_OK;
    }

    HRESULT StreamVideo(SharedFramePublisher& publisher,
                        ScannerPortServer& scannerPort,
                        const MotionSampler& motion,
                        FrameConversionWorker& rgbWorker,
                        FrameConversionWorker& rgbHqWorker,
                        FrameConversionWorker& irWorker) {
        ULONG transferBytes = 0, packetCount = 0;
        if (!ComputeIsoGeometry(m_video, transferBytes, packetCount)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (transferBytes > std::numeric_limits<ULONG>::max() / CameraUsb::kIsoQueueDepth)
            return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
        const ULONG totalBytes = transferBytes * CameraUsb::kIsoQueueDepth;
        std::vector<uint8_t> io(totalBytes);
        std::vector<USBD_ISO_PACKET_DESCRIPTOR> desc(static_cast<size_t>(packetCount) * CameraUsb::kIsoQueueDepth);
        std::vector<IsoSlot> slots(CameraUsb::kIsoQueueDepth);
        for (auto& slot : slots) {
            slot.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!slot.event) { CloseSlots(slots); return HrLastError(); }
            slot.ov.hEvent = slot.event;
        }
        WINUSB_ISOCH_BUFFER_HANDLE iso = nullptr;
        auto queueRead = [&](ULONG index, BOOL continueStream) -> bool {
            if (!iso) return false;
            IsoSlot& slot = slots[index];
            auto* packets = desc.data() + static_cast<size_t>(index) * packetCount;
            std::fill(packets, packets + packetCount, USBD_ISO_PACKET_DESCRIPTOR{});
            ResetEvent(slot.event); slot.ov = OVERLAPPED{}; slot.ov.hEvent = slot.event;
            BOOL ok = WinUsb_ReadIsochPipeAsap(iso, index * transferBytes, transferBytes,
                                               continueStream, packetCount, packets, &slot.ov);
            if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
            slot.pending = true; return true;
        };
        auto cancelVideoReads = [&](bool forcePipeRecovery) -> HRESULT {
            if (!iso) return S_OK;
            return CancelPendingIsoReads(m_video, slots, forcePipeRecovery);
        };
        auto unregisterVideoIso = [&]() -> HRESULT {
            if (!iso) return S_OK;
            HRESULT hr = S_OK;
            if (!WinUsb_UnregisterIsochBuffer(iso)) hr = HrLastError();
            iso = nullptr;
            return hr;
        };
        auto registerVideoIso = [&]() -> HRESULT {
            if (iso) return S_OK;
            if (!WinUsb_RegisterIsochBuffer(m_usb, m_video.pipeId, io.data(), totalBytes, &iso))
                return HrLastError();
            return S_OK;
        };
        auto queueAllVideoReads = [&]() -> HRESULT {
            for (ULONG i = 0; i < CameraUsb::kIsoQueueDepth; ++i) {
                // The first request establishes an ASAP start frame; following
                // requests extend that same schedule, matching one continuous
                // libusb ISO queue without overlapping ASAP frame ranges.
                if (!queueRead(i, i == 0 ? FALSE : TRUE)) return HrLastError();
            }
            return S_OK;
        };

        // The isochronous buffer stays registered for the whole physical
        // session; repeated Register/Unregister cycles can leave endpoint 0x81
        // stale. The firmware video engine runs only while a consumer wants
        // video, exactly like the Linux camera service: a ScannerPort RGB, RGB
        // HQ or IR subscription, or a renewed frame consumer lease (virtual
        // camera, IP camera).
        HRESULT result = registerVideoIso();
        auto videoDemand = [&]() noexcept {
            return scannerPort.Wants(ScannerPort::StreamMode::Rgb) ||
                   scannerPort.Wants(ScannerPort::StreamMode::RgbHighQuality) ||
                   scannerPort.Wants(ScannerPort::StreamMode::Infrared) ||
                   publisher.ConsumerLeaseActive();
        };
        auto demandedMode = [&]() noexcept {
            if (scannerPort.Wants(ScannerPort::StreamMode::Infrared)) return ScannerPort::StreamMode::Infrared;
            if (scannerPort.Wants(ScannerPort::StreamMode::RgbHighQuality) || scannerPort.VirtualRgbHqEnabled())
                return ScannerPort::StreamMode::RgbHighQuality;
            return ScannerPort::StreamMode::Rgb;
        };
        ScannerPort::StreamMode activeMode = demandedMode();
        bool videoRunning = false;

        FrameAssembler rgbAssembler(kRgbRawFrameBytes, CameraUsb::kVideoPacketBytes, kVideoFlag);
        FrameAssembler rgbHqAssembler(kRgbHqRawFrameBytes, CameraUsb::kVideoPacketBytes, kVideoFlag);
        FrameAssembler irAssembler(kIrRawFrameBytes, CameraUsb::kVideoPacketBytes, kVideoFlag);
        if (!rgbAssembler.IsValid() || !rgbHqAssembler.IsValid() || !irAssembler.IsValid())
            result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        std::vector<uint8_t> completeRaw;
        uint64_t completeCaptureTickMs = 0;
        int timeouts = 0;
        ULONGLONG lastCompleteFrameAt = GetTickCount64();
        ULONGLONG modeStartedAt = lastCompleteFrameAt;
        std::vector<HANDLE> waitHandles;
        waitHandles.reserve(CameraUsb::kIsoQueueDepth + 1u);
        if (g_stopEvent) waitHandles.push_back(g_stopEvent);
        const DWORD slotWaitBase = static_cast<DWORD>(waitHandles.size());
        for (const auto& slot : slots) waitHandles.push_back(slot.event);

        Log(L"Kinect video endpoint 0x81 ready: RGB mode follows the per-device driver setting; IR remains an explicit client mode.");
        while (SUCCEEDED(result) && SessionRunning()) {
            if (!videoDemand()) {
                if (videoRunning) {
                    publisher.SetOnline(false);
                    result = StopVideoCapture();
                    if (FAILED(result)) break;
                    Sleep(15);
                    result = cancelVideoReads(false);
                    if (FAILED(result)) break;
                    videoRunning = false;
                    Log(L"No video consumer; Kinect video engine stopped.");
                }
                if (g_stopEvent) WaitForSingleObject(g_stopEvent, kScannerStatePollMs);
                else Sleep(kScannerStatePollMs);
                continue;
            }
            if (!videoRunning) {
                // Arm isochronous reads before register 0x05 starts the video
                // engine, directly in the mode already requested.
                activeMode = demandedMode();
                if (activeMode == ScannerPort::StreamMode::Infrared) result = SetProjector(true);
                if (SUCCEEDED(result)) result = ConfigureVideoModeRegisters(activeMode);
                if (SUCCEEDED(result)) result = queueAllVideoReads();
                if (SUCCEEDED(result)) result = StartVideoCapture(activeMode);
                if (FAILED(result)) break;
                videoRunning = true;
                timeouts = 0;
                lastCompleteFrameAt = GetTickCount64();
                modeStartedAt = lastCompleteFrameAt;
                rgbAssembler.Reset(); rgbHqAssembler.Reset(); irAssembler.Reset();
                Log(L"Video consumer active; Kinect video engine started.");
            }

            const ULONGLONG now = GetTickCount64();
            const DWORD frameTimeoutMs = activeMode == ScannerPort::StreamMode::RgbHighQuality
                ? kRgbHqFrameTimeoutMs : kVideoFrameTimeoutMs;
            if (now - lastCompleteFrameAt >= frameTimeoutMs) {
                if (activeMode == ScannerPort::StreamMode::RgbHighQuality && rgbHqAssembler.GetStats().frames == 0) {
                    // HQ never completed a frame on this sensor: fall back to VGA
                    // in place, exactly like the Linux camera service.
                    LogStream(L"RGB HQ delivered no complete frame; RGB HQ disabled for this connection",
                              rgbHqAssembler.GetStats(), now - modeStartedAt);
                    scannerPort.MarkRgbHqUnavailable();
                    lastCompleteFrameAt = now;
                    continue;
                }
                const FrameAssembler& stalled = activeMode == ScannerPort::StreamMode::Rgb ? rgbAssembler :
                    (activeMode == ScannerPort::StreamMode::RgbHighQuality ? rgbHqAssembler : irAssembler);
                LogStream(activeMode == ScannerPort::StreamMode::Infrared
                              ? L"IR stopped producing frames; restarting the physical camera session"
                              : L"RGB stopped producing frames; restarting the physical camera session",
                          stalled.GetStats(), now - modeStartedAt);
                result = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                break;
            }

            const ScannerPort::StreamMode requestedMode = demandedMode();

            if (requestedMode != activeMode) {
                // Stop only the firmware video engine and outstanding reads.
                // Keep the WinUSB isoch buffer registered across module handoffs:
                // repeated Register/Unregister cycles are precisely the lifetime
                // churn that can leave endpoint 0x81 stale on the second open.
                publisher.SetOnline(false);
                result = StopVideoCapture();
                if (FAILED(result)) break;
                Sleep(15);
                result = cancelVideoReads(false);
                if (FAILED(result)) break;

                if (requestedMode == ScannerPort::StreamMode::Infrared) {
                    result = SetProjector(true);
                    if (FAILED(result)) break;
                } else if (!scannerPort.NeedsProjector()) {
                    result = SetProjector(false);
                    if (FAILED(result)) break;
                }
                result = ConfigureVideoModeRegisters(requestedMode);
                if (FAILED(result)) break;
                result = queueAllVideoReads();
                if (FAILED(result)) break;
                result = StartVideoCapture(requestedMode);
                if (FAILED(result)) break;

                activeMode = requestedMode;
                timeouts = 0;
                lastCompleteFrameAt = GetTickCount64();
                modeStartedAt = lastCompleteFrameAt;
                rgbAssembler.Reset(); rgbHqAssembler.Reset(); irAssembler.Reset();
            }

            const DWORD wait = WaitForMultipleObjects(
                static_cast<DWORD>(waitHandles.size()), waitHandles.data(), FALSE, kIsoWaitMs);
            if (wait == WAIT_TIMEOUT) {
                if (++timeouts >= kMaxIsoTimeouts) {
                    Log(L"Video ISO queue stalled; restarting the physical camera session.");
                    result = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                    break;
                }
                continue;
            }
            if (wait == WAIT_FAILED) { result = HrLastError(); break; }
            if (wait < WAIT_OBJECT_0 || wait >= WAIT_OBJECT_0 + static_cast<DWORD>(waitHandles.size())) {
                result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                break;
            }
            const DWORD signaled = wait - WAIT_OBJECT_0;
            if (g_stopEvent && signaled == 0) break;
            if (signaled < slotWaitBase || signaled >= slotWaitBase + CameraUsb::kIsoQueueDepth) {
                result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                break;
            }
            const ULONG slotIndex = static_cast<ULONG>(signaled - slotWaitBase);
            IsoSlot& slot = slots[slotIndex];
            if (!slot.pending) { ResetEvent(slot.event); continue; }
            timeouts = 0;

            DWORD ignored = 0;
            if (!WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, FALSE)) {
                const DWORD e = GetLastError(); slot.pending = false;
                if (e == ERROR_OPERATION_ABORTED && !SessionRunning()) break;
                // Resubmit every recoverable completion independently. Waiting for
                // whichever slot completes first keeps the full ISO queue scheduled
                // even when Windows reports completions out of order.
                wchar_t message[160]{};
                swprintf_s(message, L"Video ISO completion error %lu on slot %lu; resubmitting.", e, slotIndex);
                Log(message);
                if (!queueRead(slotIndex, TRUE)) { result = HrLastError(); break; }
                continue;
            }
            slot.pending = false;
            const size_t slotBegin = static_cast<size_t>(slotIndex) * transferBytes;
            const size_t slotEnd = slotBegin + transferBytes;
            auto* packetDesc = desc.data() + static_cast<size_t>(slotIndex) * packetCount;
            bool haveFrame = false;
            for (ULONG i = 0; i < packetCount; ++i) {
                const auto& packet = packetDesc[i];
                if (packet.Status != USBD_STATUS_SUCCESS || packet.Length < sizeof(VideoPacketHeader)) continue;
                const size_t packetOffset = static_cast<size_t>(packet.Offset);
                const size_t packetLength = static_cast<size_t>(packet.Length);
                if (packetOffset > transferBytes || packetLength > transferBytes - packetOffset) continue;
                const size_t packetBegin = slotBegin + packetOffset;
                if (packetBegin < slotBegin || packetBegin > slotEnd || packetLength > slotEnd - packetBegin) continue;
                FrameAssembler& assembler = activeMode == ScannerPort::StreamMode::Rgb ? rgbAssembler :
                    (activeMode == ScannerPort::StreamMode::RgbHighQuality ? rgbHqAssembler : irAssembler);
                if (assembler.Push(io.data() + packetBegin, packet.Length, completeRaw, completeCaptureTickMs))
                    haveFrame = true;
            }
            if (!queueRead(slotIndex, TRUE)) { result = HrLastError(); break; }

            if (haveFrame) {
                lastCompleteFrameAt = GetTickCount64();
                const ScannerPort::MotionSample frameMotion = motion.Current();
                if (activeMode == ScannerPort::StreamMode::Rgb && completeRaw.size() == kRgbRawFrameBytes)
                    rgbWorker.Submit(completeRaw, completeCaptureTickMs, frameMotion);
                else if (activeMode == ScannerPort::StreamMode::RgbHighQuality && completeRaw.size() == kRgbHqRawFrameBytes)
                    rgbHqWorker.Submit(completeRaw, completeCaptureTickMs, frameMotion);
                else if (activeMode == ScannerPort::StreamMode::Infrared && completeRaw.size() == kIrRawFrameBytes)
                    irWorker.Submit(completeRaw, completeCaptureTickMs, frameMotion);
            }
        }

        // Final physical-session teardown is deterministic: stop firmware,
        // cancel all reads, then unregister the long-lived isoch buffer.
        const HRESULT stopVideoHr = StopVideoCapture();
        if (FAILED(stopVideoHr) && SUCCEEDED(result)) result = stopVideoHr;
        const HRESULT cancelHr = cancelVideoReads(FAILED(result));
        if (FAILED(cancelHr) && SUCCEEDED(result)) result = cancelHr;
        const HRESULT unregisterHr = unregisterVideoIso();
        if (FAILED(unregisterHr) && SUCCEEDED(result)) result = unregisterHr;
        CloseSlots(slots);
        return result;
    }

    void DepthLoop(ScannerPortServer& scannerPort, const MotionSampler& motion, FrameConversionWorker& depthWorker) {
        while (SessionRunning()) {
            if (!scannerPort.NeedsProjector()) {
                (void)SetProjector(false);
                Sleep(kScannerStatePollMs);
                continue;
            }
            if (!scannerPort.Wants(ScannerPort::StreamMode::Depth)) {
                // IR alone needs illumination but does not need endpoint 0x82.
                (void)SetProjector(true);
                Sleep(kScannerStatePollMs);
                continue;
            }
            // First real Depth subscription creates one long-lived endpoint
            // 0x82 ISO session. StreamDepthSession returns only for shutdown or
            // a genuine transport error, never merely because the UI closed.
            const HRESULT hr = StreamDepthSession(scannerPort, motion, depthWorker);
            if (FAILED(hr) && SessionRunning()) {
                LogHr(L"Depth endpoint recovery; rebuilding persistent ISO session", hr);
                Sleep(50);
            }
        }
        (void)SetProjector(false);
    }

    HRESULT StreamDepthSession(ScannerPortServer& scannerPort, const MotionSampler& motion,
                               FrameConversionWorker& depthWorker) {
        HRESULT result = ConfigureDepthPath();
        if (FAILED(result)) return result;

        ULONG transferBytes = 0, packetCount = 0;
        if (!ComputeIsoGeometry(m_depth, transferBytes, packetCount)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (transferBytes > std::numeric_limits<ULONG>::max() / CameraUsb::kIsoQueueDepth)
            return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
        const ULONG totalBytes = transferBytes * CameraUsb::kIsoQueueDepth;
        std::vector<uint8_t> io(totalBytes);
        std::vector<USBD_ISO_PACKET_DESCRIPTOR> desc(static_cast<size_t>(packetCount) * CameraUsb::kIsoQueueDepth);
        std::vector<IsoSlot> slots(CameraUsb::kIsoQueueDepth);
        for (auto& slot : slots) {
            slot.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!slot.event) { CloseSlots(slots); return HrLastError(); }
            slot.ov.hEvent = slot.event;
        }

        WINUSB_ISOCH_BUFFER_HANDLE iso = nullptr;
        if (!WinUsb_RegisterIsochBuffer(m_usb, m_depth.pipeId, io.data(), totalBytes, &iso)) {
            const HRESULT hr = HrLastError(); CloseSlots(slots); return hr;
        }

        auto queueRead = [&](ULONG index, BOOL continueStream) -> bool {
            if (!iso) return false;
            IsoSlot& slot = slots[index];
            auto* p = desc.data() + static_cast<size_t>(index) * packetCount;
            std::fill(p, p + packetCount, USBD_ISO_PACKET_DESCRIPTOR{});
            ResetEvent(slot.event); slot.ov = OVERLAPPED{}; slot.ov.hEvent = slot.event;
            BOOL ok = WinUsb_ReadIsochPipeAsap(iso, index * transferBytes, transferBytes,
                                               continueStream, packetCount, p, &slot.ov);
            if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
            slot.pending = true; return true;
        };

        auto cancelAndUnregisterDepthIso = [&](bool forcePipeRecovery) -> HRESULT {
            if (!iso) return S_OK;
            HRESULT hr = CancelPendingIsoReads(m_depth, slots, forcePipeRecovery);
            if (!WinUsb_UnregisterIsochBuffer(iso) && SUCCEEDED(hr)) hr = HrLastError();
            iso = nullptr;
            return hr;
        };

        for (ULONG i = 0; i < CameraUsb::kIsoQueueDepth; ++i) {
            if (!queueRead(i, i == 0 ? FALSE : TRUE)) { result = HrLastError(); break; }
        }

        FrameAssembler assembler(kDepthRawFrameBytes, CameraUsb::kDepthPacketBytes, kDepthFlag);
        if (!assembler.IsValid()) result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        // Arm USB first, then enable register 0x06. Keep the WinUSB ISO
        // registration alive for the whole physical camera session; module
        // lifetime only controls the emitter and firmware stream state.
        if (SUCCEEDED(result)) result = SetProjector(scannerPort.NeedsProjector());

        std::vector<uint8_t> completeRaw;
        uint64_t completeCaptureTickMs = 0;
        int timeouts = 0;
        bool depthWasRequested = scannerPort.Wants(ScannerPort::StreamMode::Depth);
        ULONGLONG lastCompleteFrameAt = GetTickCount64();
        std::vector<HANDLE> waitHandles;
        waitHandles.reserve(CameraUsb::kIsoQueueDepth + 1u);
        if (g_stopEvent) waitHandles.push_back(g_stopEvent);
        const DWORD slotWaitBase = static_cast<DWORD>(waitHandles.size());
        for (const auto& slot : slots) waitHandles.push_back(slot.event);

        while (SUCCEEDED(result) && SessionRunning()) {
            const bool wantsDepth = scannerPort.Wants(ScannerPort::StreamMode::Depth);
            const bool needsProjector = scannerPort.NeedsProjector();
            const ULONGLONG now = GetTickCount64();
            if (wantsDepth && !depthWasRequested) {
                assembler.Reset();
                lastCompleteFrameAt = now;
                timeouts = 0;
            }
            depthWasRequested = wantsDepth;
            if (wantsDepth && now - lastCompleteFrameAt >= kDepthFrameTimeoutMs) {
                LogStream(L"Depth stopped producing frames; rebuilding the depth ISO session",
                          assembler.GetStats(), kDepthFrameTimeoutMs);
                result = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                break;
            }
            const HRESULT projectorHr = SetProjector(needsProjector);
            if (FAILED(projectorHr)) { result = projectorHr; break; }

            // With the projector OFF there is intentionally no 0x82 traffic.
            // Poll subscriber state quickly so reopening Depth wakes the existing
            // session in tens of milliseconds rather than waiting a full ISO timeout.
            const DWORD waitMs = needsProjector ? kIsoWaitMs : kScannerStatePollMs;
            const DWORD wait = WaitForMultipleObjects(
                static_cast<DWORD>(waitHandles.size()), waitHandles.data(), FALSE, waitMs);
            if (wait == WAIT_TIMEOUT) {
                // No Depth subscriber means register 0x06 may intentionally be
                // OFF, so pending ISO reads can sit idle without constituting a
                // transport failure. Timeout recovery applies only while Depth
                // is actively requested.
                if (wantsDepth && ++timeouts >= kMaxIsoTimeouts) {
                    Log(L"Depth ISO queue stalled; rebuilding the depth ISO session.");
                    result = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                    break;
                }
                if (!wantsDepth) timeouts = 0;
                continue;
            }
            if (wait == WAIT_FAILED) { result = HrLastError(); break; }
            if (wait < WAIT_OBJECT_0 || wait >= WAIT_OBJECT_0 + static_cast<DWORD>(waitHandles.size())) {
                result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                break;
            }
            const DWORD signaled = wait - WAIT_OBJECT_0;
            if (g_stopEvent && signaled == 0) break;
            if (signaled < slotWaitBase || signaled >= slotWaitBase + CameraUsb::kIsoQueueDepth) {
                result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                break;
            }
            const ULONG slotIndex = static_cast<ULONG>(signaled - slotWaitBase);
            IsoSlot& slot = slots[slotIndex];
            if (!slot.pending) { ResetEvent(slot.event); continue; }
            timeouts = 0;

            DWORD ignored = 0;
            if (!WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, FALSE)) {
                const DWORD e = GetLastError(); slot.pending = false;
                if (e == ERROR_OPERATION_ABORTED && !SessionRunning()) break;
                wchar_t message[160]{};
                swprintf_s(message, L"Depth ISO completion error %lu on slot %lu; resubmitting.", e, slotIndex);
                Log(message);
                if (!queueRead(slotIndex, TRUE)) { result = HrLastError(); break; }
                continue;
            }
            slot.pending = false;

            const size_t slotBegin = static_cast<size_t>(slotIndex) * transferBytes;
            const size_t slotEnd = slotBegin + transferBytes;
            auto* packetDesc = desc.data() + static_cast<size_t>(slotIndex) * packetCount;
            bool haveFrame = false;
            for (ULONG i = 0; i < packetCount; ++i) {
                const auto& packet = packetDesc[i];
                if (packet.Status != USBD_STATUS_SUCCESS || packet.Length < sizeof(VideoPacketHeader)) continue;
                const size_t packetOffset = static_cast<size_t>(packet.Offset);
                const size_t packetLength = static_cast<size_t>(packet.Length);
                if (packetOffset > transferBytes || packetLength > transferBytes - packetOffset) continue;
                const size_t packetBegin = slotBegin + packetOffset;
                if (packetBegin < slotBegin || packetBegin > slotEnd || packetLength > slotEnd - packetBegin) continue;
                if (assembler.Push(io.data() + packetBegin, packet.Length, completeRaw, completeCaptureTickMs)) haveFrame = true;
            }

            if (!queueRead(slotIndex, TRUE)) { result = HrLastError(); break; }
            if (haveFrame) lastCompleteFrameAt = GetTickCount64();
            if (haveFrame && completeRaw.size() == kDepthRawFrameBytes &&
                scannerPort.Wants(ScannerPort::StreamMode::Depth)) {
                depthWorker.Submit(completeRaw, completeCaptureTickMs, motion.Current());
            }
        }

        // Critical teardown order: stop the firmware depth engine BEFORE
        // cancelling/unregistering endpoint 0x82. This preserves the device's
        // freenect_stop_depth() and prevents a host-side ISO teardown from
        // leaving the Kinect firmware latched in an active Depth session.
        const bool restoreIrIllumination = SessionRunning() && scannerPort.Wants(ScannerPort::StreamMode::Infrared);
        const HRESULT stopDepthHr = SetProjector(false);
        if (FAILED(stopDepthHr) && SUCCEEDED(result)) result = stopDepthHr;

        const HRESULT stopIsoHr = cancelAndUnregisterDepthIso(FAILED(result));
        if (FAILED(stopIsoHr) && SUCCEEDED(result)) result = stopIsoHr;
        CloseSlots(slots);

        if (restoreIrIllumination) {
            const HRESULT irHr = SetProjector(true);
            if (FAILED(irHr) && SUCCEEDED(result)) result = irHr;
        }
        return result;
    }
};


void ReportService(DWORD state, DWORD error = NO_ERROR, DWORD hint = 0) {
    if (!g_statusHandle) return;
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = state;
    g_status.dwWin32ExitCode = error;
    g_status.dwWaitHint = hint;
    g_status.dwControlsAccepted = (state == SERVICE_RUNNING)
        ? (SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN) : 0;
    SetServiceStatus(g_statusHandle, &g_status);
}

DWORD WINAPI ServiceControl(DWORD control, DWORD, void*, void*) {
    if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
        ReportService(SERVICE_STOP_PENDING, NO_ERROR, 5000);
        g_run.store(false);
        if (g_stopEvent) SetEvent(g_stopEvent);
        return NO_ERROR;
    }
    return NO_ERROR;
}

std::filesystem::path DeviceManifestPath() {
    wchar_t root[1024]{};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", root, static_cast<DWORD>(std::size(root)));
    std::filesystem::path base = (n > 0 && n < std::size(root)) ? std::filesystem::path(root) : std::filesystem::path(L"C:\\ProgramData");
    return base / L"Kinect360Remold" / L"devices.tsv";
}

std::wstring ScannerPipeName(const std::string& id) {
    return std::wstring(ScannerPort::kPipePrefix) + std::wstring(id.begin(), id.end());
}

bool NamedPipeReady(const std::wstring& pipe) {
    if (WaitNamedPipeW(pipe.c_str(), 0)) return true;
    const DWORD e = GetLastError();
    return e == ERROR_PIPE_BUSY;
}

std::wstring AudioPipeName(const std::string& id) { return L"\\\\.\\pipe\\Kinect360RemoldAudio-" + std::wstring(id.begin(), id.end()); }
std::wstring AudioControlPipeName(const std::string& id) { return L"\\\\.\\pipe\\Kinect360RemoldAudioControl-" + std::wstring(id.begin(), id.end()); }
std::string VirtualCameraName(const std::string& id) { return "Kinect Xbox 360 Camera [" + id + "]"; }

std::set<std::string> EnumerateVirtualCameraIds() {
    std::set<std::string> ids;
    constexpr wchar_t kPrefix[] = L"Kinect Xbox 360 Camera [";
    constexpr wchar_t kRegistry[] = L"SOFTWARE\\Kinect360Remold\\VirtualCameras";
    constexpr size_t prefixChars = (sizeof(kPrefix) / sizeof(kPrefix[0])) - 1u;

    // Collect currently materialized PnP cameras. Windows may append text to a
    // virtual-camera friendly name, so parse through the first closing ']'.
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set != INVALID_HANDLE_VALUE) {
        for (DWORD index = 0;; ++index) {
            SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
            if (!SetupDiEnumDeviceInfo(set, index, &data)) break;
            wchar_t name[512]{}; DWORD type = 0, bytes = 0;
            if (!SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_FRIENDLYNAME, &type,
                                                   reinterpret_cast<PBYTE>(name), sizeof(name), &bytes)) continue;
            const std::wstring friendly(name);
            if (friendly.size() <= prefixChars + 1u ||
                _wcsnicmp(friendly.c_str(), kPrefix, prefixChars) != 0) continue;
            const size_t close = friendly.find(L']', prefixChars);
            if (close == std::wstring::npos || close == prefixChars) continue;
            const std::wstring wideId = friendly.substr(prefixChars, close - prefixChars);
            if (wideId.find_first_not_of(L"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") != std::wstring::npos) continue;
            ids.emplace(wideId.begin(), wideId.end());
        }
        SetupDiDestroyDeviceInfoList(set);
    }

    // MFVirtualCameraLifetime_System registration is authoritative once Start()
    // succeeds, even if the second camera has not reached PnP/MF enumeration
    // yet. The registrar writes this value only after successful Start().
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistry, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) == ERROR_SUCCESS) {
        for (DWORD index = 0;; ++index) {
            wchar_t name[256]{};
            DWORD chars = static_cast<DWORD>(std::size(name));
            const LONG rc = RegEnumValueW(key, index, name, &chars, nullptr, nullptr, nullptr, nullptr);
            if (rc == ERROR_NO_MORE_ITEMS) break;
            if (rc == ERROR_SUCCESS) {
                const std::wstring wideId(name, chars);
                if (!wideId.empty() && wideId.find_first_not_of(L"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") == std::wstring::npos)
                    ids.emplace(wideId.begin(), wideId.end());
            }
        }
        RegCloseKey(key);
    }
    return ids;
}

std::filesystem::path RegisteredVirtualCameraSource() {
    constexpr wchar_t kSourceKey[] =
        L"SOFTWARE\\Classes\\CLSID\\{D0C8E936-5A2B-4C0D-936F-281501A73691}\\InprocServer32";
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kSourceKey, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) return {};
    DWORD type = 0;
    DWORD bytes = 0;
    LONG rc = RegQueryValueExW(key, nullptr, nullptr, &type, nullptr, &bytes);
    if (rc != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) || bytes < sizeof(wchar_t)) {
        RegCloseKey(key);
        return {};
    }
    std::vector<wchar_t> value((bytes / sizeof(wchar_t)) + 2, L'\0');
    rc = RegQueryValueExW(key, nullptr, nullptr, &type, reinterpret_cast<BYTE*>(value.data()), &bytes);
    RegCloseKey(key);
    if (rc != ERROR_SUCCESS) return {};
    std::wstring path(value.data());
    if (type == REG_EXPAND_SZ) {
        const DWORD needed = ExpandEnvironmentStringsW(path.c_str(), nullptr, 0);
        if (!needed) return {};
        std::vector<wchar_t> expanded(needed + 1, L'\0');
        if (!ExpandEnvironmentStringsW(path.c_str(), expanded.data(), static_cast<DWORD>(expanded.size()))) return {};
        path.assign(expanded.data());
    }
    std::error_code ec;
    const std::filesystem::path source(path);
    return std::filesystem::is_regular_file(source, ec) && !ec ? source : std::filesystem::path{};
}

std::filesystem::path VirtualCameraToolPath() {
    // CameraBridge is installed by the PnP INF in Driver Store (%13%), while
    // the virtual-camera source and registrar are deployed together in the
    // product runtime directory. Never infer the registrar location from the
    // service executable path: that made publication fail whenever the bridge
    // ran from Driver Store.
    const auto source = RegisteredVirtualCameraSource();
    if (source.empty()) return {};
    const auto tool = source.parent_path() / L"Kinect360RemoldWebcam.exe";
    std::error_code ec;
    if (!std::filesystem::is_regular_file(tool, ec) || ec) return {};
    return tool;
}

bool RunWebcamTool(const std::vector<std::wstring>& args) {
    const auto tool = VirtualCameraToolPath();
    if (tool.empty()) {
        Log(L"Virtual-camera registrar is unavailable beside the registered media source.");
        return false;
    }
    const auto runtime = tool.parent_path();
    std::wstring command = L"\"" + tool.wstring() + L"\"";
    for (const auto& arg : args) {
        command += L" \"";
        command += arg;
        command += L"\"";
    }
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, mutableCommand.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, runtime.c_str(), &startup, &process)) {
        wchar_t message[256]{};
        swprintf_s(message, L"Virtual-camera registrar could not start (Win32=%lu).", GetLastError());
        Log(message);
        return false;
    }
    const DWORD wait = WaitForSingleObject(process.hProcess, 20000);
    DWORD exitCode = ERROR_GEN_FAILURE;
    if (wait == WAIT_OBJECT_0) {
        (void)GetExitCodeProcess(process.hProcess, &exitCode);
    } else {
        (void)TerminateProcess(process.hProcess, ERROR_TIMEOUT);
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    if (wait != WAIT_OBJECT_0 || exitCode != 0) {
        wchar_t message[256]{};
        swprintf_s(message, L"Virtual-camera registrar failed (wait=%lu exit=0x%08lX).", wait, exitCode);
        Log(message);
        return false;
    }
    return true;
}

bool InstallVirtualCamera(const std::string& id) {
    // The bridge calls this only for IDs absent from the current PnP snapshot.
    // Avoid a second full device-tree enumeration for every missing Kinect.
    const auto dll = RegisteredVirtualCameraSource();
    if (dll.empty()) {
        Log(L"Registered virtual-camera media source is unavailable.");
        return false;
    }
    return RunWebcamTool({L"install", dll.wstring(), std::wstring(id.begin(), id.end())});
}

void RemoveVirtualCamera(const std::string& id) {
    (void)RunWebcamTool({L"remove", std::wstring(id.begin(), id.end())});
}


class CameraNode {
public:
    explicit CameraNode(CameraInterfaceInfo info)
        : m_info(std::move(info)), m_scannerPort(ScannerPipeName(m_info.id), m_info.id),
          m_motion(m_info.id, [this] { return m_scannerPort.ClientActive() || m_publisher.ConsumerLeaseActive(); }) {}

    HRESULT Start() {
        m_run.store(true, std::memory_order_release);
        HRESULT hr = m_publisher.Open(m_info.id);
        if (FAILED(hr)) return hr;
        hr = m_scannerPort.Start();
        if (FAILED(hr)) return hr;
        hr = m_motion.Start();
        if (FAILED(hr)) { m_scannerPort.Stop(); return hr; }
        try { m_thread = std::thread([this] { Loop(); }); }
        catch (const std::system_error&) { m_motion.Stop(); m_scannerPort.Stop(); return E_OUTOFMEMORY; }
        return S_OK;
    }

    void Stop() {
        m_run.store(false, std::memory_order_release);
        m_online.store(false, std::memory_order_release);
        m_publisher.SetOnline(false);
        m_scannerPort.Stop();
        if (m_thread.joinable()) m_thread.join();
        m_motion.Stop();
    }

    const std::wstring& DevicePath() const noexcept { return m_info.path; }
    const CameraInterfaceInfo& Info() const noexcept { return m_info; }
    bool Online() const noexcept { return m_online.load(std::memory_order_acquire); }

private:
    CameraInterfaceInfo m_info;
    SharedFramePublisher m_publisher;
    ScannerPortServer m_scannerPort;
    MotionSampler m_motion;
    std::thread m_thread;
    std::atomic<bool> m_run{false};
    std::atomic<bool> m_online{false};

    void Loop() {
        bool startupOpen = true;
        while (g_run.load() && m_run.load(std::memory_order_acquire)) {
            CameraUsbTransport camera;
            HRESULT hr = camera.Open(m_info.path, m_info.id, startupOpen);
            if (FAILED(hr)) {
                wchar_t message[256]{};
                swprintf_s(message, L"Camera %hs open/configuration failed (0x%08X); retrying.",
                           m_info.id.c_str(), static_cast<unsigned>(hr));
                Log(message);
                m_online.store(false, std::memory_order_release);
                m_publisher.SetOnline(false);
                if (g_stopEvent && WaitForSingleObject(g_stopEvent, 750) == WAIT_OBJECT_0) break;
                if (!g_stopEvent) Sleep(750);
                continue;
            }
            startupOpen = false;
            const Hardware::Model model = camera.HardwareModel();
            m_motion.Enable(model);
            m_online.store(true, std::memory_order_release);
            hr = camera.Run(m_publisher, m_scannerPort, m_motion, &m_run);
            m_motion.Disable();
            m_online.store(false, std::memory_order_release);
            m_publisher.SetOnline(false);
            if (!g_run.load() || !m_run.load(std::memory_order_acquire)) break;
            wchar_t message[256]{};
            swprintf_s(message, L"Camera %hs transport ended; reopening its image endpoints (0x%08X)", m_info.id.c_str(), static_cast<unsigned>(hr));
            Log(message);
            const DWORD retryMs = model == Hardware::Model::Xbox1473 ? 1500 : 500;
            if (g_stopEvent && WaitForSingleObject(g_stopEvent, retryMs) == WAIT_OBJECT_0) break;
            if (!g_stopEvent) Sleep(retryMs);
        }
    }
};

void WriteDeviceManifest(const std::map<std::string, std::unique_ptr<CameraNode>>& nodes,
                         const std::set<std::string>& present,
                         const std::set<std::string>& virtualCameras) {
    std::error_code ec;
    const auto target = DeviceManifestPath();
    std::filesystem::create_directories(target.parent_path(), ec);
    const auto temp = target.wstring() + L".tmp";
    {
        std::ofstream out(std::filesystem::path(temp), std::ios::binary | std::ios::trunc);
        if (!out) return;
        out << "# id\tlabel\tstate\tcontrol\tcamera\taudio\taudio-control\tvirtual-camera\tsdk\n";
        const bool sdkReady = NamedPipeReady(L"\\\\.\\pipe\\Kinect360RemoldSdk");
        for (const auto& entry : nodes) {
            const auto& node = *entry.second;
            const auto& d = node.Info();
            const bool physical = present.count(d.id) != 0;
            const bool cameraReady = physical && node.Online();
            const std::wstring scanner = ScannerPipeName(d.id);
            const std::wstring audio = AudioPipeName(d.id);
            const std::wstring audioControl = AudioControlPipeName(d.id);
            Control::Reply controlReply{};
            // Capability discovery must never poll the accelerometer/motor. A Status
            // request can take hundreds of milliseconds on 1473 and, when repeated
            // by the manifest publisher, queues physical-control transactions behind
            // a manual Tilt. Ping only resolves/opens the per-device transport and is
            // therefore the correct readiness probe for both 1414 and 1473.
            const bool controlReady = physical &&
                BrokerExchange(Control::Command::Ping, 0, controlReply, d.id, 100) &&
                controlReply.transport == Control::Transport::PhysicalMotor;
            const bool rawAudioReady = NamedPipeReady(audio);
            // The control socket is a per-Kinect capability owned by AudioBridge,
            // independent of the instantaneous WASAPI capture state. Publish its
            // address whenever the physical Kinect exists; the Studio performs the
            // actual Get/Set handshake and can show reconnecting state if necessary.
            const bool audioControlReady = physical;
            const bool vcam = virtualCameras.count(d.id) != 0;
            const char* state = !physical ? "Reconnecting" : (cameraReady ? "Ready" : "Booting");
            out << d.id << '\t' << d.label << '\t' << state << '\t'
                << (controlReady ? WideToUtf8(Control::kPipeName) : "") << '\t'
                << (cameraReady ? WideToUtf8(scanner) : "") << '\t'
                << (rawAudioReady ? WideToUtf8(audio) : "") << '\t'
                << (audioControlReady ? WideToUtf8(audioControl) : "") << '\t'
                << (vcam ? VirtualCameraName(d.id) : "") << '\t'
                << (sdkReady ? "\\\\.\\pipe\\Kinect360RemoldSdk" : "") << '\n';
        }
    }
    if (!MoveFileExW(temp.c_str(), target.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const DWORD error = GetLastError();
        DeleteFileW(temp.c_str());
        wchar_t message[256]{};
        swprintf_s(message, L"Device manifest publish failed (Win32=%lu)", error);
        Log(message);
    }
}

int RunBridgeLoop() {
    HRESULT hr = S_OK;
    std::map<std::string, std::unique_ptr<CameraNode>> nodes;
    std::map<std::string, std::chrono::steady_clock::time_point> lastSeen;
    std::map<std::string, std::chrono::steady_clock::time_point> nextVirtualCameraAttempt;
    std::map<std::string, std::chrono::steady_clock::time_point> virtualCameraMissingSince;
    constexpr auto reconnectGrace = std::chrono::seconds(30);

    WriteDeviceManifest(nodes, {}, {});
    while (g_run.load()) {
        const auto now = std::chrono::steady_clock::now();
        const auto enumerated = EnumerateCameraInterfaces();
        std::map<std::string, CameraInterfaceInfo> desired;
        std::set<std::string> present;

        for (const auto& device : enumerated) {
            desired[device.id] = device;
            present.insert(device.id);
            lastSeen[device.id] = now;
            virtualCameraMissingSince.erase(device.id);
        }

        for (auto it = nodes.begin(); it != nodes.end();) {
            const auto wanted = desired.find(it->first);
            bool expired = false;
            if (wanted == desired.end()) {
                const auto seen = lastSeen.find(it->first);
                expired = seen == lastSeen.end() || now - seen->second >= reconnectGrace;
            }

            const bool pathChanged =
                wanted != desired.end() && it->second->DevicePath() != wanted->second.path;
            if (!expired && !pathChanged) {
                ++it;
                continue;
            }

            const std::string id = it->first;
            it->second->Stop();
            if (expired) {
                lastSeen.erase(id);
                nextVirtualCameraAttempt.erase(id);
            }
            it = nodes.erase(it);
        }

        for (const auto& device : enumerated) {
            if (nodes.find(device.id) != nodes.end()) continue;

            auto node = std::make_unique<CameraNode>(device);
            hr = node->Start();
            if (FAILED(hr)) {
                LogHr(L"Per-Kinect camera/scanner endpoint failed", hr);
                continue;
            }
            nodes.emplace(device.id, std::move(node));
        }

        auto virtualCameras = EnumerateVirtualCameraIds();
        bool virtualCameraSetChanged = false;

        for (const auto& id : present) {
            if (virtualCameras.count(id) != 0) {
                nextVirtualCameraAttempt.erase(id);
                continue;
            }

            const auto retry = nextVirtualCameraAttempt.find(id);
            if (retry != nextVirtualCameraAttempt.end() && now < retry->second) continue;

            if (InstallVirtualCamera(id)) {
                nextVirtualCameraAttempt.erase(id);
                virtualCameraSetChanged = true;
            } else {
                nextVirtualCameraAttempt[id] = now + std::chrono::seconds(10);
            }
        }

        for (const auto& id : virtualCameras) {
            if (present.count(id) != 0) continue;

            const auto [missing, inserted] = virtualCameraMissingSince.emplace(id, now);
            if (!inserted && now - missing->second >= reconnectGrace) {
                RemoveVirtualCamera(id);
                virtualCameraMissingSince.erase(missing);
                virtualCameraSetChanged = true;
            }
        }

        for (auto missing = virtualCameraMissingSince.begin();
             missing != virtualCameraMissingSince.end();) {
            if (present.count(missing->first) != 0 ||
                virtualCameras.count(missing->first) == 0) {
                missing = virtualCameraMissingSince.erase(missing);
            } else {
                ++missing;
            }
        }

        if (virtualCameraSetChanged) virtualCameras = EnumerateVirtualCameraIds();
        WriteDeviceManifest(nodes, present, virtualCameras);

        if (g_stopEvent && WaitForSingleObject(g_stopEvent, 1000) == WAIT_OBJECT_0) break;
        if (!g_stopEvent) Sleep(1000);
    }

    g_run.store(false);
    if (g_stopEvent) SetEvent(g_stopEvent);
    for (auto& entry : nodes) entry.second->Stop();

    std::error_code ec;
    std::filesystem::remove(DeviceManifestPath(), ec);
    return 0;
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
    g_statusHandle = RegisterServiceCtrlHandlerExW(L"Kinect360RemoldCameraBridge", ServiceControl, nullptr);
    if (!g_statusHandle) return;
    ReportService(SERVICE_START_PENDING, NO_ERROR, 5000);
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_stopEvent) { ReportService(SERVICE_STOPPED, GetLastError()); return; }
    g_run.store(true);
    ReportService(SERVICE_RUNNING);
    const int rc = RunBridgeLoop();
    ReportService(SERVICE_STOP_PENDING, NO_ERROR, 2000);
    CloseHandle(g_stopEvent); g_stopEvent = nullptr;
    ReportService(SERVICE_STOPPED, rc ? ERROR_GEN_FAILURE : NO_ERROR);
}

BOOL WINAPI ConsoleCtrl(DWORD) {
    g_run.store(false);
    if (g_stopEvent) SetEvent(g_stopEvent);
    return TRUE;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && _wcsicmp(argv[1], L"--console") == 0) {
        g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!g_stopEvent) return 2;
        SetConsoleCtrlHandler(ConsoleCtrl, TRUE);
        g_run.store(true);
        int rc = RunBridgeLoop();
        CloseHandle(g_stopEvent); g_stopEvent = nullptr;
        return rc;
    }
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(L"Kinect360RemoldCameraBridge"), ServiceMain},
        {nullptr, nullptr}
    };
    if (!StartServiceCtrlDispatcherW(table)) return static_cast<int>(GetLastError());
    return 0;
}
