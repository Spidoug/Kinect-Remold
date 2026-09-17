#include "remold_sdk_bridge.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace {

constexpr uint32_t kSdkMagic = 0x4B534D52u;           // RMSK
constexpr uint32_t kSdkVersion = 1u;
constexpr uint32_t kAudioControlMagic = 0x434D4D52u;  // RMMC
constexpr uint32_t kAudioVersion = 1u;
constexpr size_t kDeviceIdBytes = 64;
constexpr size_t kEndpointBytes = 108;

enum class SdkCommand : uint32_t {
  SensorCount = 1,
  Status = 2,
  Initialize = 3,
  Shutdown = 4,
  GetElevation = 5,
  SetElevation = 6,
  GetAccelerometer = 7,
  RuntimeInfo = 8,
};

enum class AudioCommand : uint32_t {
  GetState = 1,
  SetVolume = 2,
  SetMute = 3,
};

#pragma pack(push, 1)
struct SdkRequest {
  uint32_t magic = kSdkMagic;
  uint32_t version = kSdkVersion;
  SdkCommand command = SdkCommand::Status;
  int32_t value = 0;
  uint32_t flags = 0;
  uint32_t sensorIndex = 0;
  char deviceId[kDeviceIdBytes]{};
};

struct SdkReply {
  uint32_t magic = kSdkMagic;
  uint32_t version = kSdkVersion;
  int32_t result = 0;
  uint32_t sensorCount = 0;
  uint32_t status = 0;
  uint32_t capabilities = 0;
  int32_t elevationDegrees = 0;
  int32_t accelX = 0;
  int32_t accelY = 0;
  int32_t accelZ = 0;
  uint32_t initializedFlags = 0;
  char cameraEndpoint[kEndpointBytes]{};
  char audioEndpoint[kEndpointBytes]{};
  char audioControlEndpoint[kEndpointBytes]{};
  char skeletonEndpoint[kEndpointBytes]{};
};

struct AudioRequest {
  uint32_t magic = kAudioControlMagic;
  uint32_t version = kAudioVersion;
  AudioCommand command = AudioCommand::GetState;
  int32_t value = 0;
  char deviceId[kDeviceIdBytes]{};
};

struct AudioReply {
  uint32_t magic = kAudioControlMagic;
  uint32_t version = kAudioVersion;
  int32_t result = 0;
  int32_t volumeBasisPoints = 10000;
  uint32_t muted = 0;
  uint32_t capabilities = 0;
  uint32_t backend = 1;
  uint32_t reserved = 0;
};
#pragma pack(pop)

static_assert(sizeof(SdkRequest) == 88, "SDK request ABI");
static_assert(sizeof(SdkReply) == 476, "SDK reply ABI");
static_assert(sizeof(AudioRequest) == 80, "audio control request ABI");
static_assert(sizeof(AudioReply) == 32, "audio control reply ABI");

thread_local std::string gLastError;
thread_local uint32_t gSensorIndex = 0;
thread_local std::string gDeviceId;

void fail(const std::string& text) {
  gLastError = text;
}

void clear_error() {
  gLastError.clear();
}

void copy_device_id(char (&destination)[kDeviceIdBytes], const std::string& id) {
  std::memset(destination, 0, sizeof(destination));
  const size_t count = std::min(id.size(), sizeof(destination) - 1);
  if (count != 0) std::memcpy(destination, id.data(), count);
}

#ifdef _WIN32

using NativeHandle = HANDLE;
constexpr NativeHandle kInvalid = INVALID_HANDLE_VALUE;

void close_handle(NativeHandle handle) {
  if (handle != kInvalid) CloseHandle(handle);
}

NativeHandle connect_local(const wchar_t* path) {
  for (int attempt = 0; attempt < 2; ++attempt) {
    HANDLE handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle != INVALID_HANDLE_VALUE) return handle;

    const DWORD error = GetLastError();
    if (error != ERROR_PIPE_BUSY || !WaitNamedPipeW(path, 1500)) break;
  }

  fail("named pipe unavailable: " + std::to_string(GetLastError()));
  return kInvalid;
}

bool write_exact(NativeHandle handle, const void* data, size_t bytes) {
  const auto* cursor = static_cast<const uint8_t*>(data);
  size_t total = 0;
  while (total < bytes) {
    DWORD written = 0;
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(bytes - total, 0x7fffffffu));
    if (!WriteFile(handle, cursor + total, chunk, &written, nullptr) || written == 0) {
      fail("named pipe write failed: " + std::to_string(GetLastError()));
      return false;
    }
    total += written;
  }
  return true;
}

bool read_exact(NativeHandle handle, void* data, size_t bytes) {
  auto* cursor = static_cast<uint8_t*>(data);
  size_t total = 0;
  while (total < bytes) {
    DWORD received = 0;
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(bytes - total, 0x7fffffffu));
    if (!ReadFile(handle, cursor + total, chunk, &received, nullptr) || received == 0) {
      fail("named pipe read failed: " + std::to_string(GetLastError()));
      return false;
    }
    total += received;
  }
  return true;
}

#else

using NativeHandle = int;
constexpr NativeHandle kInvalid = -1;

void close_handle(NativeHandle handle) {
  if (handle >= 0) ::close(handle);
}

bool set_timeout(NativeHandle handle, int milliseconds) {
  timeval timeout{};
  timeout.tv_sec = milliseconds / 1000;
  timeout.tv_usec = (milliseconds % 1000) * 1000;
  return ::setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
         ::setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

NativeHandle connect_local(const char* path) {
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    fail("socket: " + std::string(std::strerror(errno)));
    return kInvalid;
  }

  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  const size_t path_length = std::strlen(path);
  if (path_length >= sizeof(address.sun_path)) {
    fail("unix socket path too long");
    ::close(fd);
    return kInvalid;
  }
  std::memcpy(address.sun_path, path, path_length + 1);

  if (::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    fail("connect: " + std::string(std::strerror(errno)));
    ::close(fd);
    return kInvalid;
  }

  if (!set_timeout(fd, 3000)) {
    fail("socket timeout setup failed: " + std::string(std::strerror(errno)));
    ::close(fd);
    return kInvalid;
  }
  return fd;
}

bool write_exact(NativeHandle handle, const void* data, size_t bytes) {
  const auto* cursor = static_cast<const uint8_t*>(data);
  size_t total = 0;
  while (total < bytes) {
    const ssize_t written = ::send(handle, cursor + total, bytes - total, MSG_NOSIGNAL);
    if (written > 0) {
      total += static_cast<size_t>(written);
      continue;
    }
    if (written < 0 && errno == EINTR) continue;
    fail(written == 0 ? "socket write returned zero bytes"
                      : "socket write: " + std::string(std::strerror(errno)));
    return false;
  }
  return true;
}

bool read_exact(NativeHandle handle, void* data, size_t bytes) {
  auto* cursor = static_cast<uint8_t*>(data);
  size_t total = 0;
  while (total < bytes) {
    const ssize_t received = ::recv(handle, cursor + total, bytes - total, 0);
    if (received > 0) {
      total += static_cast<size_t>(received);
      continue;
    }
    if (received < 0 && errno == EINTR) continue;
    fail(received == 0 ? "bridge closed connection"
                       : "socket read: " + std::string(std::strerror(errno)));
    return false;
  }
  return true;
}

#endif

void copy_text(char* destination, size_t capacity, const char* source, size_t source_capacity) {
  if (!destination || capacity == 0) return;

  std::memset(destination, 0, capacity);
  size_t count = 0;
  while (count < source_capacity && source[count] != '\0') ++count;
  count = std::min(count, capacity - 1);
  if (count != 0) std::memcpy(destination, source, count);
}

void decode(const SdkReply& reply, RemoldSdkState* output) {
  if (!output) return;

  std::memset(output, 0, sizeof(*output));
  output->sensor_count = reply.sensorCount;
  output->connected = reply.status;
  output->capabilities = reply.capabilities;
  output->elevation_degrees = reply.elevationDegrees;
  output->accel_x = reply.accelX;
  output->accel_y = reply.accelY;
  output->accel_z = reply.accelZ;
  output->initialized_flags = reply.initializedFlags;
  copy_text(output->camera_endpoint, sizeof(output->camera_endpoint),
            reply.cameraEndpoint, sizeof(reply.cameraEndpoint));
  copy_text(output->audio_endpoint, sizeof(output->audio_endpoint),
            reply.audioEndpoint, sizeof(reply.audioEndpoint));
  copy_text(output->audio_control_endpoint, sizeof(output->audio_control_endpoint),
            reply.audioControlEndpoint, sizeof(reply.audioControlEndpoint));
  copy_text(output->skeleton_endpoint, sizeof(output->skeleton_endpoint),
            reply.skeletonEndpoint, sizeof(reply.skeletonEndpoint));
}

void decode_audio(const AudioReply& reply, RemoldAudioState* output) {
  if (!output) return;
  output->volume_basis_points = reply.volumeBasisPoints;
  output->muted = reply.muted;
  output->capabilities = reply.capabilities;
  output->backend = reply.backend;
}

int32_t sdk_exchange(SdkCommand command, int32_t value, uint32_t flags, SdkReply& reply) {
  clear_error();

  SdkRequest request{};
  request.command = command;
  request.value = value;
  request.flags = flags;
  request.sensorIndex = gSensorIndex;
  copy_device_id(request.deviceId, gDeviceId);

#ifdef _WIN32
  NativeHandle handle = connect_local(L"\\\\.\\pipe\\Kinect360RemoldSdk");
#else
  NativeHandle handle = connect_local("/run/kinect360-remold/sdk.sock");
#endif
  if (handle == kInvalid) return -1;

  const bool ok = write_exact(handle, &request, sizeof(request)) &&
                  read_exact(handle, &reply, sizeof(reply));
  close_handle(handle);
  if (!ok) return -2;

  if (reply.magic != kSdkMagic || reply.version != kSdkVersion) {
    fail("SDK bridge ABI mismatch");
    return -3;
  }
  return reply.result;
}

int32_t audio_exchange(AudioCommand command, int32_t value, AudioReply& reply) {
  clear_error();

  AudioRequest request{};
  request.command = command;
  request.value = value;
  copy_device_id(request.deviceId, gDeviceId);

#ifdef _WIN32
  NativeHandle handle = connect_local(L"\\\\.\\pipe\\Kinect360RemoldAudioControl");
#else
  NativeHandle handle = connect_local("/run/kinect360-remold/audio-control.sock");
#endif
  if (handle == kInvalid) return -1;

  const bool ok = write_exact(handle, &request, sizeof(request)) &&
                  read_exact(handle, &reply, sizeof(reply));
  close_handle(handle);
  if (!ok) return -2;

  if (reply.magic != kAudioControlMagic || reply.version != kAudioVersion) {
    fail("audio-control ABI mismatch");
    return -3;
  }
  return reply.result;
}

}  // namespace

extern "C" {

int32_t remold_sdk_select_sensor(uint32_t index) {
  gSensorIndex = index;
  gDeviceId.clear();
  clear_error();
  return 0;
}

int32_t remold_sdk_select_device(const char* device_id) {
  if (!device_id) {
    gDeviceId.clear();
    gSensorIndex = 0;
    clear_error();
    return 0;
  }

  const size_t length = std::strlen(device_id);
  if (length >= kDeviceIdBytes) {
    fail("device id is too long");
    return -1;
  }

  gDeviceId.assign(device_id, length);
  gSensorIndex = 0;
  clear_error();
  return 0;
}

int32_t remold_sdk_sensor_count(uint32_t* count) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::SensorCount, 0, 0, reply);
  if (count) *count = reply.sensorCount;
  return result;
}

int32_t remold_sdk_status(RemoldSdkState* state) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::Status, 0, 0, reply);
  decode(reply, state);
  return result;
}

int32_t remold_sdk_runtime_info(RemoldSdkState* state) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::RuntimeInfo, 0, 0, reply);
  decode(reply, state);
  return result;
}

int32_t remold_sdk_initialize(uint32_t flags, RemoldSdkState* state) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::Initialize, 0, flags, reply);
  decode(reply, state);
  return result;
}

int32_t remold_sdk_shutdown(RemoldSdkState* state) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::Shutdown, 0, 0, reply);
  decode(reply, state);
  return result;
}

int32_t remold_sdk_get_elevation(int32_t* degrees) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::GetElevation, 0, 0, reply);
  if (degrees) *degrees = reply.elevationDegrees;
  return result;
}

int32_t remold_sdk_set_elevation(int32_t degrees, RemoldSdkState* state) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::SetElevation, degrees, 0, reply);
  decode(reply, state);
  return result;
}

int32_t remold_sdk_get_accelerometer(int32_t* x, int32_t* y, int32_t* z) {
  SdkReply reply{};
  const int32_t result = sdk_exchange(SdkCommand::GetAccelerometer, 0, 0, reply);
  if (x) *x = reply.accelX;
  if (y) *y = reply.accelY;
  if (z) *z = reply.accelZ;
  return result;
}

int32_t remold_audio_get_state(RemoldAudioState* state) {
  AudioReply reply{};
  const int32_t result = audio_exchange(AudioCommand::GetState, 0, reply);
  decode_audio(reply, state);
  return result;
}

int32_t remold_audio_set_volume(int32_t volume_basis_points, RemoldAudioState* state) {
  AudioReply reply{};
  const int32_t value = std::clamp<int32_t>(volume_basis_points, 0, 10000);
  const int32_t result = audio_exchange(AudioCommand::SetVolume, value, reply);
  decode_audio(reply, state);
  return result;
}

int32_t remold_audio_set_mute(uint32_t muted, RemoldAudioState* state) {
  AudioReply reply{};
  const int32_t result = audio_exchange(AudioCommand::SetMute, muted ? 1 : 0, reply);
  decode_audio(reply, state);
  return result;
}

const char* remold_sdk_last_error(void) {
  return gLastError.c_str();
}

}  // extern "C"
