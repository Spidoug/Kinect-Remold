#pragma once

#include <cstddef>
#include <cstdint>

namespace Kinect360RemoldControl {
inline constexpr const char kSocketPath[] = "/run/kinect360-remold/control.sock";
inline constexpr std::uint32_t kMagic = 0x54434D52u;
inline constexpr std::uint32_t kVersion = 1;
inline constexpr std::size_t kDeviceIdBytes = 64;
inline constexpr std::uint32_t kStateTiltVerified = 0x80000000u;

enum class Command : std::uint32_t {
    Ping = 0,
    Status = 1,
    Tilt = 2,
    Led = 3,
    PrepareCamera = 4,
};

enum class Transport : std::uint32_t {
    None = 0,
    PhysicalMotor = 1,
};

enum class LedMode : std::int32_t {
    Off = 0,
    Green = 1,
    Red = 2,
    Yellow = 3,
    BlinkGreen = 4,
    BlinkYellowRed = 6,
};

#pragma pack(push, 1)
struct Request {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    Command command = Command::Ping;
    std::int32_t value = 0;
    char deviceId[kDeviceIdBytes]{};
};

struct Reply {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    std::int32_t result = 0;
    Transport transport = Transport::None;
    std::int32_t accelX = 0;
    std::int32_t accelY = 0;
    std::int32_t accelZ = 0;
    std::int32_t tiltTenths = 0;
    std::uint32_t state = 0;
};
#pragma pack(pop)

static_assert(sizeof(Request) == 80, "Control request ABI");
static_assert(sizeof(Reply) == 36, "Control reply ABI");
}  // namespace Kinect360RemoldControl
