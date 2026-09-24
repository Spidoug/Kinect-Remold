#pragma once
#include <string>
#include <windows.h>
#include <cstdint>

#include "Kinect360RemoldScannerPort.h"

// Per-device RGB transport from CameraBridge to the Windows virtual camera and
// IP camera. CameraBridge is the only writer of the frame mapping. Every frame
// slot carries the same motion sample contract as a ScannerPort frame.
//
// Consumers renew a separate consumer lease while they actively use frames.
// The lease is the Windows counterpart of a Linux ScannerPort subscription:
// CameraBridge polls the accelerometer/tilt only while a ScannerPort client or
// a leased frame consumer is active.
namespace Kinect360RemoldFrameTransport {
constexpr wchar_t kMappingPrefix[] = L"Global\\Kinect360RemoldFrame-";
constexpr wchar_t kLeasePrefix[] = L"Global\\Kinect360RemoldFrameLease-";
inline std::wstring MappingName(const std::string& deviceId) { return std::wstring(kMappingPrefix) + std::wstring(deviceId.begin(), deviceId.end()); }
inline std::wstring MappingName(const std::wstring& deviceId) { return std::wstring(kMappingPrefix) + deviceId; }
inline std::wstring LeaseName(const std::string& deviceId) { return std::wstring(kLeasePrefix) + std::wstring(deviceId.begin(), deviceId.end()); }
inline std::wstring LeaseName(const std::wstring& deviceId) { return std::wstring(kLeasePrefix) + deviceId; }
constexpr uint32_t kMagic = 0x3143564Bu; // "KVC1"
constexpr uint32_t kVersion = 1;

constexpr uint32_t kWidth = 640;
constexpr uint32_t kHeight = 480;
constexpr uint32_t kHqWidth = 1280;
constexpr uint32_t kHqHeight = 1024;
constexpr uint32_t kNv12Fourcc = 0x3231564Eu; // NV12
constexpr uint32_t kNv12Bytes = kWidth * kHeight * 3u / 2u;
constexpr uint32_t kHqNv12Bytes = kHqWidth * kHqHeight * 3u / 2u;
constexpr uint32_t kHeaderBytes = 4096;
constexpr uint32_t kSlotCount = 2;
constexpr uint32_t kMappingBytes = kHeaderBytes + kHqNv12Bytes * kSlotCount;
constexpr ULONGLONG kConsumerLeaseMs = 2000;

struct FrameSlotMeta {
    uint64_t frameNumber;
    uint64_t tickMs;
    uint32_t bytes;
    uint32_t flags;
    Kinect360RemoldScannerPort::MotionSample motion;
};

struct SharedHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride;
    uint32_t frameBytes;
    uint32_t slotCount;
    volatile LONG colorSequence;   // odd while color writer mutates, even when stable
    volatile LONG activeSlot;
    volatile LONG online;
    FrameSlotMeta slot[kSlotCount];
};

struct ConsumerLease {
    volatile LONG64 renewedTickMs;
};

static_assert(sizeof(SharedHeader) <= kHeaderBytes, "Shared header must fit reserved page");

inline uint8_t* SlotAddress(void* base, uint32_t slot) noexcept {
    return static_cast<uint8_t*>(base) + kHeaderBytes + static_cast<size_t>(slot) * kHqNv12Bytes;
}
inline const uint8_t* SlotAddress(const void* base, uint32_t slot) noexcept {
    return static_cast<const uint8_t*>(base) + kHeaderBytes + static_cast<size_t>(slot) * kHqNv12Bytes;
}

// Consumer side of the lease. Renew() is cheap and may be called per frame.
class ConsumerLeaseWriter {
public:
    ConsumerLeaseWriter() = default;
    ConsumerLeaseWriter(const ConsumerLeaseWriter&) = delete;
    ConsumerLeaseWriter& operator=(const ConsumerLeaseWriter&) = delete;
    ~ConsumerLeaseWriter() { Close(); }

    void Renew(const std::wstring& deviceId) noexcept {
        if (deviceId != m_deviceId) {
            Close();
            m_deviceId = deviceId;
        }
        if (!m_lease && !Open()) return;
        InterlockedExchange64(&m_lease->renewedTickMs, static_cast<LONG64>(GetTickCount64()));
    }

    void Close() noexcept {
        if (m_lease) UnmapViewOfFile(const_cast<ConsumerLease*>(m_lease));
        if (m_mapping) CloseHandle(m_mapping);
        m_lease = nullptr;
        m_mapping = nullptr;
    }

private:
    std::wstring m_deviceId;
    HANDLE m_mapping = nullptr;
    ConsumerLease* m_lease = nullptr;

    bool Open() noexcept {
        if (m_deviceId.empty()) return false;
        m_mapping = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, LeaseName(m_deviceId).c_str());
        if (!m_mapping) return false;
        m_lease = static_cast<ConsumerLease*>(MapViewOfFile(m_mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(ConsumerLease)));
        if (!m_lease) Close();
        return m_lease != nullptr;
    }
};
} // namespace Kinect360RemoldFrameTransport
