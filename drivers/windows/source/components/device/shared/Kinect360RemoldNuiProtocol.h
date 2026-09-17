#pragma once
#include <cstdint>

namespace Kinect360RemoldNui {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldNui";
constexpr wchar_t kSkeletonPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldNuiSkeleton";
constexpr wchar_t kSdkPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldSdk";
constexpr uint32_t kMagic = 0x49554E52u;              // "RNUI"
constexpr uint32_t kSkeletonFrameMagic = 0x46554E52u; // "RNUF"
constexpr uint32_t kVersion = 2;
constexpr uint32_t kSkeletonVersion = 1;
constexpr uint32_t kJointCount = 20;
constexpr uint32_t kMaxSkeletons = 6;
constexpr uint32_t kDeviceIdBytes = 64;

enum class Command : uint32_t { RuntimeInfo = 1 };
enum Capability : uint32_t {
    CapabilityColor = 1u << 0,
    CapabilityInfrared = 1u << 1,
    CapabilityDepth = 1u << 2,
    CapabilityAudio4Mic = 1u << 3,
    CapabilityTiltLedAccel = 1u << 4,
    CapabilityNui20JointModel = 1u << 5,
    CapabilityRawSensorFrames = 1u << 6,
    CapabilitySkeletonStream = 1u << 7,
    CapabilityAudioControl = 1u << 8,
    CapabilitySdkBridge = 1u << 9,
};
enum class TrackingState : uint32_t { NotTracked = 0, PositionOnly = 1, Tracked = 2 };
enum class SkeletonRole : uint32_t { Subscribe = 1, Publish = 2 };

#pragma pack(push, 1)
struct Request {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    Command command = Command::RuntimeInfo;
    uint32_t reserved = 0;
};
struct Reply {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    int32_t result = 0;
    uint32_t capabilities = CapabilityColor | CapabilityInfrared | CapabilityDepth |
                            CapabilityAudio4Mic | CapabilityTiltLedAccel | CapabilityNui20JointModel |
                            CapabilityRawSensorFrames | CapabilitySkeletonStream |
                            CapabilityAudioControl | CapabilitySdkBridge;
    uint32_t jointCount = kJointCount;
    uint32_t maxSkeletons = kMaxSkeletons;
    uint32_t colorWidth = 640;
    uint32_t colorHeight = 480;
    uint32_t depthWidth = 640;
    uint32_t depthHeight = 480;
    char cameraEndpoint[108]{};
    char audioEndpoint[108]{};
    char controlEndpoint[108]{};
    char skeletonEndpoint[108]{};
    char audioControlEndpoint[108]{};
    char sdkEndpoint[108]{};
};
struct SkeletonHello {
    uint32_t magic = kMagic;
    uint32_t version = kSkeletonVersion;
    SkeletonRole role = SkeletonRole::Subscribe;
    uint32_t reserved = 0;
    char deviceId[kDeviceIdBytes]{};
};
struct SkeletonReply {
    uint32_t magic = kMagic;
    uint32_t version = kSkeletonVersion;
    int32_t result = 0;
    uint32_t jointCount = kJointCount;
    uint32_t maxSkeletons = kMaxSkeletons;
};
struct Joint {
    float x = 0, y = 0, z = 0, confidence = 0;
    TrackingState state = TrackingState::NotTracked;
};
struct SkeletonBody {
    uint64_t trackingId = 0;
    TrackingState trackingState = TrackingState::NotTracked;
    uint32_t reserved = 0;
    Joint joints[kJointCount]{};
};
struct SkeletonFrame {
    uint32_t magic = kSkeletonFrameMagic;
    uint32_t version = kSkeletonVersion;
    uint32_t bodyCount = 0;
    uint32_t reserved = 0;
    uint64_t frameNumber = 0;
    uint64_t tickMs = 0;
    SkeletonBody bodies[kMaxSkeletons]{};
};
#pragma pack(pop)
static_assert(sizeof(Request) == 16, "NUI request ABI");
static_assert(sizeof(Reply) == 688, "NUI reply ABI");
static_assert(sizeof(SkeletonHello) == 80, "NUI skeleton hello ABI");
static_assert(sizeof(SkeletonReply) == 20, "NUI skeleton reply ABI");
static_assert(sizeof(Joint) == 20, "NUI joint ABI");
static_assert(sizeof(SkeletonBody) == 416, "NUI skeleton body ABI");
static_assert(sizeof(SkeletonFrame) == 2528, "NUI skeleton frame ABI");

namespace Sdk {
constexpr uint32_t kMagic = 0x4B534D52u; // "RMSK"
constexpr uint32_t kVersion = 1;
enum class Command : uint32_t {
    SensorCount = 1, Status = 2, Initialize = 3, Shutdown = 4,
    GetElevation = 5, SetElevation = 6, GetAccelerometer = 7, RuntimeInfo = 8,
};
enum InitFlags : uint32_t {
    UsesColor = 1u << 0, UsesDepth = 1u << 1, UsesSkeleton = 1u << 2,
    UsesAudio = 1u << 3, UsesInfrared = 1u << 4,
};
#pragma pack(push, 1)
struct Request {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    Command command = Command::Status;
    int32_t value = 0;
    uint32_t flags = 0;
    uint32_t sensorIndex = 0;
    char deviceId[kDeviceIdBytes]{};
};
struct Reply {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    int32_t result = 0;
    uint32_t sensorCount = 0;
    uint32_t status = 0;
    uint32_t capabilities = 0;
    int32_t elevationDegrees = 0;
    int32_t accelX = 0, accelY = 0, accelZ = 0;
    uint32_t initializedFlags = 0;
    char cameraEndpoint[108]{};
    char audioEndpoint[108]{};
    char audioControlEndpoint[108]{};
    char skeletonEndpoint[108]{};
};
#pragma pack(pop)
static_assert(sizeof(Request) == 88, "SDK request ABI");
static_assert(sizeof(Reply) == 476, "SDK reply ABI");
} // namespace Sdk
} // namespace Kinect360RemoldNui
