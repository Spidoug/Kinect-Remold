#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <cstring>
#include <string>
#include "Kinect360RemoldControlProtocol.h"
#include "Kinect360RemoldNuiProtocol.h"

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
        "Kinect360RemoldNui [--device ID] broker-status | status | sdk | runtime | tilt <deg> | "
        "led <off|green|red|yellow|blink-green|blink-yellow-red>");
    return 2;
}

HRESULT LastHr() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

std::string WideUtf8(const wchar_t* text) {
    if (!text || !*text) return {};
    const int chars = static_cast<int>(std::wcslen(text));
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, chars, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<size_t>(bytes), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, chars, out.data(), bytes, nullptr, nullptr)) return {};
    return out;
}

bool CopyDeviceId(char* destination, size_t capacity, const std::string& id) {
    if (!destination || capacity == 0 || id.size() >= capacity) return false;
    std::memset(destination, 0, capacity);
    if (!id.empty()) std::memcpy(destination, id.data(), id.size());
    return true;
}

HRESULT OpenControlPipe(BrokerPipe& pipe) {
    // Every hardware revision is controlled through the same broker interface.
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

HRESULT BrokerExchange(Command command, int32_t value, const std::string& deviceId, Reply& reply) {
    BrokerPipe pipe;
    const HRESULT openHr = OpenControlPipe(pipe);
    if (FAILED(openHr)) return openHr;

    Request request{};
    request.command = command;
    request.value = value;
    if (!CopyDeviceId(request.deviceId, sizeof(request.deviceId), deviceId)) return E_INVALIDARG;
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



template <typename TRequest, typename TReply>
HRESULT PipeExchange(const wchar_t* name, const TRequest& request, TReply& reply) {
    if (!WaitNamedPipeW(name, 600)) return LastHr();
    HANDLE pipe = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return LastHr();
    DWORD mode = PIPE_READMODE_MESSAGE;
    (void)SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
    DWORD written = 0, read = 0;
    HRESULT hr = S_OK;
    if (!WriteFile(pipe, &request, sizeof(request), &written, nullptr) || written != sizeof(request)) hr = LastHr();
    else if (!ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) || read != sizeof(reply)) hr = LastHr();
    CloseHandle(pipe);
    return hr;
}

int SdkStatus(const std::string& deviceId) {
    Kinect360RemoldNui::Sdk::Request q{};
    q.command = Kinect360RemoldNui::Sdk::Command::RuntimeInfo;
    if (!CopyDeviceId(q.deviceId, sizeof(q.deviceId), deviceId)) return Usage();
    Kinect360RemoldNui::Sdk::Reply r{};
    HRESULT hr = PipeExchange(Kinect360RemoldNui::kSdkPipeName, q, r);
    if (FAILED(hr)) { std::printf("SDK bridge failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr)); return 8; }
    if (r.magic != Kinect360RemoldNui::Sdk::kMagic || r.version != Kinect360RemoldNui::Sdk::kVersion)
        return 8;
    hr = static_cast<HRESULT>(r.result);
    std::printf("SDK sensors=%u status=%u caps=0x%08X elevation=%d accel=%d,%d,%d camera=%s audio=%s skeleton=%s result=0x%08lX\n",
                r.sensorCount, r.status, r.capabilities, r.elevationDegrees, r.accelX, r.accelY, r.accelZ,
                r.cameraEndpoint, r.audioEndpoint, r.skeletonEndpoint, static_cast<unsigned long>(hr));
    return FAILED(hr) ? 8 : 0;
}

int RuntimeInfo() {
    Kinect360RemoldNui::Request q{};
    Kinect360RemoldNui::Reply r{};
    HRESULT hr = PipeExchange(Kinect360RemoldNui::kPipeName, q, r);
    if (FAILED(hr)) { std::printf("NUI discovery failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr)); return 9; }
    if (r.magic != Kinect360RemoldNui::kMagic || r.version != Kinect360RemoldNui::kVersion) return 9;
    hr = static_cast<HRESULT>(r.result);
    std::printf("NUI caps=0x%08X joints=%u camera=%s audio=%s audio-control=%s control=%s skeleton=%s sdk=%s result=0x%08lX\n",
                r.capabilities, r.jointCount, r.cameraEndpoint, r.audioEndpoint, r.audioControlEndpoint,
                r.controlEndpoint, r.skeletonEndpoint, r.sdkEndpoint, static_cast<unsigned long>(hr));
    return FAILED(hr) ? 9 : 0;
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
    const HRESULT hr = BrokerExchange(pingOnly ? Command::Ping : Command::Status, 0, deviceId, reply);
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
    const HRESULT hr = BrokerExchange(Command::Tilt, static_cast<int32_t>(value), deviceId, reply);
    if (FAILED(hr)) {
        std::printf("Broker Tilt failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 5;
    }
    std::printf("OK device=KinectXbox360 transport=broker requested=%ld actual=%.1f verified=1\n",
                value, static_cast<double>(reply.tiltTenths) / 10.0);
    return 0;
}

int BrokerLed(const wchar_t* mode, const std::string& deviceId) {
    const int state = ParseLed(mode);
    if (state < 0) return Usage();
    Reply reply{};
    const HRESULT hr = BrokerExchange(Command::Led, state, deviceId, reply);
    if (FAILED(hr)) {
        std::printf("Broker LED failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 6;
    }
    std::printf("OK device=KinectXbox360 transport=broker led=%d\n", state);
    return 0;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) return Usage();
    int arg = 1;
    std::string deviceId;
    if (arg + 1 < argc && _wcsicmp(argv[arg], L"--device") == 0) {
        deviceId = WideUtf8(argv[arg + 1]);
        if (deviceId.empty() || deviceId.size() >= Kinect360RemoldControl::kDeviceIdBytes) return Usage();
        arg += 2;
    }
    if (arg >= argc) return Usage();
    const wchar_t* command = argv[arg++];
    if (_wcsicmp(command, L"broker-status") == 0 && arg == argc) return BrokerStatus(true, deviceId);
    if (_wcsicmp(command, L"status") == 0 && arg == argc) return BrokerStatus(false, deviceId);
    if (_wcsicmp(command, L"sdk") == 0 && arg == argc) return SdkStatus(deviceId);
    if (_wcsicmp(command, L"runtime") == 0 && arg == argc) return RuntimeInfo();
    if (_wcsicmp(command, L"tilt") == 0 && arg + 1 == argc) return BrokerTilt(argv[arg], deviceId);
    if (_wcsicmp(command, L"led") == 0 && arg + 1 == argc) return BrokerLed(argv[arg], deviceId);
    return Usage();
}
