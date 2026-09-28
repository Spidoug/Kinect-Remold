#pragma once

#include <cstdint>

namespace KinectOneRemoldProtocol {

constexpr std::uint32_t kMagic = 0x43534D52u;
constexpr std::uint32_t kFrameMagic = 0x46534D52u;
constexpr std::uint32_t kVersion = 1;

enum class Command : std::uint32_t {
    SubscribeStreams = 1,
    GetDriverSettings = 2,
    SetDriverSettings = 3,
};

enum class StreamMode : std::int32_t {
    Rgb = 0,
    Infrared = 1,
    Depth = 2,
    RgbHighQuality = 3,
};

enum StreamMask : std::uint32_t {
    StreamRgb = 1u,
    StreamInfrared = 2u,
    StreamDepth = 4u,
    StreamRgbHighQuality = 8u,
};

enum Capability : std::uint32_t {
    CapabilityRgbDepthConcurrent = 1u,
    CapabilityInfrared = 1u << 1,
    CapabilityNativeMetricDepth = 1u << 2,
    CapabilityNativeJpegColor = 1u << 3,
    CapabilityStudioBody3D = 1u << 4,
};

enum PixelFormat : std::uint32_t {
    Bgra32 = 0x41524742u,
    DepthMm16 = 1003u,
    InfraredU16 = 1004u,
    Jpeg = 1005u,
};

enum Result : std::int32_t {
    ResultOk = 0,
    ResultUnsupported = -1,
    ResultDeviceNotFound = -2,
    ResultDeviceBusy = -3,
    ResultStreamingUnavailable = -4,
};

#pragma pack(push, 1)
struct Request {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    Command command = Command::SubscribeStreams;
    std::uint32_t streamMask = StreamDepth;
};

struct RequestV2 {
    Request request{};
    char deviceId[64]{};
};

struct Reply {
    std::uint32_t magic = kMagic;
    std::uint32_t version = kVersion;
    std::int32_t result = ResultUnsupported;
    std::uint32_t acceptedMask = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t capabilities = 0;
    std::uint32_t maxPayloadBytes = 0;
    std::uint32_t depthCalibrationValid = 0;
    double depthConstShift = 0;
    double depthEmitterDistance = 0;
    double depthReferenceDistance = 0;
    double depthReferencePixelSize = 0;
};

struct MotionSample {
    std::uint32_t flags = 0;
    std::int32_t accelX = 0;
    std::int32_t accelY = 0;
    std::int32_t accelZ = 0;
    std::int32_t tiltTenths = 0;
    std::uint64_t tickMs = 0;
};

struct FrameHeader {
    std::uint32_t magic = kFrameMagic;
    std::uint32_t version = kVersion;
    StreamMode mode = StreamMode::Depth;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    PixelFormat pixelFormat = DepthMm16;
    std::uint32_t payloadBytes = 0;
    std::uint32_t flags = 0;
    std::uint64_t frameNumber = 0;
    std::uint64_t tickMs = 0;
    MotionSample motion{};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16);
static_assert(sizeof(RequestV2) == 80);
static_assert(sizeof(Reply) == 68);
static_assert(sizeof(MotionSample) == 28);
static_assert(sizeof(FrameHeader) == 76);

constexpr std::uint32_t maskFor(StreamMode mode) {
    switch (mode) {
        case StreamMode::Rgb: return StreamRgb;
        case StreamMode::Infrared: return StreamInfrared;
        case StreamMode::Depth: return StreamDepth;
        case StreamMode::RgbHighQuality: return StreamRgbHighQuality;
    }
    return 0;
}

}  // namespace KinectOneRemoldProtocol
