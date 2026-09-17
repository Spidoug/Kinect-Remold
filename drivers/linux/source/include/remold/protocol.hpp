#pragma once

#include <cstdint>

namespace remold {

inline constexpr const char* kRuntimeDir = "/run/kinect360-remold";
inline constexpr const char* kControlSocket = "/run/kinect360-remold/control.sock";
inline constexpr const char* kDeviceManifest = "/run/kinect360-remold/devices.tsv";
inline constexpr const char* kAudioSocket = "/run/kinect360-remold/audio.sock";
inline constexpr const char* kAudioControlSocket = "/run/kinect360-remold/audio-control.sock";
inline constexpr const char* kAudioStatus = "/run/kinect360-remold/audio-bridge-status.txt";
inline constexpr const char* kConfigPath = "/etc/kinect360-remold/remold.conf";
inline constexpr uint32_t kDeviceIdBytes = 64;

namespace control {

inline constexpr uint32_t kMagic = 0x54434D52u;
inline constexpr uint32_t kVersion = 1;

enum class Command : uint32_t {
  Ping = 0,
  Status = 1,
  Tilt = 2,
  Led = 3,
  PrepareCamera = 4,
};

enum class Transport : uint32_t {
  None = 0,
  PhysicalMotor = 1,
};

enum class LedMode : int32_t {
  Off = 0,
  Green = 1,
  Red = 2,
  Yellow = 3,
  BlinkGreen = 4,
  BlinkYellowRed = 6,
};

#pragma pack(push, 1)
struct Request {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  Command command = Command::Ping;
  int32_t value = 0;
  char deviceId[kDeviceIdBytes]{};
};

struct Reply {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  int32_t result = 0;
  Transport transport = Transport::None;
  int32_t accelX = 0;
  int32_t accelY = 0;
  int32_t accelZ = 0;
  int32_t tiltTenths = 0;
  uint32_t state = 0;
};
#pragma pack(pop)

static_assert(sizeof(Request) == 80);
static_assert(sizeof(Reply) == 36);

}  // namespace control

namespace scanner {

inline constexpr uint32_t kMagic = 0x43534D52u;
inline constexpr uint32_t kFrameMagic = 0x46534D52u;
inline constexpr uint32_t kVersion = 1;
inline constexpr uint32_t kWidth = 640;
inline constexpr uint32_t kHeight = 480;
inline constexpr uint32_t kRgbHqWidth = 1280;
inline constexpr uint32_t kRgbHqHeight = 1024;
inline constexpr uint32_t kIrRawHeight = 488;

enum class Command : uint32_t {
  SubscribeStreams = 1,
};

enum class StreamMode : int32_t {
  Rgb = 0,
  Infrared = 1,
  Depth = 2,
  RgbHighQuality = 3,
};

enum StreamMask : uint32_t {
  StreamRgb = 1,
  StreamInfrared = 2,
  StreamDepth = 4,
  StreamRgbHighQuality = 8,
  StreamSupported = 15,
};

enum Capability : uint32_t {
  CapabilityRgbDepthConcurrent = 1,
  CapabilityExclusiveVideoMode = 2,
  CapabilityProjectorRefCounted = 4,
  CapabilityAccelerometer = 8,
  CapabilityRgbHighQuality = 16,
  CapabilityRawSensorFrames = 64,
  CapabilityPersistentIsoSession = 128,
};

enum class PixelFormat : uint32_t {
  BayerGrbg8 = 4,
  IrRaw10Packed = 5,
  DepthRaw11Packed = 6,
};

inline constexpr uint32_t kRgbRawPayloadBytes = kWidth * kHeight;
inline constexpr uint32_t kIrRaw10PayloadBytes = kWidth * kIrRawHeight * 10u / 8u;
inline constexpr uint32_t kDepthRaw11PackedPayloadBytes = kWidth * kHeight * 11u / 8u;
inline constexpr uint32_t kRgbHqPayloadBytes = kRgbHqWidth * kRgbHqHeight;
inline constexpr uint32_t kMaxPayloadBytes = kRgbHqPayloadBytes;
inline constexpr uint32_t kFlagFrameRecovered = 1;

#pragma pack(push, 1)
struct Request {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  Command command = Command::SubscribeStreams;
  uint32_t streamMask = StreamDepth;
};

struct Reply {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  int32_t result = 0;
  uint32_t acceptedMask = 0;
  uint32_t width = kWidth;
  uint32_t height = kHeight;
  uint32_t capabilities = CapabilityRgbDepthConcurrent |
                          CapabilityExclusiveVideoMode |
                          CapabilityProjectorRefCounted |
                          CapabilityRgbHighQuality |
                          CapabilityRawSensorFrames |
                          CapabilityPersistentIsoSession;
  uint32_t maxPayloadBytes = kMaxPayloadBytes;
  uint32_t depthCalibrationValid = 0;
  double depthConstShift = 0.0;
  double depthEmitterDistance = 0.0;
  double depthReferenceDistance = 0.0;
  double depthReferencePixelSize = 0.0;
};

struct MotionSample {
  uint32_t flags = 0;
  int32_t accelX = 0;
  int32_t accelY = 0;
  int32_t accelZ = 0;
  int32_t tiltTenths = 0;
  uint64_t tickMs = 0;
};

struct FrameHeader {
  uint32_t magic = kFrameMagic;
  uint32_t version = kVersion;
  StreamMode mode = StreamMode::Depth;
  uint32_t width = kWidth;
  uint32_t height = kHeight;
  PixelFormat pixelFormat = PixelFormat::DepthRaw11Packed;
  uint32_t payloadBytes = kDepthRaw11PackedPayloadBytes;
  uint32_t flags = 0;
  uint64_t frameNumber = 0;
  uint64_t tickMs = 0;
  MotionSample motion{};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16);
static_assert(sizeof(Reply) == 68);
static_assert(sizeof(MotionSample) == 28);
static_assert(sizeof(FrameHeader) == 76);

inline bool valid_mask(uint32_t mask) {
  if (mask == 0 || (mask & ~StreamSupported) != 0) return false;
  const bool wants_ir = (mask & StreamInfrared) != 0;
  const bool wants_color = (mask & (StreamRgb | StreamRgbHighQuality)) != 0;
  return !(wants_ir && wants_color);
}

}  // namespace scanner

namespace audio {

inline constexpr uint32_t kMagic = 0x414D4D52u;
inline constexpr uint32_t kFrameMagic = 0x464D4D52u;
inline constexpr uint32_t kVersion = 1;
inline constexpr uint32_t kSampleRate = 16000;
inline constexpr uint32_t kChannels = 4;
inline constexpr uint32_t kSamples = 256;
inline constexpr uint32_t kBytesPerSample = 4;
inline constexpr uint32_t kPayloadBytes = kChannels * kSamples * kBytesPerSample;
inline constexpr uint32_t kControlMagic = 0x434D4D52u;  // "RMMC"

enum class Command : uint32_t {
  SubscribeMicrophones = 1,
};

enum class SampleFormat : uint32_t {
  PcmS32Le = 1,
};

enum Capability : uint32_t {
  CapabilityPhysicalMicrophoneArray = 1,
  CapabilityChannelValidityMask = 2,
  CapabilityCaptureVolume = 4,
  CapabilityCaptureMute = 8,
  CapabilitySharedCapture = 16,
};

enum class ControlCommand : uint32_t {
  GetState = 1,
  SetVolume = 2,
  SetMute = 3,
};

enum class VolumeBackend : uint32_t {
  Software = 1,
  AlsaMixer = 2,
  WindowsEndpoint = 3,
};

#pragma pack(push, 1)
struct Request {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  Command command = Command::SubscribeMicrophones;
  uint32_t reserved = 0;
  char deviceId[kDeviceIdBytes]{};
};

struct Reply {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  int32_t result = 0;
  uint32_t sampleRate = kSampleRate;
  uint32_t channels = kChannels;
  SampleFormat sampleFormat = SampleFormat::PcmS32Le;
  uint32_t maxPayloadBytes = kPayloadBytes;
  uint32_t capabilities = CapabilityPhysicalMicrophoneArray |
                          CapabilityChannelValidityMask |
                          CapabilityCaptureVolume |
                          CapabilityCaptureMute |
                          CapabilitySharedCapture;
};

struct FrameHeader {
  uint32_t magic = kFrameMagic;
  uint32_t version = kVersion;
  uint32_t sampleRate = kSampleRate;
  uint32_t channels = kChannels;
  SampleFormat sampleFormat = SampleFormat::PcmS32Le;
  uint32_t samplesPerChannel = kSamples;
  uint32_t payloadBytes = kPayloadBytes;
  uint32_t channelMask = 0;
  uint64_t frameNumber = 0;
  uint64_t tickMs = 0;
};

struct ControlRequest {
  uint32_t magic = kControlMagic;
  uint32_t version = kVersion;
  ControlCommand command = ControlCommand::GetState;
  int32_t value = 0;
  char deviceId[kDeviceIdBytes]{};
};

struct ControlReply {
  uint32_t magic = kControlMagic;
  uint32_t version = kVersion;
  int32_t result = 0;
  int32_t volumeBasisPoints = 10000;
  uint32_t muted = 0;
  uint32_t capabilities = CapabilityCaptureVolume |
                          CapabilityCaptureMute |
                          CapabilitySharedCapture;
  VolumeBackend backend = VolumeBackend::Software;
  uint32_t reserved = 0;
};
#pragma pack(pop)

static_assert(sizeof(Request) == 80);
static_assert(sizeof(Reply) == 32);
static_assert(sizeof(FrameHeader) == 48);
static_assert(sizeof(ControlRequest) == 80);
static_assert(sizeof(ControlReply) == 32);

}  // namespace audio

namespace nui {

// Kinect v1 / Xbox 360 NUI-style compatibility ABI. It intentionally does not
// impersonate Microsoft's proprietary runtime. The ABI mirrors the sensor
// concepts games normally expect: color/depth, four microphones, motor state
// and the canonical 20-joint Kinect v1 skeleton topology.
inline constexpr const char* kSocket = "/run/kinect360-remold/nui.sock";
inline constexpr const char* kSkeletonSocket = "/run/kinect360-remold/nui-skeleton.sock";
inline constexpr uint32_t kMagic = 0x49554E52u;
inline constexpr uint32_t kSkeletonFrameMagic = 0x46554E52u;
inline constexpr uint32_t kVersion = 2;
inline constexpr uint32_t kSkeletonVersion = 1;
inline constexpr uint32_t kJointCount = 20;
inline constexpr uint32_t kMaxSkeletons = 6;

enum class Command : uint32_t {
  RuntimeInfo = 1,
};

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

enum JointType : uint32_t {
  HipCenter = 0,
  Spine = 1,
  ShoulderCenter = 2,
  Head = 3,
  ShoulderLeft = 4,
  ElbowLeft = 5,
  WristLeft = 6,
  HandLeft = 7,
  ShoulderRight = 8,
  ElbowRight = 9,
  WristRight = 10,
  HandRight = 11,
  HipLeft = 12,
  KneeLeft = 13,
  AnkleLeft = 14,
  FootLeft = 15,
  HipRight = 16,
  KneeRight = 17,
  AnkleRight = 18,
  FootRight = 19,
};

enum class TrackingState : uint32_t {
  NotTracked = 0,
  PositionOnly = 1,
  Tracked = 2,
};

enum class SkeletonRole : uint32_t {
  Subscribe = 1,
  Publish = 2,
};

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
  uint32_t capabilities = CapabilityColor |
                          CapabilityInfrared |
                          CapabilityDepth |
                          CapabilityAudio4Mic |
                          CapabilityTiltLedAccel |
                          CapabilityNui20JointModel |
                          CapabilityRawSensorFrames |
                          CapabilitySkeletonStream |
                          CapabilityAudioControl |
                          CapabilitySdkBridge;
  uint32_t jointCount = kJointCount;
  uint32_t maxSkeletons = kMaxSkeletons;
  uint32_t colorWidth = scanner::kWidth;
  uint32_t colorHeight = scanner::kHeight;
  uint32_t depthWidth = scanner::kWidth;
  uint32_t depthHeight = scanner::kHeight;
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
  float x = 0;
  float y = 0;
  float z = 0;
  float confidence = 0;
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

static_assert(sizeof(Request) == 16);
static_assert(sizeof(Reply) == 688);
static_assert(sizeof(SkeletonHello) == 80);
static_assert(sizeof(SkeletonReply) == 20);
static_assert(sizeof(Joint) == 20);
static_assert(sizeof(SkeletonBody) == 416);
static_assert(sizeof(SkeletonFrame) == 2528);

}  // namespace nui

namespace sdk {

// Clean-room SDK/NUI bridge used by native applications and emulator adapters.
// It maps Microsoft Kinect v1 concepts onto the Remold services without copying
// or redistributing the Microsoft runtime.
inline constexpr const char* kSocket = "/run/kinect360-remold/sdk.sock";
inline constexpr uint32_t kMagic = 0x4B534D52u;  // "RMSK"
inline constexpr uint32_t kVersion = 1;

enum class Command : uint32_t {
  SensorCount = 1,
  Status = 2,
  Initialize = 3,
  Shutdown = 4,
  GetElevation = 5,
  SetElevation = 6,
  GetAccelerometer = 7,
  RuntimeInfo = 8,
};

enum InitFlags : uint32_t {
  UsesColor = 1u << 0,
  UsesDepth = 1u << 1,
  UsesSkeleton = 1u << 2,
  UsesAudio = 1u << 3,
  UsesInfrared = 1u << 4,
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
  int32_t accelX = 0;
  int32_t accelY = 0;
  int32_t accelZ = 0;
  uint32_t initializedFlags = 0;
  char cameraEndpoint[108]{};
  char audioEndpoint[108]{};
  char audioControlEndpoint[108]{};
  char skeletonEndpoint[108]{};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 88);
static_assert(sizeof(Reply) == 476);

}  // namespace sdk

}  // namespace remold
