#pragma once
#include <cstdint>
namespace Kinect360RemoldAudioControl {
constexpr uint32_t kMagic = 0x43414D52u; // "RMAC"
constexpr uint32_t kVersion = 1;
enum class Command : uint32_t { Ping=0, Get=1, SetVolume=2, SetMute=3 };
#pragma pack(push,1)
struct Request { uint32_t magic=kMagic, version=kVersion; Command command=Command::Ping; int32_t value=0; };
struct Reply { uint32_t magic=kMagic, version=kVersion; int32_t result=0; int32_t volume=100; int32_t muted=0; };
#pragma pack(pop)
static_assert(sizeof(Request)==16, "Audio-control request ABI");
static_assert(sizeof(Reply)==20, "Audio-control reply ABI");
} // namespace Kinect360RemoldAudioControl
