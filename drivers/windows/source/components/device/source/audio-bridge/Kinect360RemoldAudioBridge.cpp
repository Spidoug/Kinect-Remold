#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <sddl.h>
#include <usb.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <initguid.h>
#include <functiondiscoverykeys_devpkey.h>
#include <devpkey.h>
#include <devpropdef.h>
#include <propsys.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <deque>
#include <memory>
#include <mutex>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include "Kinect360RemoldAudioPort.h"
#include "Kinect360RemoldAudioFirmware.generated.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"
#include "Kinect360RemoldAudioControlProtocol.h"
#include "Kinect360RemoldDeviceIdentity.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "propsys.lib")

namespace {
namespace AudioPort = Kinect360RemoldAudioPort;
namespace Usb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;
namespace AudioControl = Kinect360RemoldAudioControl;
namespace Identity = Kinect360RemoldIdentity;
using Microsoft::WRL::ComPtr;

constexpr UCHAR kBootOutEndpoint = Hardware::Audio::kBootOutEndpoint;
constexpr UCHAR kBootInEndpoint = Hardware::Audio::kBootInEndpoint;
constexpr DWORD kAudioRetryMs = 500;
constexpr DWORD kPostFirmwareDelayMs = 1500;
constexpr DWORD kBootIoTimeoutMs = 10000;
constexpr DWORD kWasapiWaitMs = 500;
constexpr uint32_t kUacLoadAddress = 0x00080000u;
constexpr uint32_t kUacEntryAddress = 0x00080030u;
constexpr uint32_t kUacInitialTag = 1u;
constexpr uint32_t kUacProbeBytes = 0x60u;
constexpr uint32_t kUacProbeAddress = 0x15u;

constexpr GUID kSubTypePcm = {0x00000001, 0x0000, 0x0010, {0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};
constexpr GUID kSubTypeFloat = {0x00000003, 0x0000, 0x0010, {0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};

#pragma pack(push, 1)
struct BootCommand {
    uint32_t magic;
    uint32_t tag;
    uint32_t bytes;
    uint32_t command;
    uint32_t address;
    uint32_t unknown;
};
struct BootStatus {
    uint32_t magic;
    uint32_t tag;
    uint32_t status;
};
#pragma pack(pop)
static_assert(sizeof(BootCommand) == 24, "boot command ABI");
static_assert(sizeof(BootStatus) == 12, "boot status ABI");

std::atomic<bool> gRun{true};

HRESULT HrLastError() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

bool TryReadEnvironmentPath(const wchar_t* name, std::wstring& value) {
    value.clear();
    if (!name || !*name) return false;
    const DWORD required = GetEnvironmentVariableW(name, nullptr, 0);
    if (required == 0) return false;
    std::vector<wchar_t> buffer(static_cast<size_t>(required));
    const DWORD written = GetEnvironmentVariableW(name, buffer.data(), required);
    if (written == 0 || written >= required) return false;
    value.assign(buffer.data(), written);
    return !value.empty();
}

bool TryResolveCommonDataDirectory(std::wstring& directory) {
    if (!TryReadEnvironmentPath(L"ProgramData", directory) &&
        !TryReadEnvironmentPath(L"ALLUSERSPROFILE", directory)) {
        directory.clear();
        return false;
    }
    directory += L"\\";
    directory += AudioPort::kDiagnosticsDirectory;
    return true;
}

std::string NarrowForDiagnostic(const std::wstring& value) {
    std::string result;
    result.reserve(value.size());
    for (wchar_t ch : value) result.push_back(ch >= 0x20 && ch <= 0x7e ? static_cast<char>(ch) : '?');
    return result;
}

class AudioDiagnostics {
public:
    std::atomic<uint64_t> usbOpenAttempts{0};
    std::atomic<uint64_t> bootSessions{0};
    std::atomic<uint64_t> runtimeSessions{0};
    std::atomic<uint64_t> firmwareUploads{0};
    std::atomic<uint64_t> firmwareFailures{0};
    std::atomic<uint64_t> wasapiEndpointSearches{0};
    std::atomic<uint64_t> wasapiOpenFailures{0};
    std::atomic<uint64_t> wasapiPackets{0};
    std::atomic<uint64_t> wasapiFrames{0};
    std::atomic<uint64_t> wasapiSilentFrames{0};
    std::atomic<uint64_t> wasapiDiscontinuities{0};
    std::atomic<uint64_t> publishedFrames{0};
    std::atomic<uint64_t> pipeClients{0};
    std::atomic<uint64_t> pipeFrames{0};
    std::atomic<uint64_t> captureRate{0};
    std::atomic<uint64_t> captureChannels{0};
    std::atomic<uint64_t> captureBits{0};
    std::atomic<uint64_t> captureFormatTag{0};

    void SetEndpointName(const std::wstring& value) {
        std::lock_guard<std::mutex> guard(m_lock);
        m_endpointName = NarrowForDiagnostic(value);
    }

    void SetEndpointBinding(const std::wstring& instanceId, const std::string& deviceId) {
        std::lock_guard<std::mutex> guard(m_lock);
        m_endpointInstanceId = NarrowForDiagnostic(instanceId);
        m_endpointDeviceId = deviceId;
    }

    void SetCaptureMode(const char* value) {
        std::lock_guard<std::mutex> guard(m_lock);
        m_captureMode = value ? value : "";
    }

    void SetStage(const char* stage, DWORD error = ERROR_SUCCESS, const char* detail = "") {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_stage = stage ? stage : "unknown";
            m_detail = detail ? detail : "";
            m_lastError = error;
        }
        Write(true);
    }

    void Write(bool force = false) {
        const ULONGLONG now = GetTickCount64();
        std::string stage;
        std::string detail;
        std::string endpoint;
        std::string endpointInstanceId;
        std::string endpointDeviceId;
        std::string captureMode;
        DWORD lastError = ERROR_SUCCESS;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (!force && m_lastWriteTick != 0 && now - m_lastWriteTick < 500) return;
            m_lastWriteTick = now;
            stage = m_stage;
            detail = m_detail;
            endpoint = m_endpointName;
            endpointInstanceId = m_endpointInstanceId;
            endpointDeviceId = m_endpointDeviceId;
            captureMode = m_captureMode;
            lastError = m_lastError;
        }

        std::ostringstream text;
        text << "version=1\r\n";
        text << "heartbeat_ms=" << now << "\r\n";
        text << "audio_transport_model=winusb-boot-uac-runtime-wasapi\r\n";
        text << "boot_usb_pid=02ad\r\n";
        text << "runtime_usb_pid_family=02bb,02c3\r\n";
        text << "runtime_capture=wasapi-shared-windows-audio\r\n";
        text << "raw_audio_pipe=per-device\r\n";
        text << "raw_audio_bus=per-device-multi-client-latest-frame\r\n";
        text << "raw_audio_bus_mode=multi-client-latest-frame\r\n";
        text << "firmware_kind=Microsoft-Kinect-Runtime-1.8-UACFirmware\r\n";
        text << "firmware_version=" << gRemoldAudioFirmwareVersion << "\r\n";
        text << "firmware_bytes=" << gRemoldAudioFirmwareSize << "\r\n";
        text << "firmware_load_address=0x00080000\r\n";
        text << "firmware_entry_address=0x00080030\r\n";
        text << "uac_profile=microsoft-runtime-native-shared\r\n";
        text << "uac_iso_in_endpoint=0x82\r\n";
        text << "uac_iso_in_binterval=device-firmware-defined\r\n";
        text << "uac_channels=4\r\n";
        text << "uac_sample_rate=16000\r\n";
        text << "uac_bits_per_sample=32\r\n";
        text << "stage=" << stage << "\r\n";
        text << "detail=" << detail << "\r\n";
        text << "last_error=" << lastError << "\r\n";
        text << "endpoint_name=" << endpoint << "\r\n";
        text << "endpoint_instance_id=" << endpointInstanceId << "\r\n";
        text << "endpoint_device_id=" << endpointDeviceId << "\r\n";
        text << "capture_mode=" << captureMode << "\r\n";
        text << "usb_open_attempts=" << usbOpenAttempts.load() << "\r\n";
        text << "boot_sessions=" << bootSessions.load() << "\r\n";
        text << "runtime_sessions=" << runtimeSessions.load() << "\r\n";
        text << "firmware_uploads=" << firmwareUploads.load() << "\r\n";
        text << "firmware_failures=" << firmwareFailures.load() << "\r\n";
        text << "wasapi_endpoint_searches=" << wasapiEndpointSearches.load() << "\r\n";
        text << "wasapi_open_failures=" << wasapiOpenFailures.load() << "\r\n";
        text << "wasapi_packets=" << wasapiPackets.load() << "\r\n";
        text << "wasapi_frames=" << wasapiFrames.load() << "\r\n";
        text << "wasapi_silent_frames=" << wasapiSilentFrames.load() << "\r\n";
        text << "wasapi_discontinuities=" << wasapiDiscontinuities.load() << "\r\n";
        text << "capture_sample_rate=" << captureRate.load() << "\r\n";
        text << "stream_sample_rate=" << AudioPort::kSampleRate << "\r\n";
        text << "capture_channels=" << captureChannels.load() << "\r\n";
        text << "capture_bits=" << captureBits.load() << "\r\n";
        text << "capture_format_tag=" << captureFormatTag.load() << "\r\n";
        text << "published_frames=" << publishedFrames.load() << "\r\n";
        text << "pipe_clients=" << pipeClients.load() << "\r\n";
        text << "pipe_frames=" << pipeFrames.load() << "\r\n";

        std::wstring directory;
        if (!TryResolveCommonDataDirectory(directory)) return;
        if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return;
        const std::wstring path = directory + L"\\" + AudioPort::kDiagnosticsFileName;
        const std::wstring temporary = path + L".tmp";
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
        const std::string body = text.str();
        DWORD written = 0;
        const BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
        FlushFileBuffers(file);
        CloseHandle(file);
        if (ok && written == body.size()) {
            (void)MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        } else {
            (void)DeleteFileW(temporary.c_str());
        }
    }

private:
    std::mutex m_lock;
    std::string m_stage{"starting"};
    std::string m_detail;
    std::string m_endpointName;
    std::string m_endpointInstanceId;
    std::string m_endpointDeviceId;
    std::string m_captureMode;
    DWORD m_lastError = ERROR_SUCCESS;
    ULONGLONG m_lastWriteTick = 0;
};

AudioDiagnostics gDiagnostics;

class AudioPortServer {
public:
    explicit AudioPortServer(const wchar_t* pipeName) : m_pipeName(pipeName ? pipeName : L"") {}
    ~AudioPortServer() { Stop(); }

    HRESULT Start() {
        if (m_acceptThread.joinable()) return S_OK;
        m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stopEvent) return HrLastError();
        try { m_acceptThread = std::thread([this] { AcceptLoop(); }); }
        catch (const std::system_error&) {
            CloseHandle(m_stopEvent); m_stopEvent = nullptr;
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Stop() {
        if (m_stopEvent) SetEvent(m_stopEvent);
        m_frameCv.notify_all();
        if (m_acceptThread.joinable()) m_acceptThread.join();

        std::vector<std::thread> clients;
        {
            std::lock_guard<std::mutex> guard(m_clientThreadsLock);
            clients.swap(m_clientThreads);
        }
        for (auto& client : clients) if (client.joinable()) client.join();

        if (m_stopEvent) CloseHandle(m_stopEvent);
        m_stopEvent = nullptr;
        m_activeClients.store(0, std::memory_order_release);
    }

    uint32_t ActiveClients() const noexcept {
        return m_activeClients.load(std::memory_order_acquire);
    }

    void Publish(const int32_t* interleaved, uint32_t channelMask) {
        if (!interleaved || channelMask == 0) return;

        QueuedFrame frame;
        frame.header.channelMask = channelMask & 0x0fu;
        frame.header.frameNumber = ++m_frameNumber;
        frame.header.tickMs = GetTickCount64();
        frame.payload.resize(AudioPort::kPayloadBytes);
        std::memcpy(frame.payload.data(), interleaved, frame.payload.size());

        {
            std::lock_guard<std::mutex> guard(m_frameLock);
            m_latest = std::move(frame);
            ++m_generation;
            ++gDiagnostics.pipeFrames;
        }
        m_frameCv.notify_all();
    }

private:
    struct QueuedFrame {
        AudioPort::FrameHeader header{};
        std::vector<uint8_t> payload;
    };

    std::wstring m_pipeName;
    std::thread m_acceptThread;
    HANDLE m_stopEvent = nullptr;
    std::atomic<uint32_t> m_activeClients{0};
    std::atomic<uint64_t> m_frameNumber{0};

    std::mutex m_frameLock;
    std::condition_variable m_frameCv;
    QueuedFrame m_latest;
    uint64_t m_generation = 0;

    std::mutex m_clientThreadsLock;
    std::vector<std::thread> m_clientThreads;

    bool Stopping() const noexcept {
        return !gRun.load() || (m_stopEvent && WaitForSingleObject(m_stopEvent, 0) == WAIT_OBJECT_0);
    }

    bool TransferExact(HANDLE pipe, void* data, DWORD bytes, bool write, DWORD timeoutMs) {
        auto* cursor = static_cast<uint8_t*>(data);
        DWORD total = 0;
        while (total < bytes && !Stopping()) {
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) return false;
            OVERLAPPED ov{}; ov.hEvent = event;
            DWORD done = 0;
            BOOL ok = write ? WriteFile(pipe, cursor + total, bytes - total, &done, &ov)
                            : ReadFile(pipe, cursor + total, bytes - total, &done, &ov);
            if (!ok && GetLastError() == ERROR_IO_PENDING) {
                HANDLE waits[2]{m_stopEvent, event};
                const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, timeoutMs);
                if (wait != WAIT_OBJECT_0 + 1) {
                    (void)CancelIoEx(pipe, &ov);
                    (void)GetOverlappedResult(pipe, &ov, &done, TRUE);
                    CloseHandle(event);
                    return false;
                }
                ok = GetOverlappedResult(pipe, &ov, &done, FALSE);
            }
            CloseHandle(event);
            if (!ok || done == 0) return false;
            total += done;
        }
        return total == bytes;
    }

    bool ClientStillConnected(HANDLE pipe) const noexcept {
        DWORD available = 0;
        if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
            const DWORD e = GetLastError();
            if (e == ERROR_BROKEN_PIPE || e == ERROR_PIPE_NOT_CONNECTED || e == ERROR_NO_DATA) return false;
        }
        return true;
    }

    void ServeClient(HANDLE pipe) {
        AudioPort::Request request{};
        if (!TransferExact(pipe, &request, sizeof(request), false, 5000)) return;

        AudioPort::Reply reply{};
        if (request.magic != AudioPort::kMagic || request.version != AudioPort::kVersion ||
            request.command != AudioPort::Command::SubscribeMicrophones || request.reserved != 0) {
            reply.result = static_cast<int32_t>(E_INVALIDARG);
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        if (!TransferExact(pipe, &reply, sizeof(reply), true, 1000)) return;

        m_activeClients.fetch_add(1, std::memory_order_acq_rel);
        ++gDiagnostics.pipeClients;
        gDiagnostics.Write();

        uint64_t seenGeneration = 0;
        while (!Stopping()) {
            QueuedFrame frame;
            {
                std::unique_lock<std::mutex> lock(m_frameLock);
                m_frameCv.wait_for(lock, std::chrono::milliseconds(250), [this, &seenGeneration] {
                    return Stopping() || m_generation != seenGeneration;
                });
                if (Stopping()) break;
                if (!ClientStillConnected(pipe)) break;
                if (m_generation == seenGeneration || m_latest.payload.empty()) continue;

                // Each client gets an independent snapshot of the newest raw frame.
                // A slow UI client may skip stale blocks, but can never block capture or
                // another software instance.
                frame = m_latest;
                seenGeneration = m_generation;
            }

            if (!TransferExact(pipe, &frame.header, sizeof(frame.header), true, 2000)) break;
            if (!TransferExact(pipe, frame.payload.data(),
                               static_cast<DWORD>(frame.payload.size()), true, 2000)) break;
        }

        m_activeClients.fetch_sub(1, std::memory_order_acq_rel);
        gDiagnostics.Write();
    }

    void ClientThread(HANDLE pipe) {
        ServeClient(pipe);
        (void)DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }

    void AcceptLoop() {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        SECURITY_ATTRIBUTES security{}; security.nLength = sizeof(security);
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1,
                &descriptor, nullptr)) {
            security.lpSecurityDescriptor = descriptor;
        }

        while (!Stopping()) {
            HANDLE pipe = CreateNamedPipeW(
                m_pipeName.c_str(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                static_cast<DWORD>(sizeof(AudioPort::FrameHeader) + AudioPort::kPayloadBytes),
                static_cast<DWORD>(sizeof(AudioPort::Request)),
                0, security.lpSecurityDescriptor ? &security : nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;

            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) { CloseHandle(pipe); break; }
            OVERLAPPED ov{}; ov.hEvent = event;
            BOOL connected = ConnectNamedPipe(pipe, &ov);
            DWORD error = connected ? ERROR_SUCCESS : GetLastError();
            bool ready = connected || error == ERROR_PIPE_CONNECTED;

            if (!ready && error == ERROR_IO_PENDING) {
                HANDLE waits[2]{m_stopEvent, event};
                const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wait == WAIT_OBJECT_0 + 1) {
                    DWORD transferred = 0;
                    ready = GetOverlappedResult(pipe, &ov, &transferred, FALSE) != FALSE;
                } else {
                    (void)CancelIoEx(pipe, &ov);
                }
            }
            CloseHandle(event);

            if (!ready) {
                CloseHandle(pipe);
                continue;
            }

            try {
                std::thread client([this, pipe] { ClientThread(pipe); });
                std::lock_guard<std::mutex> guard(m_clientThreadsLock);
                m_clientThreads.emplace_back(std::move(client));
            } catch (const std::system_error&) {
                (void)DisconnectNamedPipe(pipe);
                CloseHandle(pipe);
            }
        }

        if (descriptor) LocalFree(descriptor);
    }
};

class RawAudioBus {
public:
    explicit RawAudioBus(AudioPortServer& server) : m_server(server) {}

    void Publish(const int32_t* interleaved, uint32_t channelMask) {
        if (!interleaved || channelMask == 0) return;
        const bool muted = m_muted.load(std::memory_order_acquire);
        const int volume = m_volume.load(std::memory_order_acquire);
        if (!muted && volume == 100) {
            m_server.Publish(interleaved, channelMask);
            return;
        }
        std::array<int32_t, AudioPort::kSamplesPerChannel * AudioPort::kChannels> adjusted{};
        for (size_t i = 0; i < adjusted.size(); ++i) {
            if (muted || volume == 0) { adjusted[i] = 0; continue; }
            const int64_t scaled = static_cast<int64_t>(interleaved[i]) * volume / 100;
            adjusted[i] = static_cast<int32_t>((std::max)(static_cast<int64_t>(INT32_MIN),
                               (std::min)(static_cast<int64_t>(INT32_MAX), scaled)));
        }
        m_server.Publish(adjusted.data(), channelMask);
    }

    int Volume() const noexcept { return m_volume.load(std::memory_order_acquire); }
    bool Muted() const noexcept { return m_muted.load(std::memory_order_acquire); }
    void SetVolume(int value) noexcept { m_volume.store((std::max)(0, (std::min)(100, value)), std::memory_order_release); }
    void SetMuted(bool value) noexcept { m_muted.store(value, std::memory_order_release); }

private:
    AudioPortServer& m_server;
    std::atomic<int> m_volume{100};
    std::atomic<bool> m_muted{false};
};

class AudioControlServer {
public:
    AudioControlServer(std::wstring pipeName, RawAudioBus& bus) : m_pipeName(std::move(pipeName)), m_bus(bus) {}
    ~AudioControlServer() { Stop(); }

    HRESULT Start() {
        if (m_thread.joinable()) return S_OK;
        m_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stop) return HrLastError();
        try { m_thread = std::thread([this]{ Loop(); }); }
        catch (const std::system_error&) { CloseHandle(m_stop); m_stop=nullptr; return E_OUTOFMEMORY; }
        return S_OK;
    }

    void Stop() {
        if (m_stop) SetEvent(m_stop);
        if (m_thread.joinable()) m_thread.join();
        if (m_stop) CloseHandle(m_stop);
        m_stop = nullptr;
    }

private:
    std::wstring m_pipeName;
    RawAudioBus& m_bus;
    HANDLE m_stop = nullptr;
    std::thread m_thread;

    void Serve(HANDLE pipe) {
        AudioControl::Request request{};
        DWORD done = 0;
        if (!ReadFile(pipe, &request, sizeof(request), &done, nullptr) || done != sizeof(request)) return;
        AudioControl::Reply reply{};
        if (request.magic != AudioControl::kMagic || request.version != AudioControl::kVersion) {
            reply.result = static_cast<int32_t>(E_INVALIDARG);
        } else {
            switch (request.command) {
                case AudioControl::Command::Ping:
                case AudioControl::Command::Get:
                    // Mixer state belongs to this per-Kinect AudioNode and is
                    // available independently of WASAPI capture re-enumeration.
                    break;
                case AudioControl::Command::SetVolume:
                    if (request.value < 0 || request.value > 100) reply.result = static_cast<int32_t>(E_INVALIDARG);
                    else m_bus.SetVolume(request.value);
                    break;
                case AudioControl::Command::SetMute:
                    m_bus.SetMuted(request.value != 0);
                    break;
                default:
                    reply.result = static_cast<int32_t>(E_INVALIDARG);
                    break;
            }
        }
        reply.volume = m_bus.Volume();
        reply.muted = m_bus.Muted() ? 1 : 0;
        done = 0;
        (void)WriteFile(pipe, &reply, sizeof(reply), &done, nullptr);
    }

    void Loop() {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        SECURITY_ATTRIBUTES security{sizeof(security)};
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1,
                &descriptor, nullptr)) security.lpSecurityDescriptor = descriptor;
        while (gRun.load() && WaitForSingleObject(m_stop, 0) != WAIT_OBJECT_0) {
            HANDLE pipe = CreateNamedPipeW(m_pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES, sizeof(AudioControl::Reply), sizeof(AudioControl::Request), 0,
                security.lpSecurityDescriptor ? &security : nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) { CloseHandle(pipe); break; }
            OVERLAPPED ov{}; ov.hEvent = event;
            BOOL connected = ConnectNamedPipe(pipe, &ov);
            DWORD error = connected ? ERROR_SUCCESS : GetLastError();
            bool ready = connected || error == ERROR_PIPE_CONNECTED;
            if (!ready && error == ERROR_IO_PENDING) {
                HANDLE waits[2]{m_stop, event};
                const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wait == WAIT_OBJECT_0 + 1) {
                    DWORD transferred=0; ready = GetOverlappedResult(pipe, &ov, &transferred, FALSE) != FALSE;
                } else (void)CancelIoEx(pipe, &ov);
            }
            CloseHandle(event);
            if (ready) Serve(pipe);
            (void)DisconnectNamedPipe(pipe);
            CloseHandle(pipe);
        }
        if (descriptor) LocalFree(descriptor);
    }
};

struct UsbSession {
    HANDLE file = INVALID_HANDLE_VALUE;
    Usb::Handle primary = nullptr;
    std::vector<Usb::Handle> interfaces;
    Usb::Handle selected = nullptr;
    UCHAR inputPipe = 0;
    UCHAR outputPipe = 0;
    std::wstring identityKey;

    ~UsbSession() {
        for (auto it = interfaces.rbegin(); it != interfaces.rend(); ++it) {
            if (*it) Usb::Get().Free(*it);
        }
        interfaces.clear();
        primary = nullptr;
        selected = nullptr;
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
    }
};

bool FindBootPipes(Usb::Handle iface, UCHAR& input, UCHAR& output) {
    auto& api = Usb::Get();
    for (UCHAR alt = 0; alt < 16; ++alt) {
        USB_INTERFACE_DESCRIPTOR desc{};
        if (!api.QueryInterfaceSettings(iface, alt, &desc)) continue;
        bool haveIn = false, haveOut = false;
        for (UCHAR i = 0; i < desc.bNumEndpoints; ++i) {
            Usb::PipeInformation pipe{};
            if (!api.QueryPipe(iface, alt, i, &pipe) || pipe.PipeType != UsbdPipeTypeBulk) continue;
            if (pipe.PipeId == kBootInEndpoint) { input = pipe.PipeId; haveIn = true; }
            else if (pipe.PipeId == kBootOutEndpoint) { output = pipe.PipeId; haveOut = true; }
        }
        if (haveIn && haveOut) {
            // Interface 0 is already active after WinUSB_Initialize. Avoid a
            // redundant SET_INTERFACE on the bootloader just as we do for the
            // 1473 runtime control interface.
            if (alt != 0 && !api.SetCurrentAlternateSetting(iface, alt)) return false;
            return true;
        }
    }
    return false;
}

std::wstring FirstDeviceLocationPath(HDEVINFO info, SP_DEVINFO_DATA& dev) {
    DWORD regType = 0;
    DWORD needed = 0;
    (void)SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_LOCATION_PATHS,
                                            &regType, nullptr, 0, &needed);
    if (needed < sizeof(wchar_t)) return {};
    std::vector<BYTE> buffer(needed + sizeof(wchar_t), 0);
    if (!SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_LOCATION_PATHS,
                                           &regType, buffer.data(), needed, nullptr)) return {};
    if (regType != REG_MULTI_SZ && regType != REG_SZ) return {};
    const auto* text = reinterpret_cast<const wchar_t*>(buffer.data());
    return (text && text[0]) ? std::wstring(text) : std::wstring{};
}

std::wstring NormalizeAudioLocationKey(std::wstring value) {
    return Identity::PhysicalParentLocation(std::move(value));
}

std::set<std::wstring> EnumerateAudioInterfaceLocationKeys(const GUID& guid) {
    std::set<std::wstring> keys;
    HDEVINFO set = SetupDiGetClassDevsW(&guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return keys;
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{}; iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &guid, index, &iface)) break;
        DWORD bytes = 0;
        SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
        (void)SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<uint8_t> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, &dev)) continue;
        std::wstring key = NormalizeAudioLocationKey(FirstDeviceLocationPath(set, dev));
        if (key.empty()) key = detail->DevicePath;
        if (!key.empty()) keys.insert(std::move(key));
    }
    SetupDiDestroyDeviceInfoList(set);
    return keys;
}

std::set<std::string> EnumerateInterfaceDeviceIds(const GUID& guid) {
    std::set<std::string> ids;
    HDEVINFO set = SetupDiGetClassDevsW(&guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return ids;
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{}; iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &guid, index, &iface)) break;
        DWORD bytes = 0;
        SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
        (void)SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<uint8_t> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, &dev)) continue;
        const std::string id = Identity::DeviceId(set, dev);
        if (!id.empty()) ids.insert(id);
    }
    SetupDiDestroyDeviceInfoList(set);
    return ids;
}

std::unique_ptr<UsbSession> OpenBootAudioUsb(const std::set<std::wstring>& suppressedKeys = {}) {
    ++gDiagnostics.usbOpenAttempts;
    if (!Usb::Ready()) {
        gDiagnostics.SetStage("winusb-load-error", Usb::Get().LoadError(), "system winusb.dll is unavailable");
        return {};
    }
    auto& api = Usb::Get();
    HDEVINFO set = SetupDiGetClassDevsW(&Hardware::kAudioTransportGuid, nullptr, nullptr,
                                        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return {};
    std::unique_ptr<UsbSession> result;
    for (DWORD index = 0; !result; ++index) {
        SP_DEVICE_INTERFACE_DATA ifaceData{}; ifaceData.cbSize = sizeof(ifaceData);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &Hardware::kAudioTransportGuid, index, &ifaceData)) break;
        DWORD bytes = 0;
        SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
        SetupDiGetDeviceInterfaceDetailW(set, &ifaceData, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<uint8_t> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &ifaceData, detail, bytes, nullptr, &dev)) continue;

        std::wstring identityKey = NormalizeAudioLocationKey(FirstDeviceLocationPath(set, dev));
        if (identityKey.empty()) identityKey = detail->DevicePath;
        if (suppressedKeys.find(identityKey) != suppressedKeys.end()) continue;

        auto session = std::make_unique<UsbSession>();
        session->identityKey = std::move(identityKey);
        session->file = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (session->file == INVALID_HANDLE_VALUE) continue;
        Usb::Handle primary = nullptr;
        if (!api.Initialize(session->file, &primary)) continue;
        session->primary = primary;
        session->interfaces.push_back(primary);
        for (UCHAR associatedIndex = 0; associatedIndex < 8; ++associatedIndex) {
            Usb::Handle associated = nullptr;
            if (!api.GetAssociatedInterface(primary, associatedIndex, &associated)) break;
            session->interfaces.push_back(associated);
        }
        for (auto iface : session->interfaces) {
            UCHAR in = 0, out = 0;
            if (FindBootPipes(iface, in, out)) {
                session->selected = iface;
                session->inputPipe = in;
                session->outputPipe = out;
                // Leave PIPE_TRANSFER_TIMEOUT at WinUSB's default. The loader
                // reference uses ordinary bulk transfers; the runtime bounds each I/O
                // explicitly with OVERLAPPED + CancelIoEx instead of arming a
                // persistent host-side pipe timer.
                result = std::move(session);
                break;
            }
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT WaitBootOverlapped(UsbSession& session, OVERLAPPED& ov, UINT& transferred) {
    const DWORD wait = WaitForSingleObject(ov.hEvent, kBootIoTimeoutMs);
    if (wait == WAIT_OBJECT_0) {
        return Usb::Get().GetOverlappedResult(session.selected, &ov, &transferred, FALSE)
            ? S_OK : HrLastError();
    }
    if (wait == WAIT_TIMEOUT) {
        (void)CancelIoEx(session.file, &ov);
        (void)WaitForSingleObject(ov.hEvent, 500);
        UINT ignored = 0;
        (void)Usb::Get().GetOverlappedResult(session.selected, &ov, &ignored, FALSE);
        return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    return HrLastError();
}

bool BulkWrite(UsbSession& session, const void* data, ULONG bytes) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return false;
    OVERLAPPED ov{}; ov.hEvent = event;
    UINT transferred = 0;
    BOOL ok = Usb::Get().WritePipe(session.selected, session.outputPipe,
                                   const_cast<PUCHAR>(static_cast<const UCHAR*>(data)), bytes,
                                   nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        hr = error == ERROR_IO_PENDING ? WaitBootOverlapped(session, ov, transferred)
                                       : HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = Usb::Get().GetOverlappedResult(session.selected, &ov, &transferred, FALSE)
            ? S_OK : HrLastError();
    }
    CloseHandle(event);
    if (FAILED(hr)) { SetLastError(HRESULT_CODE(hr)); return false; }
    if (transferred != bytes) { SetLastError(ERROR_WRITE_FAULT); return false; }
    return true;
}

HRESULT BulkReadPacket(UsbSession& session, void* data, ULONG capacity, ULONG expectedBytes) {
    if (!data || capacity < expectedBytes) return E_INVALIDARG;
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return HrLastError();
    OVERLAPPED ov{}; ov.hEvent = event;
    UINT transferred = 0;
    BOOL ok = Usb::Get().ReadPipe(session.selected, session.inputPipe, static_cast<PUCHAR>(data), capacity,
                                  nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        hr = error == ERROR_IO_PENDING ? WaitBootOverlapped(session, ov, transferred)
                                       : HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = Usb::Get().GetOverlappedResult(session.selected, &ov, &transferred, FALSE)
            ? S_OK : HrLastError();
    }
    CloseHandle(event);
    if (FAILED(hr)) return hr;
    if (expectedBytes == 0) return transferred != 0 ? S_OK : HRESULT_FROM_WIN32(ERROR_BAD_LENGTH);
    return transferred == expectedBytes ? S_OK : HRESULT_FROM_WIN32(ERROR_BAD_LENGTH);
}

HRESULT ReadBootStatus(UsbSession& session, uint32_t tag) {
    std::array<uint8_t, 512> reply{};
    HRESULT hr = BulkReadPacket(session, reply.data(), static_cast<ULONG>(reply.size()), static_cast<ULONG>(sizeof(BootStatus)));
    if (FAILED(hr)) return hr;
    BootStatus status{};
    std::memcpy(&status, reply.data(), sizeof(status));
    if (status.magic != Hardware::Audio::kBootStatusMagic || status.tag != tag || status.status != 0) {
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }
    return S_OK;
}

bool IsUsbDeviceGone(DWORD error) {
    return error == ERROR_DEVICE_NOT_CONNECTED || error == ERROR_NO_SUCH_DEVICE ||
           error == ERROR_GEN_FAILURE || error == ERROR_OPERATION_ABORTED || error == ERROR_INVALID_HANDLE;
}

HRESULT UploadUacFirmware(UsbSession& session) {
    if (!session.selected || gRemoldAudioFirmwareSize == 0) return E_UNEXPECTED;

    uint32_t tag = kUacInitialTag;
    BootCommand probe{Hardware::Audio::kBootCommandMagic, tag, kUacProbeBytes, 0u, kUacProbeAddress, 0u};
    if (!BulkWrite(session, &probe, static_cast<ULONG>(sizeof(probe)))) return HrLastError();

    // The UAC loader protocol has one 96-byte version reply before the normal
    // 12-byte status reply; the UAC image uses the raw bootloader layout.
    std::array<uint8_t, 512> versionReply{};
    HRESULT hr = BulkReadPacket(session, versionReply.data(), static_cast<ULONG>(versionReply.size()), 0);
    if (FAILED(hr)) return hr;
    hr = ReadBootStatus(session, tag);
    if (FAILED(hr)) return hr;
    ++tag;

    uint32_t address = kUacLoadAddress;
    uint32_t sent = 0;
    while (sent < gRemoldAudioFirmwareSize && gRun.load()) {
        const uint32_t page = std::min<uint32_t>(Hardware::Audio::kFirmwarePageBytes, gRemoldAudioFirmwareSize - sent);
        BootCommand command{Hardware::Audio::kBootCommandMagic, tag, page,
                            Hardware::Audio::kBootWriteCommand, address, 0u};
        if (!BulkWrite(session, &command, static_cast<ULONG>(sizeof(command)))) return HrLastError();
        uint32_t pageSent = 0;
        while (pageSent < page) {
            const uint32_t chunk = std::min<uint32_t>(Hardware::Audio::kFirmwareChunkBytes, page - pageSent);
            if (!BulkWrite(session, gRemoldAudioFirmware + sent + pageSent, chunk)) return HrLastError();
            pageSent += chunk;
        }
        hr = ReadBootStatus(session, tag);
        if (FAILED(hr)) return hr;
        sent += page;
        address += page;
        ++tag;
    }
    if (!gRun.load()) return HRESULT_FROM_WIN32(ERROR_CANCELLED);

    BootCommand launch{Hardware::Audio::kBootCommandMagic, tag, 0u,
                       Hardware::Audio::kBootLaunchCommand, kUacEntryAddress, 0u};
    if (!BulkWrite(session, &launch, static_cast<ULONG>(sizeof(launch)))) return HrLastError();
    hr = ReadBootStatus(session, tag);
    if (FAILED(hr) && !IsUsbDeviceGone(HRESULT_CODE(hr))) return hr;
    return S_OK;
}

bool ContainsInsensitive(const std::wstring& text, const wchar_t* needle) {
    if (!needle || !*needle) return true;
    std::wstring lhs(text);
    std::wstring rhs(needle);
    std::transform(lhs.begin(), lhs.end(), lhs.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    std::transform(rhs.begin(), rhs.end(), rhs.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return lhs.find(rhs) != std::wstring::npos;
}

std::wstring EndpointPropertyString(IMMDevice* device, REFPROPERTYKEY key) {
    if (!device) return {};
    ComPtr<IPropertyStore> store;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &store))) return {};
    PROPVARIANT value;
    PropVariantInit(&value);
    std::wstring result;
    if (SUCCEEDED(store->GetValue(key, &value)) && value.vt == VT_LPWSTR && value.pwszVal) {
        result = value.pwszVal;
    }
    PropVariantClear(&value);
    return result;
}

struct UacEndpointCandidate {
    ComPtr<IMMDevice> device;
    std::wstring friendlyName;
    std::wstring instanceId;
    std::string deviceId;
};

bool SetupDeviceInstanceId(HDEVINFO set, SP_DEVINFO_DATA& data, std::wstring& value) {
    value.clear();
    DWORD required = 0;
    (void)SetupDiGetDeviceInstanceIdW(set, &data, nullptr, 0, &required);
    if (required < 2) return false;
    std::vector<wchar_t> buffer(static_cast<size_t>(required) + 1u, L'\0');
    if (!SetupDiGetDeviceInstanceIdW(set, &data, buffer.data(), static_cast<DWORD>(buffer.size()), nullptr)) return false;
    value.assign(buffer.data());
    return !value.empty();
}

bool SetupDeviceStringProperty(HDEVINFO set, SP_DEVINFO_DATA& data, const DEVPROPKEY& key, std::wstring& value) {
    value.clear();
    DEVPROPTYPE type = 0;
    DWORD required = 0;
    (void)SetupDiGetDevicePropertyW(set, &data, &key, &type, nullptr, 0, &required, 0);
    if (required < sizeof(wchar_t)) return false;
    std::vector<BYTE> buffer(static_cast<size_t>(required) + sizeof(wchar_t), 0);
    if (!SetupDiGetDevicePropertyW(set, &data, &key, &type, buffer.data(), required, nullptr, 0)) return false;
    if (type != DEVPROP_TYPE_STRING) return false;
    const auto* text = reinterpret_cast<const wchar_t*>(buffer.data());
    if (!text || !text[0]) return false;
    value.assign(text);
    return true;
}

bool SetupDeviceGuidProperty(HDEVINFO set, SP_DEVINFO_DATA& data, const DEVPROPKEY& key, GUID& value) {
    DEVPROPTYPE type = 0;
    DWORD required = 0;
    GUID result{};
    if (!SetupDiGetDevicePropertyW(set, &data, &key, &type,
                                   reinterpret_cast<PBYTE>(&result), sizeof(result), &required, 0)) return false;
    if (type != DEVPROP_TYPE_GUID || required != sizeof(result)) return false;
    value = result;
    return true;
}

bool EndpointPropertyGuid(IMMDevice* device, REFPROPERTYKEY key, GUID& value) {
    if (!device) return false;
    ComPtr<IPropertyStore> store;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &store))) return false;
    PROPVARIANT property;
    PropVariantInit(&property);
    bool ok = false;
    if (SUCCEEDED(store->GetValue(key, &property)) && property.vt == VT_CLSID && property.puuid) {
        value = *property.puuid;
        ok = true;
    }
    PropVariantClear(&property);
    return ok;
}

bool IsKinectUacRuntimeInstance(const std::wstring& instanceId) {
    const bool runtimePid = ContainsInsensitive(instanceId, L"VID_045E&PID_02BB") ||
                            ContainsInsensitive(instanceId, L"VID_045E&PID_02C3");
    return runtimePid;
}

bool IsKinectUacCaptureInstance(const std::wstring& instanceId) {
    return IsKinectUacRuntimeInstance(instanceId) && ContainsInsensitive(instanceId, L"MI_02");
}

std::string DeviceIdFromPnpChain(const std::wstring& instanceId) {
    if (instanceId.empty()) return {};
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return {};
    std::wstring current = instanceId;
    std::set<std::wstring> visited;
    std::string result;
    for (unsigned depth = 0; depth < 16 && !current.empty(); ++depth) {
        std::wstring key = current;
        std::transform(key.begin(), key.end(), key.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        if (!visited.insert(key).second) break;
        SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
        if (!SetupDiOpenDeviceInfoW(set, current.c_str(), nullptr, 0, &data)) break;
        std::wstring actual;
        if (!SetupDeviceInstanceId(set, data, actual)) actual = current;
        if (IsKinectUacRuntimeInstance(actual)) {
            result = Identity::DeviceId(set, data);
            if (!result.empty()) break;
        }
        std::wstring parent;
        if (!SetupDeviceStringProperty(set, data, Identity::kDeviceParentKey, parent)) break;
        current = std::move(parent);
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

struct PhysicalUacCaptureDevice {
    std::wstring instanceId;
    std::string deviceId;
    GUID containerId{};
    bool hasContainerId = false;
};

std::vector<PhysicalUacCaptureDevice> EnumeratePhysicalUacCaptureDevices() {
    std::vector<PhysicalUacCaptureDevice> devices;
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return devices;
    std::set<std::string> seen;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) break;
        std::wstring instanceId;
        if (!SetupDeviceInstanceId(set, data, instanceId) || !IsKinectUacCaptureInstance(instanceId)) continue;
        std::string deviceId = Identity::DeviceId(set, data);
        if (deviceId.empty() || !seen.insert(deviceId).second) continue;
        PhysicalUacCaptureDevice item;
        item.instanceId = std::move(instanceId);
        item.deviceId = std::move(deviceId);
        item.hasContainerId = SetupDeviceGuidProperty(set, data, Identity::kDeviceContainerIdKey, item.containerId);
        devices.push_back(std::move(item));
    }
    SetupDiDestroyDeviceInfoList(set);
    std::sort(devices.begin(), devices.end(), [](const PhysicalUacCaptureDevice& a, const PhysicalUacCaptureDevice& b) {
        return a.deviceId < b.deviceId;
    });
    return devices;
}

std::set<std::string> EnumeratePresentKinectDeviceIds() {
    // Device presence is deliberately independent from WASAPI readiness.  This is
    // what keeps a stable per-Kinect audio pipe alive while 02AD firmware boot or
    // Windows USB-Audio re-enumeration is still in progress.  Both 1414 and 1473
    // follow the same rule and therefore expose the same reconnect behavior.
    std::set<std::string> ids;
    const GUID interfaceGuids[] = {
        Hardware::kCameraTransportGuid,
        Hardware::kNuiTransportGuid,
        Hardware::kAudioTransportGuid,
        Hardware::kAudioControlTransportGuid,
    };
    for (const auto& guid : interfaceGuids) {
        const auto found = EnumerateInterfaceDeviceIds(guid);
        ids.insert(found.begin(), found.end());
    }
    for (const auto& capture : EnumeratePhysicalUacCaptureDevices()) {
        if (!capture.deviceId.empty()) ids.insert(capture.deviceId);
    }
    return ids;
}

std::string DeviceIdFromContainer(IMMDevice* endpoint, const std::vector<PhysicalUacCaptureDevice>& physical) {
    GUID container{};
    if (!EndpointPropertyGuid(endpoint, PKEY_Device_ContainerId, container)) return {};
    std::string match;
    for (const auto& device : physical) {
        if (!device.hasContainerId || !IsEqualGUID(container, device.containerId)) continue;
        if (!match.empty() && match != device.deviceId) return {};
        match = device.deviceId;
    }
    return match;
}

HRESULT FindKinectUacCaptureEndpoints(std::vector<UacEndpointCandidate>& endpoints) {
    ++gDiagnostics.wasapiEndpointSearches;
    endpoints.clear();
    const auto physical = EnumeratePhysicalUacCaptureDevices();
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) return hr;
    ComPtr<IMMDeviceCollection> collection;
    hr = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(hr)) return hr;
    UINT count = 0; hr = collection->GetCount(&count); if (FAILED(hr)) return hr;
    std::vector<size_t> unresolved;
    for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> candidate; if (FAILED(collection->Item(index, &candidate))) continue;
        const std::wstring name = EndpointPropertyString(candidate.Get(), PKEY_Device_FriendlyName);
        const std::wstring instanceId = EndpointPropertyString(candidate.Get(), PKEY_Device_InstanceId);
        const bool exactUsb = IsKinectUacCaptureInstance(instanceId);
        const bool kinectNamed = ContainsInsensitive(name, L"Kinect") &&
            (ContainsInsensitive(name, L"Audio") || ContainsInsensitive(name, L"Microphone"));
        const bool xboxNuiNamed = ContainsInsensitive(name, L"Xbox NUI") && ContainsInsensitive(name, L"Audio");
        if (!exactUsb && !kinectNamed && !xboxNuiNamed) continue;

        std::string deviceId = DeviceIdFromPnpChain(instanceId);
        if (deviceId.empty()) deviceId = DeviceIdFromContainer(candidate.Get(), physical);

        UacEndpointCandidate item;
        item.device = candidate;
        item.instanceId = (exactUsb ? L"0:" : L"1:") + instanceId;
        item.friendlyName = name.empty() ? instanceId : name;
        item.deviceId = std::move(deviceId);
        endpoints.push_back(std::move(item));
        if (endpoints.back().deviceId.empty()) unresolved.push_back(endpoints.size() - 1u);
    }

    // Resolve only assignments that are provably unambiguous.  This covers the
    // common two-Kinect case where one MMDevice exposes its parent/container and
    // the other does not: once one physical ID is already claimed, a single
    // unresolved endpoint can safely take the single remaining Kinect ID.
    std::set<std::string> assigned;
    for (const auto& endpoint : endpoints) if (!endpoint.deviceId.empty()) assigned.insert(endpoint.deviceId);
    std::vector<std::string> remaining;
    for (const auto& device : physical) if (!assigned.count(device.deviceId)) remaining.push_back(device.deviceId);
    if (unresolved.size() == 1u && remaining.size() == 1u) {
        endpoints[unresolved.front()].deviceId = remaining.front();
    } else if (physical.size() == 1u) {
        for (size_t index : unresolved) endpoints[index].deviceId = physical.front().deviceId;
    }

    endpoints.erase(std::remove_if(endpoints.begin(), endpoints.end(), [](const UacEndpointCandidate& endpoint) {
        return endpoint.deviceId.empty();
    }), endpoints.end());
    std::sort(endpoints.begin(), endpoints.end(), [](const UacEndpointCandidate& a, const UacEndpointCandidate& b) {
        if (a.deviceId != b.deviceId) return a.deviceId < b.deviceId;
        return a.instanceId < b.instanceId;
    });
    return endpoints.empty() ? HRESULT_FROM_WIN32(ERROR_NOT_FOUND) : S_OK;
}

enum class SampleEncoding { Unsupported, Pcm16, Pcm24, Pcm32, Float32 };

SampleEncoding DetectEncoding(const WAVEFORMATEX* format) {
    if (!format) return SampleEncoding::Unsupported;
    WORD tag = format->wFormatTag;
    GUID subtype{};
    if (tag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        subtype = ext->SubFormat;
        if (IsEqualGUID(subtype, kSubTypeFloat) && format->wBitsPerSample == 32) return SampleEncoding::Float32;
        if (!IsEqualGUID(subtype, kSubTypePcm)) return SampleEncoding::Unsupported;
        tag = WAVE_FORMAT_PCM;
    }
    if (tag == WAVE_FORMAT_IEEE_FLOAT && format->wBitsPerSample == 32) return SampleEncoding::Float32;
    if (tag != WAVE_FORMAT_PCM) return SampleEncoding::Unsupported;
    switch (format->wBitsPerSample) {
        case 16: return SampleEncoding::Pcm16;
        case 24: return SampleEncoding::Pcm24;
        case 32: return SampleEncoding::Pcm32;
        default: return SampleEncoding::Unsupported;
    }
}

bool IsUsableCaptureFormat(const WAVEFORMATEX* format) {
    if (!format || format->nSamplesPerSec < AudioPort::kSampleRate || format->nSamplesPerSec > 192000 ||
        format->nChannels == 0 || format->nBlockAlign == 0) return false;
    return DetectEncoding(format) != SampleEncoding::Unsupported;
}

int32_t ReadSample(const uint8_t* sample, SampleEncoding encoding) {
    if (!sample) return 0;
    switch (encoding) {
        case SampleEncoding::Pcm16: {
            int16_t value = 0;
            std::memcpy(&value, sample, sizeof(value));
            return static_cast<int32_t>(value) << 16;
        }
        case SampleEncoding::Pcm24: {
            int32_t value = static_cast<int32_t>(sample[0]) |
                            (static_cast<int32_t>(sample[1]) << 8) |
                            (static_cast<int32_t>(sample[2]) << 16);
            if (value & 0x00800000) value |= static_cast<int32_t>(0xff000000u);
            return value << 8;
        }
        case SampleEncoding::Pcm32: {
            int32_t value = 0;
            std::memcpy(&value, sample, sizeof(value));
            return value;
        }
        case SampleEncoding::Float32: {
            float value = 0.0f;
            std::memcpy(&value, sample, sizeof(value));
            if (!std::isfinite(value)) value = 0.0f;
            value = std::max(-1.0f, std::min(1.0f, value));
            const double scaled = static_cast<double>(value) * 2147483647.0;
            return static_cast<int32_t>(scaled);
        }
        default: return 0;
    }
}

class WasapiFrameAssembler {
public:
    explicit WasapiFrameAssembler(RawAudioBus& port) : m_port(port) {}

    void Push(const BYTE* data, UINT32 frames, DWORD flags, const WAVEFORMATEX* format, SampleEncoding encoding) {
        if (!format || frames == 0 || format->nSamplesPerSec < AudioPort::kSampleRate) return;
        const uint32_t channels = format->nChannels;
        const uint32_t sampleBytes = format->wBitsPerSample / 8u;
        if (channels == 0 || sampleBytes == 0 ||
            format->nBlockAlign < channels * sampleBytes) return;
        const uint32_t activeChannels = std::min<uint32_t>(channels, AudioPort::kChannels);
        const uint32_t channelMask = (1u << activeChannels) - 1u;
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        if (silent) gDiagnostics.wasapiSilentFrames.fetch_add(frames);
        if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ++gDiagnostics.wasapiDiscontinuities;

        // The public ABI remains 4ch/16 kHz/S32LE, with a validity mask for the
        // channels actually supplied by the Windows shared endpoint. If the mix
        // rate is above 16 kHz, all supplied channels use the same phase
        // accumulator so their relative timing remains aligned.
        const uint64_t inputRate = format->nSamplesPerSec;
        for (UINT32 frame = 0; frame < frames; ++frame) {
            const BYTE* frameData = silent || !data ? nullptr : data + static_cast<size_t>(frame) * format->nBlockAlign;
            ++gDiagnostics.wasapiFrames;
            m_phase += AudioPort::kSampleRate;
            if (m_phase < inputRate) continue;
            m_phase -= inputRate;
            for (uint32_t channel = 0; channel < AudioPort::kChannels; ++channel)
                m_frame[m_frames * AudioPort::kChannels + channel] = 0;
            for (uint32_t channel = 0; channel < activeChannels; ++channel) {
                const BYTE* sample = frameData ? frameData + static_cast<size_t>(channel) * sampleBytes : nullptr;
                m_frame[m_frames * AudioPort::kChannels + channel] = silent ? 0 : ReadSample(sample, encoding);
            }
            ++m_frames;
            if (m_frames == AudioPort::kSamplesPerChannel) {
                m_port.Publish(m_frame.data(), channelMask);
                ++gDiagnostics.publishedFrames;
                m_frames = 0;
            }
        }
    }

private:
    RawAudioBus& m_port;
    std::array<int32_t, AudioPort::kSamplesPerChannel * AudioPort::kChannels> m_frame{};
    uint32_t m_frames = 0;
    uint64_t m_phase = 0;
};

HRESULT RunWasapiCaptureSession(IMMDevice* endpoint,
                                const std::wstring& friendlyName,
                                const WAVEFORMATEX* selected,
                                RawAudioBus& port,
                                const char* captureMode,
                                const std::atomic<bool>* nodeRun = nullptr) {
    if (!endpoint || !selected) return E_POINTER;
    ComPtr<IAudioClient> audioClient;
    HRESULT hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr,
                                    reinterpret_cast<void**>(audioClient.GetAddressOf()));
    if (FAILED(hr)) return hr;

    // Shared event-driven WASAPI uses 0/0 duration/periodicity and lets the
    // Windows audio engine select the endpoint period.  Keeping MI_02 shared is
    // required so the Windows Sound meter, volume control and other clients
    // continue to receive the live Kinect signal while Remold is running.
    const DWORD streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST;
    HANDLE readyEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!readyEvent) return HrLastError();
    hr = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, 0, 0, selected, nullptr);
    if (SUCCEEDED(hr)) hr = audioClient->SetEventHandle(readyEvent);
    ComPtr<IAudioCaptureClient> captureClient;
    if (SUCCEEDED(hr)) hr = audioClient->GetService(IID_PPV_ARGS(&captureClient));
    if (SUCCEEDED(hr)) hr = audioClient->Start();
    if (FAILED(hr)) { if (readyEvent) CloseHandle(readyEvent); return hr; }

    const SampleEncoding encoding = DetectEncoding(selected);
    if (encoding == SampleEncoding::Unsupported || selected->nChannels == 0) {
        (void)audioClient->Stop(); if (readyEvent) CloseHandle(readyEvent); return AUDCLNT_E_UNSUPPORTED_FORMAT;
    }

    gDiagnostics.SetEndpointName(friendlyName);
    gDiagnostics.SetCaptureMode(captureMode);
    gDiagnostics.captureRate = selected->nSamplesPerSec;
    gDiagnostics.captureChannels = selected->nChannels;
    gDiagnostics.captureBits = selected->wBitsPerSample;
    gDiagnostics.captureFormatTag = selected->wFormatTag;
    ++gDiagnostics.runtimeSessions;
    gDiagnostics.SetStage("uac-runtime-capturing", ERROR_SUCCESS, captureMode);

    WasapiFrameAssembler assembler(port);
    HRESULT result = S_OK;
    while (gRun.load() && (!nodeRun || nodeRun->load(std::memory_order_acquire))) {
        const DWORD wait = WaitForSingleObject(readyEvent, kWasapiWaitMs);
        if (wait == WAIT_TIMEOUT) { gDiagnostics.Write(); continue; }
        if (wait != WAIT_OBJECT_0) { result = HrLastError(); break; }

        UINT32 packetFrames = 0;
        hr = captureClient->GetNextPacketSize(&packetFrames);
        if (FAILED(hr)) { result = hr; break; }
        while (packetFrames != 0 && gRun.load() && (!nodeRun || nodeRun->load(std::memory_order_acquire))) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            UINT64 devicePosition = 0, qpcPosition = 0;
            hr = captureClient->GetBuffer(&data, &frames, &flags, &devicePosition, &qpcPosition);
            if (FAILED(hr)) { result = hr; break; }
            (void)devicePosition; (void)qpcPosition;
            ++gDiagnostics.wasapiPackets;
            assembler.Push(data, frames, flags, selected, encoding);
            hr = captureClient->ReleaseBuffer(frames);
            if (FAILED(hr)) { result = hr; break; }
            hr = captureClient->GetNextPacketSize(&packetFrames);
            if (FAILED(hr)) { result = hr; break; }
        }
        if (FAILED(hr)) break;
        gDiagnostics.Write();
    }
    (void)audioClient->Stop();
    if (readyEvent) CloseHandle(readyEvent);
    return result;
}

HRESULT CaptureUacRuntime(IMMDevice* endpoint, const std::wstring& friendlyName, RawAudioBus& port, const std::atomic<bool>* nodeRun = nullptr) {
    if (!endpoint) return E_POINTER;
    gDiagnostics.SetEndpointName(friendlyName);
    gDiagnostics.SetCaptureMode("probing-shared");

    // Keep the Kinect capture endpoint in WASAPI shared mode.  On the 1473 an
    // Taking exclusive ownership of MI_02 can leave Windows listing the
    // microphone while the Sound control-panel meter and other capture clients
    // stop receiving the live signal.  The 1414 already works in shared mode;
    // using the endpoint's mix format gives the 1473 the same Windows behavior.
    ComPtr<IAudioClient> probe;
    HRESULT hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr,
                                    reinterpret_cast<void**>(probe.GetAddressOf()));
    if (FAILED(hr)) return hr;

    WAVEFORMATEX* mixFormat = nullptr;
    hr = probe->GetMixFormat(&mixFormat);
    if (FAILED(hr) || !mixFormat) return FAILED(hr) ? hr : E_UNEXPECTED;
    if (!IsUsableCaptureFormat(mixFormat)) {
        CoTaskMemFree(mixFormat);
        gDiagnostics.SetCaptureMode("unsupported-shared-format");
        return AUDCLNT_E_UNSUPPORTED_FORMAT;
    }

    const HRESULT capture = RunWasapiCaptureSession(endpoint, friendlyName, mixFormat,
        port, "wasapi-shared-native-input", nodeRun);
    CoTaskMemFree(mixFormat);
    if (FAILED(capture)) ++gDiagnostics.wasapiOpenFailures;
    return capture;
}

void FirmwareLoop() {
    // UACFirmware is a boot transition, not a periodic keep-alive. Remember a
    // successful launch per physical Kinect/USB port and do not upload again
    // while that sensor is still present. This prevents a failed 02AD->UAC-runtime
    // transition from becoming an endless Windows connect/disconnect loop.
    std::set<std::wstring> launchedKeys;
    std::map<std::wstring, unsigned> absentPasses;
    constexpr unsigned kDisconnectPasses = 6; // ~3 s at kAudioRetryMs

    while (gRun.load()) {
        const auto bootPresent = EnumerateAudioInterfaceLocationKeys(Hardware::kAudioTransportGuid);
        const auto controlPresent = EnumerateAudioInterfaceLocationKeys(Hardware::kAudioControlTransportGuid);
        std::set<std::wstring> familyPresent = bootPresent;
        familyPresent.insert(controlPresent.begin(), controlPresent.end());

        for (auto it = launchedKeys.begin(); it != launchedKeys.end();) {
            if (familyPresent.find(*it) != familyPresent.end()) {
                absentPasses[*it] = 0;
                ++it;
                continue;
            }
            unsigned& passes = absentPasses[*it];
            if (++passes >= kDisconnectPasses) {
                absentPasses.erase(*it);
                it = launchedKeys.erase(it);
            } else {
                ++it;
            }
        }

        auto boot = OpenBootAudioUsb(launchedKeys);
        if (boot) {
            const std::wstring key = boot->identityKey;
            ++gDiagnostics.bootSessions;
            gDiagnostics.SetStage("uac-firmware-uploading", ERROR_SUCCESS,
                                  "uploading Microsoft Kinect Runtime v1.8 UACFirmware 01.02.709.00 through 02AD WinUSB bulk endpoints");
            const HRESULT upload = UploadUacFirmware(*boot);
            boot.reset();
            if (SUCCEEDED(upload)) {
                ++gDiagnostics.firmwareUploads;
                if (!key.empty()) {
                    launchedKeys.insert(key);
                    absentPasses[key] = 0;
                }
                gDiagnostics.SetStage("uac-firmware-launched", ERROR_SUCCESS,
                                      "waiting for 045E:02BB/02C3 Kinect USB Audio re-enumeration; this boot epoch will not be reflashed");
                Sleep(kPostFirmwareDelayMs);
            } else {
                ++gDiagnostics.firmwareFailures;
                gDiagnostics.SetStage("uac-firmware-error", HRESULT_CODE(upload),
                                      "UACFirmware upload/bootloader handshake failed");
                Sleep(kAudioRetryMs);
            }
            continue;
        }
        Sleep(kAudioRetryMs);
    }
}

std::wstring PerDevicePipe(const wchar_t* prefix, const std::string& id) {
    return std::wstring(L"\\\\.\\pipe\\") + prefix + std::wstring(id.begin(), id.end());
}

class AudioNode {
public:
    explicit AudioNode(std::string id)
        : m_id(std::move(id)),
          m_audioPipe(PerDevicePipe(L"Kinect360RemoldAudio-", m_id)),
          m_controlPipe(PerDevicePipe(L"Kinect360RemoldAudioControl-", m_id)),
          m_server(m_audioPipe.c_str()), m_bus(m_server), m_control(m_controlPipe, m_bus) {}
    ~AudioNode() { Stop(); }

    HRESULT Start() {
        HRESULT hr = m_server.Start();
        if (FAILED(hr)) return hr;
        hr = m_control.Start();
        if (FAILED(hr)) { m_server.Stop(); return hr; }
        m_run.store(true, std::memory_order_release);
        try { m_thread = std::thread([this]{ Capture(); }); }
        catch (const std::system_error&) { m_run.store(false); m_control.Stop(); m_server.Stop(); return E_OUTOFMEMORY; }
        return S_OK;
    }

    void Stop() {
        m_run.store(false, std::memory_order_release);
        if (m_thread.joinable()) m_thread.join();
        m_control.Stop();
        m_server.Stop();
    }

private:
    std::string m_id;
    std::wstring m_audioPipe;
    std::wstring m_controlPipe;
    AudioPortServer m_server;
    RawAudioBus m_bus;
    AudioControlServer m_control;
    std::atomic<bool> m_run{false};
    std::thread m_thread;

    void Capture() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        const bool uninitialize = SUCCEEDED(com);
        if (FAILED(com) && com != RPC_E_CHANGED_MODE) return;
        while (gRun.load() && m_run.load(std::memory_order_acquire)) {
            std::vector<UacEndpointCandidate> endpoints;
            if (SUCCEEDED(FindKinectUacCaptureEndpoints(endpoints))) {
                bool attempted = false;
                for (auto& endpoint : endpoints) {
                    if (endpoint.deviceId != m_id) continue;
                    attempted = true;
                    gDiagnostics.SetEndpointBinding(endpoint.instanceId, endpoint.deviceId);
                    const HRESULT hr = CaptureUacRuntime(endpoint.device.Get(), endpoint.friendlyName, m_bus, &m_run);
                    if (!gRun.load() || !m_run.load(std::memory_order_acquire)) break;
                    if (FAILED(hr)) Sleep(kAudioRetryMs);
                    break;
                }
                if (!attempted) {
                    gDiagnostics.SetStage("uac-runtime-reconnecting", ERROR_NOT_READY,
                                          "physical Kinect present; waiting for its Windows USB Audio capture endpoint");
                    Sleep(kAudioRetryMs);
                }
            } else {
                gDiagnostics.SetStage("uac-runtime-reconnecting", ERROR_NOT_READY,
                                      "waiting for Kinect Windows USB Audio capture endpoint");
                Sleep(kAudioRetryMs);
            }
        }
        if (uninitialize) CoUninitialize();
    }
};

void AudioCoordinatorLoop() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninitialize = SUCCEEDED(com);
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) return;
    std::map<std::string, std::unique_ptr<AudioNode>> nodes;
    std::map<std::string, std::chrono::steady_clock::time_point> lastSeen;
    constexpr auto reconnectGrace = std::chrono::seconds(30);
    while (gRun.load()) {
        const auto now = std::chrono::steady_clock::now();
        const std::set<std::string> present = EnumeratePresentKinectDeviceIds();
        for (const auto& deviceId : present) {
            lastSeen[deviceId] = now;
            auto nodeIt = nodes.find(deviceId);
            if (nodeIt == nodes.end()) {
                auto node = std::make_unique<AudioNode>(deviceId);
                if (SUCCEEDED(node->Start())) nodeIt = nodes.emplace(deviceId, std::move(node)).first;
            }
        }
        for (auto it = nodes.begin(); it != nodes.end();) {
            if (present.count(it->first)) { ++it; continue; }
            const auto seen = lastSeen.find(it->first);
            const bool expired = seen == lastSeen.end() || now - seen->second >= reconnectGrace;
            if (!expired) { ++it; continue; }
            it->second->Stop();
            lastSeen.erase(it->first);
            it = nodes.erase(it);
        }
        for (DWORD slept=0; slept<kAudioRetryMs && gRun.load(); slept+=50) Sleep(50);
    }
    for (auto& node : nodes) node.second->Stop();
    if (uninitialize) CoUninitialize();
}

int RunHost() {
    gDiagnostics.SetStage("starting");
    std::thread firmware(FirmwareLoop);
    std::thread coordinator(AudioCoordinatorLoop);
    while (gRun.load()) Sleep(200);
    if (coordinator.joinable()) coordinator.join();
    if (firmware.joinable()) firmware.join();
    return 0;
}

SERVICE_STATUS_HANDLE gServiceHandle = nullptr;
SERVICE_STATUS gServiceStatus{};

void WINAPI ServiceControl(DWORD control) {
    if (control != SERVICE_CONTROL_STOP && control != SERVICE_CONTROL_SHUTDOWN) return;
    gRun.store(false);
    gServiceStatus.dwCurrentState = SERVICE_STOP_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    if (gServiceHandle) SetServiceStatus(gServiceHandle, &gServiceStatus);
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gServiceHandle = RegisterServiceCtrlHandlerW(L"Kinect360RemoldAudioBridge", ServiceControl);
    if (!gServiceHandle) return;
    gServiceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    gServiceStatus.dwCurrentState = SERVICE_START_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwWin32ExitCode = NO_ERROR;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
    gRun.store(true);
    gServiceStatus.dwCurrentState = SERVICE_RUNNING;
    gServiceStatus.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
    const int rc = RunHost();
    gServiceStatus.dwCurrentState = SERVICE_STOPPED;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwWin32ExitCode = rc == 0 ? NO_ERROR : ERROR_SERVICE_SPECIFIC_ERROR;
    gServiceStatus.dwServiceSpecificExitCode = static_cast<DWORD>(rc);
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}

BOOL WINAPI ConsoleControl(DWORD control) {
    if (control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT || control == CTRL_CLOSE_EVENT ||
        control == CTRL_SHUTDOWN_EVENT) { gRun.store(false); return TRUE; }
    return FALSE;
}
} // namespace

int wmain() {
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(L"Kinect360RemoldAudioBridge"), ServiceMain},
        {nullptr, nullptr}
    };
    if (StartServiceCtrlDispatcherW(table)) return 0;
    if (GetLastError() != ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) return 1;
    (void)SetConsoleCtrlHandler(ConsoleControl, TRUE);
    gRun.store(true);
    return RunHost();
}
