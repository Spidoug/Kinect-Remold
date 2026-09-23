#pragma once

#include <cstdint>

// Physical Kinect Xbox 360 USB profile shared by every Linux Remold service.
// Its model and motion rules mirror the Windows runtime one-to-one
// (drivers/windows/source/components/device/shared/Kinect360RemoldHardwareProfile.h).
//
//   1414: camera 045E:02AE bcdDevice 0x010B; motor/LED/accelerometer on the
//         dedicated 045E:02B0 function (classic USB control requests).
//   1473: camera 045E:02AE with any other bcdDevice; 045E:02C2 is only the
//         parent hub and is never claimed or reset. Motor/LED/accelerometer use
//         045E:02BB/02C3 MI_00 after UAC firmware 01.02.709.00 launches.
//
// Both models expose 02BB/02C3 after the firmware transition, so the model is
// always resolved from the camera identity, never from the runtime audio PID.
namespace remold::hardware {

inline constexpr uint16_t kMicrosoftVid = 0x045e;
inline constexpr uint16_t kMotor1414Pid = 0x02b0;
inline constexpr uint16_t kCameraPid = 0x02ae;
inline constexpr uint16_t kAudioBootPid = 0x02ad;
inline constexpr uint16_t kAudioRuntimePids[] = {0x02bb, 0x02c3};
inline constexpr uint16_t kCamera1414BcdDevice = 0x010b;

enum class Model : uint8_t {
  Unknown = 0,
  Xbox1414 = 1,
  Xbox1473 = 2,
};

inline constexpr bool is_audio_runtime_pid(uint16_t pid) noexcept {
  for (const auto candidate : kAudioRuntimePids) {
    if (candidate == pid) return true;
  }
  return false;
}

inline constexpr Model model_from_camera(uint16_t pid, uint16_t bcd_device) noexcept {
  if (pid != kCameraPid) return Model::Unknown;
  return bcd_device == kCamera1414BcdDevice ? Model::Xbox1414 : Model::Xbox1473;
}

inline constexpr const char* model_name(Model model) noexcept {
  return model == Model::Xbox1414 ? "1414" : (model == Model::Xbox1473 ? "1473" : "unknown");
}

// Motion sampling contract. The camera service is the only periodic status
// owner; it polls while a frame consumer is active and attaches the latest
// sample to every frame. 1414 status is a cheap 02B0 control request. 1473
// status shares MI_00 with LED and tilt, so it is polled conservatively. A
// sample stays attached until it is older than stale_after_ms.
struct MotionPolicy {
  uint32_t poll_period_ms;
  uint32_t stale_after_ms;
};

inline constexpr MotionPolicy motion_policy(Model model) noexcept {
  return model == Model::Xbox1414 ? MotionPolicy{25u, 250u} : MotionPolicy{500u, 1500u};
}

// Product tilt range, identical to TiltMinDegrees/TiltMaxDegrees in the
// Windows Product.psd1 policy.
inline constexpr int kTiltMinDegrees = -27;
inline constexpr int kTiltMaxDegrees = 27;

static_assert(model_from_camera(kCameraPid, kCamera1414BcdDevice) == Model::Xbox1414);
static_assert(model_from_camera(kCameraPid, 0x0205) == Model::Xbox1473);
static_assert(motion_policy(Model::Xbox1414).poll_period_ms == 25u);
static_assert(motion_policy(Model::Xbox1473).poll_period_ms == 500u);

}  // namespace remold::hardware
