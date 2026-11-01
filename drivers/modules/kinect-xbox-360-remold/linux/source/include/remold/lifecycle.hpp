#pragma once

#include <cstdint>

// Cross-platform lifecycle policy for the Linux runtime. These timings mirror
// the Windows services so discovery, reconnect and local IPC have the same
// externally visible cadence without depending on machine-specific paths.
namespace remold::lifecycle {
inline constexpr int kDiscoveryPollMs = 200;
inline constexpr int kRetryMs = 500;
inline constexpr int kPostFirmwareDelayMs = 1500;
inline constexpr int kUsbIoTimeoutMs = 3000;
inline constexpr int kControlIoTimeoutMs = 750;
inline constexpr int kClientIoTimeoutMs = 3000;
inline constexpr int kSdkClientIoTimeoutMs = 1000;
inline constexpr int kLocalClientIoTimeoutMs = 2000;
inline constexpr int kReconnectGraceSeconds = 3;
inline constexpr int kStartupOpenAttempts = 20;
inline constexpr int kStartupOpenRetryMs = 250;
inline constexpr int kServiceRetryMs = 250;
}
