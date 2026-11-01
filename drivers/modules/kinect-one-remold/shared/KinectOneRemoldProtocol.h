#pragma once

#include <cstdint>
#include <cstddef>
#include <cstring>

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

// Reply.depthCalibrationValid codes for native metric-depth devices.
//   2 = Reply carries native depth intrinsics (fx, fy, cx, cy) in the four double fields.
//   3 = as 2, and a ReplyExtension (factory depth distortion + color intrinsics) follows
//       the 68-byte Reply. Sent only when the client asked for it (see below), so older
//       clients keep receiving exactly the 68-byte v1 reply.
constexpr std::uint32_t kDepthCalibrationNative = 2u;
constexpr std::uint32_t kDepthCalibrationNativeExtended = 3u;

// Backward-compatible opt-in: a client that understands ReplyExtension writes this
// marker into RequestV2.deviceId[63] and keeps the NUL-terminated id <= 62 bytes.
// Older servers read the id with strnlen() and ignore bytes after its terminator.
constexpr std::uint8_t kReplyExtensionRequest = 0xC3u;
constexpr std::uint32_t kReplyExtensionMagic = 0x31584352u;  // "RCX1"
constexpr std::uint32_t kReplyExtensionVersion = 1u;
enum ReplyExtensionFlags : std::uint32_t {
    ReplyExtensionDepthDistortion = 1u,
    ReplyExtensionColorIntrinsics = 1u << 1,
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

// Appended after Reply when depthCalibrationValid == kDepthCalibrationNativeExtended.
// Depth distortion is the factory Brown-Conrady model (OpenCV order k1,k2,p1,p2,k3
// applied to normalized coordinates) that the depth engine inverts when it builds its
// ray tables; depthPixelCenter is the pixel-centre convention of those tables
// (normalized x = (u + depthPixelCenter - cx) / fx). Color values are the factory
// color-camera parameters (single focal length, principal point, depth shift terms).
struct ReplyExtension {
    std::uint32_t magic = kReplyExtensionMagic;
    std::uint32_t version = kReplyExtensionVersion;
    std::uint32_t bytes = 64;
    std::uint32_t flags = 0;
    float depthK1 = 0, depthK2 = 0, depthK3 = 0, depthP1 = 0, depthP2 = 0;
    float depthPixelCenter = 0.5f;
    float colorFx = 0, colorFy = 0, colorCx = 0, colorCy = 0;
    float colorShiftD = 0, colorShiftM = 0;
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
static_assert(sizeof(ReplyExtension) == 64);
static_assert(sizeof(MotionSample) == 28);
static_assert(sizeof(FrameHeader) == 76);

inline bool extensionRequested(const RequestV2& request) {
    return static_cast<std::uint8_t>(request.deviceId[sizeof(request.deviceId) - 1]) == kReplyExtensionRequest;
}

// Fills ReplyExtension from the decoded depth calibration (k1..p2) and the raw
// color-parameter response (packed: u8 table id, then float f, cx, cy, shift_d, shift_m).
inline ReplyExtension makeReplyExtension(float k1, float k2, float k3, float p1, float p2,
                                         const std::uint8_t* colorParams, std::size_t colorBytes) {
    ReplyExtension ext{};
    ext.depthK1 = k1; ext.depthK2 = k2; ext.depthK3 = k3; ext.depthP1 = p1; ext.depthP2 = p2;
    ext.flags |= ReplyExtensionDepthDistortion;
    if (colorParams && colorBytes >= 21) {
        float v[5]{};
        std::memcpy(v, colorParams + 1, sizeof(v));
        if (v[0] > 1.0f && v[0] < 10000.0f && v[1] > 0.0f && v[2] > 0.0f) {
            ext.colorFx = v[0]; ext.colorFy = v[0]; ext.colorCx = v[1]; ext.colorCy = v[2];
            ext.colorShiftD = v[3]; ext.colorShiftM = v[4];
            ext.flags |= ReplyExtensionColorIntrinsics;
        }
    }
    return ext;
}

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
