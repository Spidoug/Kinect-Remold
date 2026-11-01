#pragma once

#include <cstdint>

// Physical Kinect Xbox 360 USB profile shared by the runtime services.
//
//   1414: camera 045E:02AE bcdDevice 0x010B; motor/LED/accelerometer on the
//         dedicated 045E:02B0 function (classic USB control requests).
//   1473: camera 045E:02AE with any other bcdDevice; 045E:02C2 is only the
//         parent hub and is never claimed or reset. Motor/LED/accelerometer use
//         045E:02BB/02C3 MI_00 after UAC firmware 01.02.709.00 launches.
//   1517: camera 045E:02BF, dedicated 045E:02C2 motor/control function and
//         factory 045E:02BE Kinect for Windows USB-audio runtime.
//
// The model is always resolved from the camera identity. 02C2 is ambiguous
// between a 1473 hub and the dedicated 1517 motor function, and is therefore
// never used by itself to classify hardware.
namespace remold::hardware {

inline constexpr uint16_t kMicrosoftVid = 0x045e;
inline constexpr uint16_t kMotor1414Pid = 0x02b0;
inline constexpr uint16_t kMotor1517Pid = 0x02c2;
inline constexpr uint16_t kCameraXboxPid = 0x02ae;
inline constexpr uint16_t kCamera1517Pid = 0x02bf;
inline constexpr uint16_t kAudioBootPid = 0x02ad;
inline constexpr uint16_t kAudio1517Pid = 0x02be;
inline constexpr uint16_t kAudioRuntimePids[] = {0x02bb, 0x02c3};
inline constexpr uint16_t kCamera1414BcdDevice = 0x010b;

enum class Model : uint8_t {
  Unknown = 0,
  Xbox1414 = 1,
  Xbox1473 = 2,
  Windows1517 = 3,
};

inline constexpr bool is_audio_uac_pid(uint16_t pid) noexcept {
  if (pid == kAudio1517Pid) return true;
  for (const auto candidate : kAudioRuntimePids) {
    if (candidate == pid) return true;
  }
  return false;
}

inline constexpr bool is_audio_runtime_pid(uint16_t pid) noexcept {
  for (const auto candidate : kAudioRuntimePids) {
    if (candidate == pid) return true;
  }
  return false;
}

inline constexpr bool is_camera_pid(uint16_t pid) noexcept { return pid == kCameraXboxPid || pid == kCamera1517Pid; }

inline constexpr Model model_from_camera(uint16_t pid, uint16_t bcd_device) noexcept {
  if (pid == kCamera1517Pid) return Model::Windows1517;
  if (pid != kCameraXboxPid) return Model::Unknown;
  return bcd_device == kCamera1414BcdDevice ? Model::Xbox1414 : Model::Xbox1473;
}

inline constexpr const char* model_name(Model model) noexcept {
  return model == Model::Xbox1414 ? "1414" : (model == Model::Xbox1473 ? "1473" : (model == Model::Windows1517 ? "1517" : "unknown"));
}

// Motion sampling interface. The camera service owns periodic status polling
// while a frame consumer is active and attaches the latest sample to every
// frame. Both hardware models use the same sampling and validity periods.
struct MotionPolicy {
  uint32_t poll_period_ms;
  uint32_t stale_after_ms;
};

inline constexpr MotionPolicy motion_policy(Model) noexcept {
  return MotionPolicy{25u, 250u};
}

// Product tilt range, identical to TiltMinDegrees/TiltMaxDegrees in the
// Windows Product.psd1 policy.
inline constexpr int kTiltMinDegrees = -27;
inline constexpr int kTiltMaxDegrees = 27;

static_assert(model_from_camera(kCameraXboxPid, kCamera1414BcdDevice) == Model::Xbox1414);
static_assert(model_from_camera(kCameraXboxPid, 0x0205) == Model::Xbox1473);
static_assert(model_from_camera(kCamera1517Pid, 0x0100) == Model::Windows1517);
static_assert(motion_policy(Model::Xbox1414).poll_period_ms == 25u);
static_assert(motion_policy(Model::Xbox1473).poll_period_ms == 25u);
static_assert(motion_policy(Model::Xbox1414).stale_after_ms == 250u);
static_assert(motion_policy(Model::Xbox1473).stale_after_ms == 250u);

}  // namespace remold::hardware
