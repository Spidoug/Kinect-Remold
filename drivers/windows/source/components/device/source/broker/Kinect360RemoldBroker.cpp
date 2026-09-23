#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <sstream>
#include <fstream>
#include <filesystem>
#include <mutex>
#include <map>
#include <memory>
#include <optional>
#include <thread>
#include <vector>
#include <string>

#include "Kinect360RemoldControlProtocol.h"
#include "Kinect360RemoldDevicePolicy.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"
#include "Kinect360RemoldDeviceIdentity.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;
using Kinect360RemoldControl::Transport;

namespace Policy = Kinect360RemoldDevicePolicy;
namespace WinUsb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;

std::atomic<bool> gRun{true};
HRESULT HrFromLastError() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

enum class PhysicalTransportKind : uint8_t {
    None = 0,
    Classic1414,
    AudioControl1473,
};

struct PhysicalNuiSession {
    HANDLE file = INVALID_HANDLE_VALUE;
    WinUsb::Handle usb = nullptr;
    PhysicalTransportKind kind = PhysicalTransportKind::None;
    uint32_t nextTag = 0;
    UCHAR controlInEndpoint = 0;
    UCHAR controlOutEndpoint = 0;
    UCHAR controlAltSetting = 0;
    bool controlPipesReady = false;
    bool prepared = false;
    bool lastTiltValid = false;   // last measured angle, used to size 1473 travel
    LONG lastTiltTenths = 0;
    std::string deviceId;
    bool Ready() const noexcept { return file != INVALID_HANDLE_VALUE && usb != nullptr; }
    void Close() noexcept {
        if (usb) WinUsb::Get().Free(usb);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        usb = nullptr;
        file = INVALID_HANDLE_VALUE;
        kind = PhysicalTransportKind::None;
        nextTag = 0;
        controlInEndpoint = 0;
        controlOutEndpoint = 0;
        controlAltSetting = 0;
        controlPipesReady = false;
        prepared = false;
        lastTiltValid = false;
        lastTiltTenths = 0;
        deviceId.clear();
    }
    ~PhysicalNuiSession() { Close(); }
};

struct PhysicalNuiContext {
    std::mutex mutex;
    PhysicalNuiSession session;
    // Set for the whole Tilt command, including uninterrupted travel. Status
    // never queues behind it: the camera service's motion sampler receives
    // ERROR_BUSY immediately and keeps its last sample until it goes stale.
    std::atomic<bool> tiltInFlight{false};
};

std::mutex gPhysicalContextsMutex;
std::map<std::string, std::shared_ptr<PhysicalNuiContext>> gPhysicalContexts;
std::mutex gPhysicalIoMutexesMutex;
std::map<std::string, std::shared_ptr<std::mutex>> gPhysicalIoMutexes;

std::shared_ptr<std::mutex> PhysicalIoMutexFor(const std::string& deviceId) {
    const std::string key = deviceId.empty() ? std::string("__unknown__") : deviceId;
    std::lock_guard<std::mutex> guard(gPhysicalIoMutexesMutex);
    auto& mutex = gPhysicalIoMutexes[key];
    if (!mutex) mutex = std::make_shared<std::mutex>();
    return mutex;
}

std::shared_ptr<PhysicalNuiContext> PhysicalContextFor(const std::string& deviceId) {
    const std::string key = deviceId.empty() ? std::string("__auto__") : deviceId;
    std::lock_guard<std::mutex> guard(gPhysicalContextsMutex);
    auto& context = gPhysicalContexts[key];
    if (!context) context = std::make_shared<PhysicalNuiContext>();
    return context;
}

void ClosePhysicalContexts() {
    std::lock_guard<std::mutex> guard(gPhysicalContextsMutex);
    for (auto& entry : gPhysicalContexts) {
        std::lock_guard<std::mutex> contextGuard(entry.second->mutex);
        entry.second->session.Close();
    }
    gPhysicalContexts.clear();
    {
        std::lock_guard<std::mutex> ioGuard(gPhysicalIoMutexesMutex);
        gPhysicalIoMutexes.clear();
    }
}

constexpr DWORD kControlIoTimeoutMs = 750;

bool Discover1473ControlPipes(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    auto& api = WinUsb::Get();

    // Do not assume that the active alternate setting or endpoint numbers are
    // already what the firmware uses. The Microsoft Kinect Audio Array Control
    // package and our fallback both expose MI_00 through WinUSB, but the only
    // authoritative source is the live interface descriptor. This also catches
    // partial 02BB enumerations instead of converting them into ERROR_GEN_FAILURE
    // on the first command.
    for (UCHAR alt = 0; alt < 16; ++alt) {
        USB_INTERFACE_DESCRIPTOR descriptor{};
        if (!api.QueryInterfaceSettings(session.usb, alt, &descriptor)) continue;
        UCHAR in = 0;
        UCHAR out = 0;
        for (UCHAR index = 0; index < descriptor.bNumEndpoints; ++index) {
            WinUsb::PipeInformation pipe{};
            if (!api.QueryPipe(session.usb, alt, index, &pipe) || pipe.PipeType != UsbdPipeTypeBulk) continue;
            if ((pipe.PipeId & 0x80u) != 0) {
                if (!in || pipe.PipeId == Hardware::AudioControl::kInEndpoint) in = pipe.PipeId;
            } else {
                if (!out || pipe.PipeId == Hardware::AudioControl::kOutEndpoint) out = pipe.PipeId;
            }
        }
        if (!in || !out) continue;
        // WinUSB starts on alternate setting 0. Do not issue an unnecessary
        // SET_INTERFACE for the normal MI_00 layout; some 1473 firmware/host
        // combinations report a generic device failure for redundant requests.
        if (alt != 0 && !api.SetCurrentAlternateSetting(session.usb, alt)) return false;
        session.controlInEndpoint = in;
        session.controlOutEndpoint = out;
        session.controlAltSetting = alt;
        session.controlPipesReady = true;
        return true;
    }
    SetLastError(ERROR_NOT_READY);
    return false;
}

bool Validate1473RuntimeConfiguration(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    USB_CONFIGURATION_DESCRIPTOR config{};
    ULONG transferred = 0;
    if (!WinUsb::Get().GetDescriptor(session.usb, USB_CONFIGURATION_DESCRIPTOR_TYPE, 0, 0,
                                     reinterpret_cast<PUCHAR>(&config), sizeof(config), &transferred))
        return false;
    if (transferred < sizeof(config) || config.bDescriptorType != USB_CONFIGURATION_DESCRIPTOR_TYPE) {
        SetLastError(ERROR_INVALID_DATA);
        return false;
    }
    // Interface count is not a capability gate on model 1473. Captured Xbox
    // runtimes may expose control and audio endpoints through a single interface,
    // while other firmware builds expose MI_00/MI_01/MI_02. The
    // authoritative control probe is Discover1473ControlPipes(), which validates
    // the live bulk IN/OUT endpoints after this descriptor sanity check.
    if (config.bNumInterfaces == 0) {
        SetLastError(ERROR_NOT_READY);
        return false;
    }
    return true;
}

bool Configure1473ControlTimeouts(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    if (!session.controlPipesReady && !Discover1473ControlPipes(session)) return false;

    // Keep WinUSB's PIPE_TRANSFER_TIMEOUT at its default (0). A non-zero pipe
    // policy makes the USB stack itself cancel requests and report
    // ERROR_SEM_TIMEOUT (121), which is exactly the failure seen on some 1473
    // controllers. The broker owns the timeout with OVERLAPPED I/O instead, so
    // a timeout cancels only the current request and the interface can be
    // reopened cleanly without leaving a host-controller timer armed.
    return true;
}

HRESULT OpenPhysicalInterface(const GUID& guid, PhysicalTransportKind kind, PhysicalNuiSession& session, const std::string& targetId) {
    HDEVINFO set = SetupDiGetClassDevsW(
        &guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return HrFromLastError();

    HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{};
        iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &guid, index, &iface)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) result = HrFromLastError();
            break;
        }

        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, &dev)) continue;
        const std::string candidateId = Kinect360RemoldIdentity::DeviceId(set, dev);
        if (!targetId.empty() && candidateId != targetId) continue;

        HANDLE file = CreateFileW(
            detail->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            nullptr);
        if (file == INVALID_HANDLE_VALUE) continue;

        WinUsb::Handle usb = nullptr;
        if (!WinUsb::Ready() || !WinUsb::Get().Initialize(file, &usb)) {
            result = HrFromLastError();
            CloseHandle(file);
            continue;
        }

        session.file = file;
        session.usb = usb;
        session.kind = kind;
        session.deviceId = candidateId;
        session.nextTag = 0;
        if (kind == PhysicalTransportKind::AudioControl1473 &&
            (!Validate1473RuntimeConfiguration(session) || !Configure1473ControlTimeouts(session))) {
            result = HrFromLastError();
            session.Close();
            continue;
        }
        result = S_OK;
        break;
    }

    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT OpenClassic1414(PhysicalNuiSession& session, const std::string& targetId) {
    const HRESULT hr = OpenPhysicalInterface(Hardware::kNuiTransportGuid, PhysicalTransportKind::Classic1414, session, targetId);
    if (FAILED(hr)) session.Close();
    return hr;
}

HRESULT OpenAudioControl1473(PhysicalNuiSession& session, const std::string& targetId) {
    const HRESULT hr = OpenPhysicalInterface(Hardware::kAudioControlTransportGuid, PhysicalTransportKind::AudioControl1473, session, targetId);
    if (FAILED(hr)) session.Close();
    return hr;
}

HRESULT OpenPhysicalNui(PhysicalNuiSession& session, const std::string& targetId) {
    // Same selection as the Linux broker. A device-scoped request resolves the
    // model from its 02AE camera: 1414 is pinned to 02B0 and never falls
    // through to 02BB/02C3, which is only its UAC audio function; 1473 is
    // pinned to 02BB/02C3&MI_00. An unscoped diagnostic request, or a sensor
    // whose camera is re-enumerating, prefers the unambiguous 02B0 function.
    const Hardware::Model model = targetId.empty()
        ? Hardware::Model::Unknown : Kinect360RemoldIdentity::CameraModel(targetId);
    if (model == Hardware::Model::Xbox1414) return OpenClassic1414(session, targetId);
    if (model == Hardware::Model::Xbox1473) return OpenAudioControl1473(session, targetId);
    const HRESULT classicHr = OpenClassic1414(session, targetId);
    if (SUCCEEDED(classicHr)) return classicHr;
    return OpenAudioControl1473(session, targetId);
}

HRESULT EnsurePhysicalNui(PhysicalNuiSession& session, const std::string& targetId) {
    if (session.Ready() && (targetId.empty() || session.deviceId == targetId)) return S_OK;
    session.Close();
    return OpenPhysicalNui(session, targetId);
}

#pragma pack(push, 1)
struct AltMotorCommand {
    uint32_t magic;
    uint32_t tag;
    uint32_t arg1;
    uint32_t command;
    uint32_t arg2;
};
struct AltMotorReply {
    uint32_t magic;
    uint32_t tag;
    uint32_t status;
};
#pragma pack(pop)
static_assert(sizeof(AltMotorCommand) == 20, "1473 motor command ABI");
static_assert(sizeof(AltMotorReply) == 12, "1473 motor reply ABI");

HRESULT Wait1473Overlapped(PhysicalNuiSession& session, OVERLAPPED& ov, UINT& transferred, DWORD timeoutMs = kControlIoTimeoutMs) {
    const DWORD wait = WaitForSingleObject(ov.hEvent, timeoutMs);
    if (wait == WAIT_OBJECT_0) {
        if (WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)) return S_OK;
        return HrFromLastError();
    }
    if (wait == WAIT_TIMEOUT) {
        // Cancel only this I/O. Do not ResetPipe/FlushPipe here: MI_00 and the
        // UAC capture interface belong to the same 02BB composite device.
        CancelIoEx(session.file, &ov);
        WaitForSingleObject(ov.hEvent, 250);
        UINT ignored = 0;
        WinUsb::Get().GetOverlappedResult(session.usb, &ov, &ignored, FALSE);
        return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    return HrFromLastError();
}

HRESULT BulkWriteExact(PhysicalNuiSession& session, UCHAR endpoint, const void* data, UINT bytes) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return HrFromLastError();
    OVERLAPPED ov{};
    ov.hEvent = event;
    UINT transferred = 0;
    BOOL ok = WinUsb::Get().WritePipe(session.usb, endpoint,
        reinterpret_cast<PUCHAR>(const_cast<void*>(data)), bytes, nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        if (error == ERROR_IO_PENDING) hr = Wait1473Overlapped(session, ov, transferred);
        else hr = HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)
            ? S_OK : HrFromLastError();
    }
    CloseHandle(event);
    if (FAILED(hr)) return hr;
    return transferred == bytes ? S_OK : HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
}

HRESULT BulkRead1473(PhysicalNuiSession& session, void* data, UINT bytes, UINT& transferred, DWORD timeoutMs = kControlIoTimeoutMs) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return HrFromLastError();
    OVERLAPPED ov{};
    ov.hEvent = event;
    transferred = 0;
    BOOL ok = WinUsb::Get().ReadPipe(session.usb, session.controlInEndpoint,
        reinterpret_cast<PUCHAR>(data), bytes, nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        if (error == ERROR_IO_PENDING) hr = Wait1473Overlapped(session, ov, transferred, timeoutMs);
        else hr = HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)
            ? S_OK : HrFromLastError();
    }
    CloseHandle(event);
    return hr;
}

HRESULT ReadAltAck(PhysicalNuiSession& session, uint32_t expectedTag, DWORD timeoutMs = kControlIoTimeoutMs) {
    std::array<UCHAR, 512> buffer{};
    UINT transferred = 0;
    const HRESULT readHr = BulkRead1473(
        session, buffer.data(), static_cast<UINT>(buffer.size()), transferred, timeoutMs);
    if (FAILED(readHr)) return readHr;
    if (transferred != sizeof(AltMotorReply)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    AltMotorReply ack{};
    std::memcpy(&ack, buffer.data(), sizeof(ack));
    if (ack.magic != Hardware::AudioControl::kReplyMagic || ack.status != 0)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

    // The alternate 1473 camera firmware uses tags as a sequencing hint, but
    // the device protocol does not require rejecting a reply
    // solely because its tag differs. After a reset/re-enumeration a valid ACK may carry a stale tag. Treat
    // magic+status as authoritative. A failed transaction gets one bounded
    // recovery attempt, then the physical session is discarded.
    (void)expectedTag;
    return S_OK;
}

HRESULT SendAltCommandOnce(PhysicalNuiSession& session, uint32_t command, int32_t arg2) {
    const uint32_t tag = session.nextTag++;
    AltMotorCommand request{};
    request.magic = Hardware::AudioControl::kCommandMagic;
    request.tag = tag;
    request.arg1 = 0;
    request.command = command;
    request.arg2 = static_cast<uint32_t>(arg2);
    HRESULT hr = BulkWriteExact(session, session.controlOutEndpoint, &request, sizeof(request));
    if (FAILED(hr)) return hr;
    return ReadAltAck(session, tag);
}

HRESULT SendAltCommand(PhysicalNuiSession& session, uint32_t command, int32_t arg2) {
    return SendAltCommandOnce(session, command, arg2);
}

// Keep recovery local to MI_00 because MI_02 may already be carrying the
// active Windows USB-Audio stream. A fresh MI_00 handle is the recovery
// boundary; healthy composite interfaces are never reset or flushed.

void Recover1473ControlAfterFailure(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473 ||
        !session.controlPipesReady) return;
    auto& api = WinUsb::Get();
    // Error-only recovery. Never run this during a healthy open: MI_02 may be
    // streaming through the same 02BB composite. Clearing only MI_00 here gives
    // a stalled bulk endpoint one chance to recover before the common fresh-
    // handle retry, without any PnP restart/re-enumeration.
    (void)api.AbortPipe(session.usb, session.controlInEndpoint);
    (void)api.AbortPipe(session.usb, session.controlOutEndpoint);
    (void)api.ResetPipe(session.usb, session.controlInEndpoint);
    (void)api.ResetPipe(session.usb, session.controlOutEndpoint);
    (void)api.FlushPipe(session.usb, session.controlInEndpoint);
}

HRESULT Prepare1473Control(PhysicalNuiSession& session) {
    if (session.kind != PhysicalTransportKind::AudioControl1473) return S_OK;
    if (session.prepared) return S_OK;
    if (!session.controlPipesReady && !Discover1473ControlPipes(session))
        return HrFromLastError();

    // The alternate motor/LED protocol is carried by MI_00 after UAC firmware
    // boot. A fresh handle starts at tag 0 and is primed with the solid-green
    // command before the first motor transaction; some 1473 controllers do not
    // accept 0x803B reliably before that initialization completes.
    session.nextTag = 0;
    const HRESULT hr = SendAltCommandOnce(
        session, Hardware::AudioControl::kLedCommand, 3);
    if (SUCCEEDED(hr)) session.prepared = true;
    return hr;
}

HRESULT Prepare1414Control(PhysicalNuiSession&) {
    return S_OK;
}

void Recover1414ControlAfterFailure(PhysicalNuiSession&) {
}

HRESULT ReadStatus1414(PhysicalNuiSession& session, Reply& reply) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0xC0;
    packet.Request = 0x32;
    packet.Length = 10;
    UCHAR buffer[10]{};
    UINT transferred = 0;
    if (!WinUsb::Get().ControlTransfer(session.usb, packet, buffer, sizeof(buffer), &transferred, nullptr) ||
        transferred != sizeof(buffer)) return HrFromLastError();

    reply.accelX = static_cast<short>((buffer[2] << 8) | buffer[3]);
    reply.accelY = static_cast<short>((buffer[4] << 8) | buffer[5]);
    reply.accelZ = static_cast<short>((buffer[6] << 8) | buffer[7]);
    reply.tiltTenths = static_cast<signed char>(buffer[8]) * 5;
    reply.state = buffer[9];
    return S_OK;
}

HRESULT ReadStatus1473(PhysicalNuiSession& session, Reply& reply) {
    const uint32_t tag = session.nextTag++;
    AltMotorCommand request{};
    request.magic = Hardware::AudioControl::kCommandMagic;
    request.tag = tag;
    request.arg1 = Hardware::AudioControl::kStatusReplyBytes;
    request.command = Hardware::AudioControl::kStatusCommand;

    HRESULT hr = BulkWriteExact(session, session.controlOutEndpoint, &request, 16);
    if (FAILED(hr)) return hr;

    // Be tolerant of one stale short reply left by a timed-out earlier
    // transaction, but keep the normal protocol fully synchronized: this
    // command consumes both its 104-byte payload and its trailing 12-byte ACK.
    std::array<UCHAR, 256> buffer{};
    for (int readAttempt = 0; readAttempt < 4; ++readAttempt) {
        UINT transferred = 0;
        hr = BulkRead1473(session, buffer.data(), static_cast<UINT>(buffer.size()), transferred);
        if (FAILED(hr)) return hr;

        if (transferred == sizeof(AltMotorReply)) {
            AltMotorReply ack{};
            std::memcpy(&ack, buffer.data(), sizeof(ack));
            if (ack.magic != Hardware::AudioControl::kReplyMagic || ack.status != 0)
                return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
            continue;
        }
        if (transferred != Hardware::AudioControl::kStatusReplyBytes)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        int32_t values[4]{};
        std::memcpy(values, buffer.data() + 16, sizeof(values));
        reply.accelX = static_cast<short>(values[0]);
        reply.accelY = static_cast<short>(values[1]);
        reply.accelZ = static_cast<short>(values[2]);
        reply.tiltTenths = values[3] * 10;
        reply.state = 0;

        // The status transaction is 104-byte payload followed by a 12-byte ACK.
        // Consume both parts so MI_00 is clean before the next LED/Tilt/status
        // command. A valid payload is authoritative even when the trailing ACK
        // is delayed; the next fresh transaction can still recover cleanly.
        const HRESULT ackHr = ReadAltAck(session, tag, 1200);
        if (FAILED(ackHr) &&
            HRESULT_CODE(ackHr) != ERROR_TIMEOUT &&
            HRESULT_CODE(ackHr) != ERROR_SEM_TIMEOUT) {
            return ackHr;
        }
        return S_OK;
    }
    return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
}

HRESULT IssueTilt1414(PhysicalNuiSession& session, LONG degrees) {
    // Connection detail only: classic motor control encodes the same logical
    // angle in half-degree units through request 0x31.
    const SHORT halfDegrees = static_cast<SHORT>(degrees * 2);
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x31;
    packet.Value = static_cast<USHORT>(halfDegrees);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(
        session.usb, packet, nullptr, 0, &transferred, nullptr) ? S_OK : HrFromLastError();
}

HRESULT IssueTilt1473(PhysicalNuiSession& session, LONG degrees) {
    if (!session.controlPipesReady && !Discover1473ControlPipes(session))
        return HrFromLastError();

    const uint32_t tag = session.nextTag++;
    AltMotorCommand request{};
    request.magic = Hardware::AudioControl::kCommandMagic;
    request.tag = tag;
    request.arg1 = 0;
    request.command = Hardware::AudioControl::kTiltCommand;
    request.arg2 = static_cast<uint32_t>(static_cast<int32_t>(degrees));

    const HRESULT writeHr = BulkWriteExact(
        session, session.controlOutEndpoint, &request, sizeof(request));
    if (FAILED(writeHr)) return writeHr;

    // 1473 carries motor control on the audio-controller MI_00 bulk pair.
    // Complete the command transaction immediately: the reference firmware
    // returns a 12-byte ACK after 0x803B. Leaving it queued can stall or
    // interleave later controller work and make the mechanism move in bursts.
    // A late/missing ACK must never cause 0x803B to be resent: the successful
    // 20-byte OUT transfer is the motor command commit point.
    const HRESULT ackHr = ReadAltAck(session, tag, 2000);
    if (FAILED(ackHr) &&
        HRESULT_CODE(ackHr) != ERROR_TIMEOUT &&
        HRESULT_CODE(ackHr) != ERROR_SEM_TIMEOUT) {
        return ackHr;
    }
    return S_OK;
}

HRESULT SetLed1414(PhysicalNuiSession& session, LONG value) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x06;
    packet.Value = static_cast<USHORT>(value);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(session.usb, packet, nullptr, 0, &transferred, nullptr)
        ? S_OK : HrFromLastError();
}

HRESULT SetLed1473(PhysicalNuiSession& session, LONG value) {
    // Normalize the common LED contract onto the subset exposed by the 1473
    // alternate controller. Yellow degrades to green and compound blink to the
    // closest supported state, while success/failure semantics remain common.
    int32_t alt = 3;
    if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Off)) alt = 1;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkGreen)) alt = 2;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Red)) alt = 4;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Green) ||
             value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Yellow)) alt = 3;

    if (!session.controlPipesReady && !Discover1473ControlPipes(session))
        return HrFromLastError();
    const HRESULT hr = SendAltCommand(session, Hardware::AudioControl::kLedCommand, alt);
    if (SUCCEEDED(hr)) session.prepared = true;
    return hr;
}

struct PhysicalControlOps {
    HRESULT (*prepare)(PhysicalNuiSession&);
    HRESULT (*readStatus)(PhysicalNuiSession&, Reply&);
    HRESULT (*issueTilt)(PhysicalNuiSession&, LONG);
    HRESULT (*setLed)(PhysicalNuiSession&, LONG);
    void (*recoverAfterFailure)(PhysicalNuiSession&);
};

const PhysicalControlOps* ControlOpsFor(PhysicalTransportKind kind) {
    static const PhysicalControlOps k1414{Prepare1414Control, ReadStatus1414, IssueTilt1414, SetLed1414, Recover1414ControlAfterFailure};
    static const PhysicalControlOps k1473{Prepare1473Control, ReadStatus1473, IssueTilt1473, SetLed1473, Recover1473ControlAfterFailure};
    switch (kind) {
        case PhysicalTransportKind::Classic1414: return &k1414;
        case PhysicalTransportKind::AudioControl1473: return &k1473;
        default: return nullptr;
    }
}

HRESULT ReadPhysicalStatus(PhysicalNuiSession& session, Reply& reply) {
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;
    const HRESULT hr = ops->readStatus(session, reply);
    if (SUCCEEDED(hr)) {
        session.lastTiltValid = true;
        session.lastTiltTenths = reply.tiltTenths;
    }
    return hr;
}

HRESULT WaitForTiltTarget1414(PhysicalNuiSession& session, LONG degrees, Reply& observed) {
    constexpr LONG kToleranceTenths = 15;
    constexpr DWORD kInitialSettleMs = 120;
    constexpr DWORD kPollMs = 100;
    constexpr int kPollCount = 40;
    const LONG targetTenths = degrees * 10;

    Sleep(kInitialSettleMs);
    HRESULT lastHr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    bool receivedStatus = false;
    LONG firstTenths = 0;
    LONG lastTenths = 0;
    bool firstValid = false;

    for (int attempt = 0; attempt < kPollCount; ++attempt) {
        Reply latest{};
        lastHr = ReadPhysicalStatus(session, latest);
        if (SUCCEEDED(lastHr)) {
            receivedStatus = true;
            observed = latest;
            lastTenths = latest.tiltTenths;
            if (!firstValid) {
                firstTenths = lastTenths;
                firstValid = true;
            }
            if (std::abs(lastTenths - targetTenths) <= kToleranceTenths) {
                observed.state |= Kinect360RemoldControl::kStateTiltVerified;
                return S_OK;
            }
        } else if (HRESULT_CODE(lastHr) != ERROR_TIMEOUT) {
            return lastHr;
        }
        Sleep(kPollMs);
    }

    if (!receivedStatus) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    const bool moved = firstValid && std::abs(lastTenths - firstTenths) >= 5;
    return HRESULT_FROM_WIN32(moved ? ERROR_TIMEOUT : ERROR_IO_DEVICE);
}

// 1473 travel budget. MI_00 must stay silent for the whole mechanical travel:
// any status/LED transaction while the controller is moving makes the motor
// stop and restart. The budget grows with the distance from the last measured
// angle; an unknown start assumes the full range.
DWORD Tilt1473QuietMs(const PhysicalNuiSession& session, LONG degrees) {
    constexpr DWORD kMinimumQuietMs = 1500;
    constexpr DWORD kSettleMarginMs = 600;
    constexpr DWORD kTravelMsPerDegree = 85;
    const LONG fullRange = Policy::kTiltMaxDegrees - Policy::kTiltMinDegrees;
    const LONG distance = session.lastTiltValid
        ? (std::abs(degrees * 10 - session.lastTiltTenths) + 9) / 10 : fullRange;
    return (std::max)(kMinimumQuietMs, kSettleMarginMs + static_cast<DWORD>(distance) * kTravelMsPerDegree);
}

HRESULT VerifyTiltTarget1473(PhysicalNuiSession& session, LONG degrees, DWORD quietMs, Reply& observed) {
    constexpr LONG kToleranceTenths = 15;
    const LONG targetTenths = degrees * 10;

    // 0x803B and its immediate ACK are complete; keep MI_00 silent for the
    // whole travel, then read the angle exactly once.
    Sleep(quietMs);

    Reply latest{};
    if (SUCCEEDED(ReadPhysicalStatus(session, latest))) {
        observed = latest;
        if (std::abs(latest.tiltTenths - targetTenths) <= kToleranceTenths)
            observed.state |= Kinect360RemoldControl::kStateTiltVerified;
        return S_OK;
    }

    // The complete 20-byte OUT transfer is the command commit point. A missing
    // status reply is not grounds to resend 0x803B, because a resend restarts
    // physical travel. Report the accepted target with verified=0 instead.
    observed = {};
    observed.transport = Transport::PhysicalMotor;
    observed.tiltTenths = targetTenths;
    return S_OK;
}

HRESULT SetPhysicalTiltDegrees(PhysicalNuiSession& session, LONG requestedDegrees, Reply& observed) {
    const LONG degrees = std::clamp<LONG>(requestedDegrees, Policy::kTiltMinDegrees, Policy::kTiltMaxDegrees);
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;

    if (session.kind == PhysicalTransportKind::AudioControl1473) {
        // 0x803B must be the first MI_00 transaction after preparation. Do not
        // pre-read status: a late status/ACK can block or reorder the motor
        // command on 1473. Verification happens only after uninterrupted travel.
        const DWORD quietMs = Tilt1473QuietMs(session, degrees);
        const HRESULT issueHr = ops->issueTilt(session, degrees);
        if (FAILED(issueHr)) return issueHr;
        return VerifyTiltTarget1473(session, degrees, quietMs, observed);
    }

    const HRESULT issueHr = ops->issueTilt(session, degrees);
    if (FAILED(issueHr)) return issueHr;
    return WaitForTiltTarget1414(session, degrees, observed);
}

bool IsValidLedMode(LONG value) {
    return value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Off) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Green) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Red) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Yellow) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkGreen) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkYellowRed);
}

HRESULT SetPhysicalLed(PhysicalNuiSession& session, LONG value) {
    if (!IsValidLedMode(value)) return E_INVALIDARG;
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;
    return ops->setLed(session, value);
}

struct TiltInFlight {
    explicit TiltInFlight(std::atomic<bool>& inFlight) : flag(inFlight) { flag.store(true, std::memory_order_release); }
    ~TiltInFlight() { flag.store(false, std::memory_order_release); }
    TiltInFlight(const TiltInFlight&) = delete;
    TiltInFlight& operator=(const TiltInFlight&) = delete;
    std::atomic<bool>& flag;
};

HRESULT TryPhysicalNuiCommand(const Request& request, Reply& reply) {
    const size_t idLen = strnlen_s(request.deviceId, Kinect360RemoldControl::kDeviceIdBytes);
    const std::string targetId(request.deviceId, idLen);
    const auto context = PhysicalContextFor(targetId);
    if (request.command == Command::Status && context->tiltInFlight.load(std::memory_order_acquire))
        return HRESULT_FROM_WIN32(ERROR_BUSY);
    std::optional<TiltInFlight> tiltGuard;
    if (request.command == Command::Tilt) tiltGuard.emplace(context->tiltInFlight);
    std::lock_guard<std::mutex> physicalGuard(context->mutex);
    PhysicalNuiSession& session = context->session;

    auto execute = [&](Reply& out) -> HRESULT {
        const HRESULT openHr = EnsurePhysicalNui(session, targetId);
        if (FAILED(openHr)) return openHr;

        // Different logical callers can address the same physical Kinect through
        // an explicit ID or the automatic selector. Serialize the actual USB
        // control interface by resolved physical ID so status/LED traffic cannot
        // cut into a 1473 motor transaction.
        const auto ioMutex = PhysicalIoMutexFor(session.deviceId);
        std::lock_guard<std::mutex> ioGuard(*ioMutex);

        out = {};
        out.transport = Transport::PhysicalMotor;
        if (request.command == Command::Ping) return S_OK;
        const PhysicalControlOps* ops = ControlOpsFor(session.kind);
        if (!ops) return E_HANDLE;
        if (request.command == Command::PrepareCamera) return ops->prepare(session);
        if (request.command == Command::Status) {
            const HRESULT prepareHr = ops->prepare(session);
            if (FAILED(prepareHr)) return prepareHr;
            return ReadPhysicalStatus(session, out);
        }
        if (request.command == Command::Tilt) {
            const HRESULT prepareHr = ops->prepare(session);
            if (FAILED(prepareHr)) return prepareHr;
            const LONG degrees = std::clamp<LONG>(request.value, Policy::kTiltMinDegrees, Policy::kTiltMaxDegrees);
            return SetPhysicalTiltDegrees(session, degrees, out);
        }
        if (request.command == Command::Led) return SetPhysicalLed(session, request.value);
        return E_INVALIDARG;
    };

    HRESULT hr = execute(reply);
    if (SUCCEEDED(hr)) return hr;

    if (const PhysicalControlOps* ops = ControlOpsFor(session.kind); ops && ops->recoverAfterFailure)
        ops->recoverAfterFailure(session);
    session.Close();
    Sleep(50);
    hr = execute(reply);
    if (FAILED(hr)) session.Close();
    return hr;
}

HRESULT DispatchControlRequest(const Request& request, Reply& reply) {
    reply = {};
    if (request.magic != Kinect360RemoldControl::kMagic ||
        request.version != Kinect360RemoldControl::kVersion) {
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }

    switch (request.command) {
        case Command::Ping:
            // An empty-device Ping is the broker liveness probe used by the CLI.
            // A device-scoped Ping is the non-invasive physical-capability probe
            // used by CameraBridge/Studio and must resolve the requested Kinect,
            // returning PhysicalMotor on success. This matches the Linux broker
            // and keeps one model-neutral control contract for 1414 and 1473.
            if (request.deviceId[0] == '\0') return S_OK;
            return TryPhysicalNuiCommand(request, reply);
        case Command::Status:
        case Command::Tilt:
        case Command::Led:
        case Command::PrepareCamera:
            return TryPhysicalNuiCommand(request, reply);
        default:
            return E_INVALIDARG;
    }
}

void ServeControlClient(HANDLE pipe) {
    Request request{};
    DWORD read = 0;
    if (ReadFile(pipe, &request, sizeof(request), &read, nullptr) && read == sizeof(request)) {
        Reply reply{};
        const HRESULT hr = DispatchControlRequest(request, reply);
        reply.result = static_cast<int32_t>(hr);
        DWORD written = 0;
        (void)WriteFile(pipe, &reply, sizeof(reply), &written, nullptr);
        (void)FlushFileBuffers(pipe);
    }
    (void)DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
}

// Every connection is served on its own thread, like the Linux broker. A
// 1473 Tilt holds its device for several seconds of uninterrupted travel;
// Status, Ping and other Kinects must not wait behind it.
void ControlServerLoop(std::atomic<bool>* active) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)",
            SDDL_REVISION_1,
            &descriptor,
            nullptr)) {
        security.lpSecurityDescriptor = descriptor;
    }

    struct ClientThread {
        std::shared_ptr<std::atomic<bool>> done;
        std::thread thread;
    };
    std::vector<ClientThread> clients;
    auto reap = [&clients](bool all) {
        for (auto it = clients.begin(); it != clients.end();) {
            if (all || it->done->load(std::memory_order_acquire)) {
                if (it->thread.joinable()) it->thread.join();
                it = clients.erase(it);
            } else {
                ++it;
            }
        }
    };

    while (active->load() && gRun.load()) {
        HANDLE pipe = CreateNamedPipeW(
            Kinect360RemoldControl::kPipeName,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            sizeof(Reply),
            sizeof(Request),
            1000,
            security.lpSecurityDescriptor ? &security : nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(250);
            continue;
        }

        BOOL connected = ConnectNamedPipe(pipe, nullptr);
        if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (!connected) {
            CloseHandle(pipe);
            continue;
        }
        reap(false);
        auto done = std::make_shared<std::atomic<bool>>(false);
        try {
            clients.push_back(ClientThread{done, std::thread([pipe, done] {
                ServeControlClient(pipe);
                done->store(true, std::memory_order_release);
            })});
        } catch (const std::system_error&) {
            ServeControlClient(pipe);
        }
    }
    reap(true);
    if (descriptor) LocalFree(descriptor);
}

constexpr wchar_t kSdkPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldSdk";

std::filesystem::path DeviceManifestPath() {
    wchar_t root[1024]{};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", root, static_cast<DWORD>(std::size(root)));
    std::filesystem::path base = (n > 0 && n < std::size(root)) ? std::filesystem::path(root) : std::filesystem::path(L"C:\\ProgramData");
    return base / L"Kinect360Remold" / L"devices.tsv";
}

std::vector<std::string> ReadDeviceRows() {
    std::vector<std::string> rows;
    std::ifstream in(DeviceManifestPath(), std::ios::binary);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        rows.push_back(std::move(line));
    }
    return rows;
}

std::string FirstField(const std::string& row) {
    const size_t tab = row.find('\t');
    return tab == std::string::npos ? row : row.substr(0, tab);
}

std::string DispatchSdk(const std::string& raw) {
    std::string command = raw;
    while (!command.empty() && (command.back() == '\r' || command.back() == '\n' || command.back() == ' ')) command.pop_back();
    while (!command.empty() && command.front() == ' ') command.erase(command.begin());
    const auto rows = ReadDeviceRows();
    if (command == "LIST") {
        std::ostringstream out;
        for (const auto& row : rows) out << row << '\n';
        return out.str();
    }
    if (command.rfind("GET ", 0) == 0) {
        const std::string id = command.substr(4);
        for (const auto& row : rows) if (FirstField(row) == id) return row + "\n";
        return "ERR NOT_FOUND\n";
    }
    if (command.rfind("INDEX ", 0) == 0) {
        char* end = nullptr;
        const long index = std::strtol(command.c_str() + 6, &end, 10);
        if (end && *end == '\0' && index >= 0 && static_cast<size_t>(index) < rows.size()) return rows[static_cast<size_t>(index)] + "\n";
        return "ERR NOT_FOUND\n";
    }
    return "ERR BAD_COMMAND\n";
}

void SdkServerLoop(std::atomic<bool>* active) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES security{sizeof(security)};
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1,
            &descriptor, nullptr)) security.lpSecurityDescriptor = descriptor;
    while (active->load() && gRun.load()) {
        HANDLE pipe = CreateNamedPipeW(kSdkPipeName, PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            8, 16384, 4096, 1000, security.lpSecurityDescriptor ? &security : nullptr);
        if (pipe == INVALID_HANDLE_VALUE) { Sleep(250); continue; }
        BOOL connected = ConnectNamedPipe(pipe, nullptr);
        if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (connected) {
            char request[1024]{}; DWORD read = 0;
            if (ReadFile(pipe, request, sizeof(request)-1, &read, nullptr) && read > 0) {
                request[read] = 0;
                const std::string response = DispatchSdk(std::string(request, read));
                DWORD written=0; (void)WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()), &written, nullptr);
                (void)FlushFileBuffers(pipe);
            }
            (void)DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
    if (descriptor) LocalFree(descriptor);
}

void WakeSdkServer() {
    if (!WaitNamedPipeW(kSdkPipeName, 100)) return;
    HANDLE pipe = CreateFileW(kSdkPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    const char ping[] = "LIST\n"; DWORD done=0;
    (void)WriteFile(pipe, ping, static_cast<DWORD>(sizeof(ping)-1), &done, nullptr);
    char reply[64]{}; (void)ReadFile(pipe, reply, sizeof(reply), &done, nullptr);
    CloseHandle(pipe);
}

void WakeControlServer() {
    if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 100)) return;
    HANDLE pipe = CreateFileW(
        Kinect360RemoldControl::kPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    Request request{};
    request.command = Command::Ping;
    DWORD written = 0;
    (void)WriteFile(pipe, &request, sizeof(request), &written, nullptr);
    Reply reply{};
    DWORD read = 0;
    (void)ReadFile(pipe, &reply, sizeof(reply), &read, nullptr);
    CloseHandle(pipe);
}

int RunHost() {
    std::atomic<bool> brokerRun{true};
    std::thread controlThread(ControlServerLoop, &brokerRun);
    std::thread sdkThread(SdkServerLoop, &brokerRun);
    while (gRun.load()) Sleep(250);
    brokerRun.store(false);
    WakeControlServer();
    WakeSdkServer();
    if (controlThread.joinable()) controlThread.join();
    if (sdkThread.joinable()) sdkThread.join();
    ClosePhysicalContexts();
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
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gServiceHandle = RegisterServiceCtrlHandlerW(L"Kinect360RemoldBroker", ServiceControl);
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

    (void)RunHost();

    gServiceStatus.dwCurrentState = SERVICE_STOPPED;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && _wcsicmp(argv[1], L"--console") == 0) {
        gRun.store(true);
        return RunHost();
    }

    SERVICE_TABLE_ENTRYW table[] = {
        { const_cast<LPWSTR>(L"Kinect360RemoldBroker"), ServiceMain },
        { nullptr, nullptr }
    };
    if (StartServiceCtrlDispatcherW(table)) return 0;

    const DWORD error = GetLastError();
    if (error == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
        gRun.store(true);
        return RunHost();
    }
    return static_cast<int>(error);
}
