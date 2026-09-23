#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <string>
#include <algorithm>
#include "Kinect360RemoldControlProtocol.h"
#include "..\..\..\camera\shared\Kinect360RemoldFrameTransport.h"
#include <fstream>
#include <vector>

namespace {
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;

struct BrokerPipe {
    HANDLE handle = INVALID_HANDLE_VALUE;
    ~BrokerPipe() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
};

int Usage() {
    std::puts(
        "Kinect360RemoldNui [--device DEVICE_ID] broker-status | status | tilt <deg> | "
        "led <off|green|red|yellow|blink-green|blink-yellow-red> | "
        "probe [rgb|rgb-hq|ir|depth|rgb+depth|ir+depth] [seconds] | frames [seconds]");
    return 2;
}

HRESULT LastHr() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

HRESULT OpenControlPipe(BrokerPipe& pipe) {
    // Every supported hardware model is controlled through the same broker contract.
    // 1414/1473 USB topology is intentionally invisible to this client.
    constexpr DWORD kOpenAttempts = 4;
    HRESULT last = HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    for (DWORD attempt = 0; attempt < kOpenAttempts; ++attempt) {
        if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 350)) {
            last = LastHr();
            continue;
        }
        pipe.handle = CreateFileW(Kinect360RemoldControl::kPipeName,
                                  GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (pipe.handle == INVALID_HANDLE_VALUE) {
            last = LastHr();
            continue;
        }
        DWORD mode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(pipe.handle, &mode, nullptr, nullptr)) {
            last = LastHr();
            CloseHandle(pipe.handle);
            pipe.handle = INVALID_HANDLE_VALUE;
            continue;
        }
        return S_OK;
    }
    return last;
}

HRESULT BrokerExchange(Command command, int32_t value, Reply& reply, const std::string& deviceId = {}) {
    BrokerPipe pipe;
    const HRESULT openHr = OpenControlPipe(pipe);
    if (FAILED(openHr)) return openHr;

    Request request{};
    request.command = command;
    request.value = value;
    if (!deviceId.empty()) strncpy_s(request.deviceId, deviceId.c_str(), _TRUNCATE);
    DWORD written = 0;
    if (!WriteFile(pipe.handle, &request, sizeof(request), &written, nullptr) || written != sizeof(request))
        return LastHr();
    DWORD read = 0;
    if (!ReadFile(pipe.handle, &reply, sizeof(reply), &read, nullptr) || read != sizeof(reply))
        return LastHr();
    if (reply.magic != Kinect360RemoldControl::kMagic || reply.version != Kinect360RemoldControl::kVersion)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    return static_cast<HRESULT>(reply.result);
}

int ParseLed(const wchar_t* mode) {
    if (_wcsicmp(mode, L"off") == 0) return 0;
    if (_wcsicmp(mode, L"green") == 0) return 1;
    if (_wcsicmp(mode, L"red") == 0) return 2;
    if (_wcsicmp(mode, L"yellow") == 0) return 3;
    if (_wcsicmp(mode, L"blink-green") == 0) return 4;
    if (_wcsicmp(mode, L"blink-yellow-red") == 0) return 6;
    return -1;
}

bool ParseLong(const wchar_t* text, long& value) {
    wchar_t* end = nullptr;
    value = wcstol(text, &end, 10);
    return end && *end == L'\0';
}

int BrokerStatus(bool pingOnly, const std::string& deviceId) {
    Reply reply{};
    const HRESULT hr = BrokerExchange(pingOnly ? Command::Ping : Command::Status, 0, reply, deviceId);
    if (FAILED(hr)) {
        std::printf("Broker command failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 7;
    }
    if (pingOnly) {
        std::printf("OK broker=ready\n");
    } else {
        std::printf("OK device=KinectXbox360 transport=broker accel=%d,%d,%d tilt=%.1f state=%u\n",
                    reply.accelX, reply.accelY, reply.accelZ,
                    static_cast<double>(reply.tiltTenths) / 10.0,
                    static_cast<unsigned int>(reply.state));
    }
    return 0;
}

int BrokerTilt(const wchar_t* text, const std::string& deviceId) {
    long value = 0;
    if (!ParseLong(text, value)) return Usage();
    Reply reply{};
    const HRESULT hr = BrokerExchange(Command::Tilt, static_cast<int32_t>(value), reply, deviceId);
    if (FAILED(hr)) {
        std::printf("Broker Tilt failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 5;
    }
    const bool verified = (reply.state & Kinect360RemoldControl::kStateTiltVerified) != 0;
    std::printf("OK device=KinectXbox360 transport=broker requested=%ld actual=%.1f verified=%d\n",
                value, static_cast<double>(reply.tiltTenths) / 10.0, verified ? 1 : 0);
    return 0;
}

int BrokerLed(const wchar_t* mode, const std::string& deviceId) {
    const int state = ParseLed(mode);
    if (state < 0) return Usage();
    Reply reply{};
    const HRESULT hr = BrokerExchange(Command::Led, state, reply, deviceId);
    if (FAILED(hr)) {
        std::printf("Broker LED failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 6;
    }
    std::printf("OK device=KinectXbox360 transport=broker led=%d\n", state);
    return 0;
}
namespace Frame = Kinect360RemoldFrameTransport;
namespace Scanner = Kinect360RemoldScannerPort;

// First Ready device of the CameraBridge manifest when no --device is given.
std::string ResolveDevice(const std::string& requested, std::string& cameraPipe) {
    wchar_t root[MAX_PATH]{};
    const DWORD n = GetEnvironmentVariableW(L"ProgramData", root, MAX_PATH);
    const std::wstring manifest = std::wstring(n && n < MAX_PATH ? root : L"C:\\ProgramData") +
                                  L"\\Kinect360Remold\\devices.tsv";
    std::ifstream in(manifest.c_str());
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> fields;
        size_t start = 0;
        for (;;) {
            const size_t tab = line.find('\t', start);
            fields.push_back(line.substr(start, tab == std::string::npos ? std::string::npos : tab - start));
            if (tab == std::string::npos) break;
            start = tab + 1;
        }
        if (fields.size() < 5) continue;
        if (!requested.empty() && fields[0] != requested) continue;
        if (requested.empty() && fields[4].empty()) continue;
        cameraPipe = fields[4];
        return fields[0];
    }
    return {};
}

uint32_t ProbeMask(const wchar_t* text) {
    if (!text || _wcsicmp(text, L"rgb+depth") == 0) return Scanner::StreamRgb | Scanner::StreamDepth;
    if (_wcsicmp(text, L"rgb") == 0) return Scanner::StreamRgb;
    if (_wcsicmp(text, L"rgb-hq") == 0) return Scanner::StreamRgbHighQuality;
    if (_wcsicmp(text, L"ir") == 0) return Scanner::StreamInfrared;
    if (_wcsicmp(text, L"depth") == 0) return Scanner::StreamDepth;
    if (_wcsicmp(text, L"ir+depth") == 0) return Scanner::StreamInfrared | Scanner::StreamDepth;
    return 0;
}

bool ReadExact(HANDLE pipe, void* data, DWORD bytes) {
    auto* cursor = static_cast<uint8_t*>(data);
    while (bytes) {
        DWORD done = 0;
        if (!ReadFile(pipe, cursor, bytes, &done, nullptr) || done == 0) return false;
        cursor += done;
        bytes -= done;
    }
    return true;
}

// End-to-end ScannerPort self-test, identical to `kinect360-remoldctl probe`.
int Probe(const std::string& requested, uint32_t mask, int seconds) {
    std::string pipeName;
    const std::string id = ResolveDevice(requested, pipeName);
    if (id.empty() || pipeName.empty()) {
        std::printf("No Ready Kinect camera instance is available for device=%s.\n", requested.empty() ? "auto" : requested.c_str());
        return 3;
    }
    const std::wstring widePipe(pipeName.begin(), pipeName.end());
    HANDLE pipe = CreateFileW(widePipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) {
        std::printf("probe: cannot open %s (Win32=%lu)\n", pipeName.c_str(), GetLastError());
        return 3;
    }
    Scanner::Request request{};
    request.streamMask = mask;
    Scanner::Reply reply{};
    DWORD written = 0;
    if (!WriteFile(pipe, &request, sizeof(request), &written, nullptr) || !ReadExact(pipe, &reply, sizeof(reply))) {
        std::puts("probe: no ScannerPort reply");
        CloseHandle(pipe);
        return 4;
    }
    std::printf("probe device=%s mask=0x%x result=0x%08lX accepted=0x%x depth_calibration=%s capabilities=0x%x\n",
                id.c_str(), mask, static_cast<unsigned long>(reply.result), reply.acceptedMask,
                reply.depthCalibrationValid ? "valid" : "UNAVAILABLE", reply.capabilities);
    if (FAILED(static_cast<HRESULT>(reply.result))) {
        CloseHandle(pipe);
        return 5;
    }
    uint64_t frames[4]{};
    uint64_t motionFrames = 0;
    std::vector<uint8_t> payload(Scanner::kMaxPayloadBytes);
    const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000u;
    while (GetTickCount64() < deadline) {
        Scanner::FrameHeader header{};
        if (!ReadExact(pipe, &header, sizeof(header)) || header.magic != Scanner::kFrameMagic ||
            header.payloadBytes > payload.size() || !ReadExact(pipe, payload.data(), header.payloadBytes)) break;
        const auto index = static_cast<size_t>(header.mode);
        if (index < 4) ++frames[index];
        if (header.motion.flags & Scanner::MotionTiltValid) ++motionFrames;
    }
    CloseHandle(pipe);
    const char* names[4] = {"rgb", "ir", "depth", "rgb-hq"};
    int missing = 0;
    for (size_t index = 0; index < 4; ++index) {
        if ((mask & (1u << index)) == 0) continue;
        std::printf("  %-7s %llu frames (%.1f fps)\n", names[index], static_cast<unsigned long long>(frames[index]),
                    static_cast<double>(frames[index]) / seconds);
        if (frames[index] == 0) ++missing;
    }
    std::printf("  motion  %llu frames carried a valid accelerometer/tilt sample\n", static_cast<unsigned long long>(motionFrames));
    return missing ? 6 : 0;
}

// Inspects the shared RGB transport consumed by the virtual camera and the IP
// camera: layout version, online state, frame progress and consumer lease.
int Frames(const std::string& requested, int seconds) {
    std::string pipeName;
    const std::string id = ResolveDevice(requested, pipeName);
    if (id.empty()) {
        std::puts("No Kinect is published in devices.tsv.");
        return 3;
    }
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, Frame::MappingName(id).c_str());
    if (!mapping) {
        std::printf("frames device=%s: shared RGB mapping missing (Win32=%lu)\n", id.c_str(), GetLastError());
        return 4;
    }
    const auto* header = static_cast<const Frame::SharedHeader*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, Frame::kHeaderBytes));
    if (!header) {
        CloseHandle(mapping);
        return 4;
    }
    auto latest = [header]() {
        const LONG slot = header->activeSlot;
        return (slot >= 0 && slot < static_cast<LONG>(Frame::kSlotCount)) ? header->slot[slot] : Frame::FrameSlotMeta{};
    };
    const Frame::FrameSlotMeta first = latest();
    Sleep(static_cast<DWORD>(seconds) * 1000u);
    const Frame::FrameSlotMeta last = latest();
    const ULONGLONG now = GetTickCount64();
    std::printf("frames device=%s layout=%s online=%ld %ux%u frames=%llu in %d s, latest age=%llu ms, motion=%s\n",
                id.c_str(),
                header->magic == Frame::kMagic && header->version == Frame::kVersion ? "current" : "MISMATCH",
                header->online, header->width, header->height,
                static_cast<unsigned long long>(last.frameNumber - first.frameNumber), seconds,
                static_cast<unsigned long long>(last.tickMs ? now - last.tickMs : 0),
                (last.motion.flags & Scanner::MotionTiltValid) ? "valid" : "none");
    HANDLE leaseMapping = OpenFileMappingW(FILE_MAP_READ, FALSE, Frame::LeaseName(id).c_str());
    if (leaseMapping) {
        const auto* lease = static_cast<const Frame::ConsumerLease*>(MapViewOfFile(leaseMapping, FILE_MAP_READ, 0, 0, sizeof(Frame::ConsumerLease)));
        if (lease) {
            const auto renewed = static_cast<ULONGLONG>(lease->renewedTickMs);
            std::printf("  consumer lease: %s\n", renewed && now - renewed <= Frame::kConsumerLeaseMs ? "active (a virtual/IP camera is reading)" : "idle");
            UnmapViewOfFile(lease);
        }
        CloseHandle(leaseMapping);
    } else {
        std::puts("  consumer lease: missing");
    }
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return last.frameNumber != first.frameNumber ? 0 : 6;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) return Usage();
    int index = 1;
    std::string deviceId;
    if (index + 1 < argc && _wcsicmp(argv[index], L"--device") == 0) {
        const std::wstring wide = argv[index + 1];
        const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
        if (bytes <= 0) return Usage();
        deviceId.resize(static_cast<size_t>(bytes));
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.c_str(), static_cast<int>(wide.size()), deviceId.data(), bytes, nullptr, nullptr)) return Usage();
        index += 2;
    }
    const int remaining = argc - index;
    if (remaining == 1 && _wcsicmp(argv[index], L"broker-status") == 0) return BrokerStatus(true, deviceId);
    if (remaining == 1 && _wcsicmp(argv[index], L"status") == 0) return BrokerStatus(false, deviceId);
    if (remaining == 2 && _wcsicmp(argv[index], L"tilt") == 0) return BrokerTilt(argv[index + 1], deviceId);
    if (remaining == 2 && _wcsicmp(argv[index], L"led") == 0) return BrokerLed(argv[index + 1], deviceId);
    if (remaining >= 1 && remaining <= 3 && _wcsicmp(argv[index], L"probe") == 0) {
        const uint32_t mask = ProbeMask(remaining >= 2 ? argv[index + 1] : nullptr);
        const int seconds = remaining == 3 ? std::clamp(_wtoi(argv[index + 2]), 1, 60) : 5;
        return mask ? Probe(deviceId, mask, seconds) : Usage();
    }
    if (remaining >= 1 && remaining <= 2 && _wcsicmp(argv[index], L"frames") == 0)
        return Frames(deviceId, remaining == 2 ? std::clamp(_wtoi(argv[index + 1]), 1, 60) : 3);
    return Usage();
}
