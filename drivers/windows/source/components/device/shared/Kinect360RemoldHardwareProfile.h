#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cstddef>
#include <cstdint>

// Physical Kinect Xbox 360 USB profile shared by every Remold user-mode
// transport. Its model and motion rules are mirrored one-to-one by the Linux
// runtime in drivers/linux/source/include/remold/hardware_profile.hpp.
//
//   1414: camera 045E:02AE bcdDevice 0x010B; motor/LED/accelerometer on the
//         dedicated 045E:02B0 function (classic USB control requests).
//   1473: camera 045E:02AE with any other bcdDevice; 045E:02C2 is only the
//         parent hub and stays on the inbox hub driver. Motor/LED/accelerometer
//         use 045E:02BB/02C3&MI_00 after UAC firmware 01.02.709.00 launches.
//
// Both models expose 02BB/02C3 after the firmware transition, so the model is
// always resolved from the camera identity, never from the runtime audio PID.
namespace Kinect360RemoldHardware {

inline constexpr uint16_t kVendorId = 0x045E;
inline constexpr uint16_t kMotorProductIds[] = {0x02B0};
inline constexpr uint16_t kControllerHubProductIds[] = {0x02C2};
inline constexpr uint16_t kCameraProductIds[] = {0x02AE};
inline constexpr uint16_t kAudioProductIds[] = {0x02AD};
inline constexpr uint16_t kCameraProductId = kCameraProductIds[0];
inline constexpr uint16_t kCamera1414BcdDevice = 0x010B;

inline constexpr const wchar_t* kAudioRuntimeControlHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_00", L"USB\\VID_045E&PID_02C3&MI_00"};
inline constexpr const wchar_t* kAudioRuntimeSecurityHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_01", L"USB\\VID_045E&PID_02C3&MI_01"};
inline constexpr const wchar_t* kAudioRuntimeCaptureHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_02", L"USB\\VID_045E&PID_02C3&MI_02"};

enum class Model : uint8_t {
    Unknown = 0,
    Xbox1414 = 1,
    Xbox1473 = 2,
};

inline constexpr Model ModelFromCamera(uint16_t productId, uint16_t bcdDevice) noexcept {
    if (productId != kCameraProductId) return Model::Unknown;
    return bcdDevice == kCamera1414BcdDevice ? Model::Xbox1414 : Model::Xbox1473;
}

inline constexpr const char* ModelName(Model model) noexcept {
    return model == Model::Xbox1414 ? "1414" : (model == Model::Xbox1473 ? "1473" : "unknown");
}

// Motion sampling contract. The camera service is the only periodic status
// owner; it polls while a frame consumer is active and attaches the latest
// sample to every frame. 1414 status is a cheap 02B0 control request. 1473
// status shares MI_00 with LED and tilt, so it is polled conservatively. A
// sample stays attached until it is older than staleAfterMs.
struct MotionPolicy {
    uint32_t pollPeriodMs;
    uint32_t staleAfterMs;
};

inline constexpr MotionPolicy MotionPolicyFor(Model model) noexcept {
    return model == Model::Xbox1414 ? MotionPolicy{25u, 250u} : MotionPolicy{500u, 1500u};
}

// Classic 1414 motor transport.
inline constexpr GUID kNuiTransportGuid =
    {0x71d72413,0xe133,0x42b4,{0xa5,0xce,0x66,0xf4,0xd2,0xe3,0x8d,0xfa}};
// 1473 motor-control path exposed by UAC runtime interface 0 after firmware.
// This is the interface GUID of Microsoft's Kinect Audio Array Control WinUSB
// package, so MI_00 opens whether Windows selected that package or Remold's.
inline constexpr GUID kAudioControlTransportGuid =
    {0xf9dbe212,0xf689,0x4fdf,{0xa7,0x5d,0x53,0x2e,0x95,0x1f,0xbd,0x0a}};
inline constexpr GUID kCameraTransportGuid =
    {0xe05f50e4,0x0674,0x4ecf,{0x9d,0x63,0x15,0x40,0x1b,0x83,0x7e,0x9b}};
// 02AD boot transport only. Keep this separate from UAC MI_00 so AudioBridge
// never mistakes the runtime control interface for a firmware-boot device.
inline constexpr GUID kAudioTransportGuid =
    {0x67965f38,0x6818,0x4a56,{0xb5,0x3e,0x8d,0xf9,0x2f,0x2e,0xeb,0xde}};

namespace Audio {
inline constexpr UCHAR kBootOutEndpoint = 0x01;
inline constexpr UCHAR kBootInEndpoint = 0x81;
inline constexpr uint32_t kBootCommandMagic = 0x06022009u;
inline constexpr uint32_t kBootStatusMagic = 0x0A6FE000u;
inline constexpr uint32_t kBootWriteCommand = 0x03u;
inline constexpr uint32_t kBootLaunchCommand = 0x04u;
inline constexpr uint32_t kFirmwarePageBytes = 16u * 1024u;
inline constexpr uint32_t kFirmwareChunkBytes = 512u;
}

namespace AudioControl {
inline constexpr UCHAR kOutEndpoint = 0x01;
inline constexpr UCHAR kInEndpoint = 0x81;
inline constexpr uint32_t kCommandMagic = 0x06022009u;
inline constexpr uint32_t kReplyMagic = 0x0A6FE000u;
inline constexpr uint32_t kStatusCommand = 0x8032u;
inline constexpr uint32_t kTiltCommand = 0x803Bu;
inline constexpr uint32_t kLedCommand = 0x10u;
inline constexpr uint32_t kStatusReplyBytes = 0x68u;
}

namespace Camera {
inline constexpr UCHAR kVideoInEndpoint = 0x81;
inline constexpr UCHAR kDepthInEndpoint = 0x82;
inline constexpr ULONG kVideoPacketBytes = 1920;
inline constexpr ULONG kDepthPacketBytes = 1760;
// WinUSB batching: eight transfers of 32 packets keep 256 ISO packets
// continuously scheduled. Linux uses libfreenect's 16x16 libusb geometry.
inline constexpr ULONG kIsoPacketsPerTransfer = 32;
inline constexpr ULONG kIsoQueueDepth = 8;
}

} // namespace Kinect360RemoldHardware

static_assert(Kinect360RemoldHardware::ModelFromCamera(0x02AE, 0x010B) == Kinect360RemoldHardware::Model::Xbox1414);
static_assert(Kinect360RemoldHardware::ModelFromCamera(0x02AE, 0x0205) == Kinect360RemoldHardware::Model::Xbox1473);
static_assert(Kinect360RemoldHardware::MotionPolicyFor(Kinect360RemoldHardware::Model::Xbox1414).pollPeriodMs == 25u);
static_assert(Kinect360RemoldHardware::MotionPolicyFor(Kinect360RemoldHardware::Model::Xbox1473).pollPeriodMs == 500u);
