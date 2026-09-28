#pragma once

#include <cstdint>

namespace Kinect360RemoldAudioControl {
inline constexpr std::uint32_t kMagic = 0x43414D52u;
inline constexpr std::uint32_t kVersion = 1;

enum class Command : std::uint32_t {
    Ping = 0,
    Get = 1,
    SetVolume = 2,
    SetMute = 3,
};

#pragma pack(push, 1)
struct Request {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    Command command = Command::Ping;
    std::int32_t value = 0;
};

struct Reply {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    std::int32_t result = 0;
    std::int32_t volume = 100;
    std::int32_t muted = 0;
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16, "Audio-control request ABI");
static_assert(sizeof(Reply) == 20, "Audio-control reply ABI");
}  // namespace Kinect360RemoldAudioControl
