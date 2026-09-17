#include <charconv>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>

#include <unistd.h>

#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {

void usage() {
  std::puts(
      "Usage: kinect360-remoldctl [--device ID] "
      "status | backend | tilt <degrees> | "
      "led <off|green|red|yellow|blink-green|blink-yellow-red> | "
      "ping | nui | sdk | audio-volume [0..100] | audio-mute <on|off>");
}

bool parse_int(std::string_view text, int& value) {
  if (text.empty()) return false;
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto result = std::from_chars(begin, end, value, 10);
  return result.ec == std::errc{} && result.ptr == end;
}

int led_value(const std::string& value) {
  if (value == "off") return 0;
  if (value == "green") return 1;
  if (value == "red") return 2;
  if (value == "yellow") return 3;
  if (value == "blink-green") return 4;
  if (value == "blink-yellow-red") return 6;
  return -1;
}

bool copy_device_id(char* destination, size_t capacity, const std::string& id) {
  if (!destination || capacity == 0 || id.size() >= capacity) return false;
  std::memset(destination, 0, capacity);
  if (!id.empty()) std::memcpy(destination, id.data(), id.size());
  return true;
}

int nui_info() {
  int fd = unixio::connect_socket(nui::kSocket);
  if (fd < 0) {
    std::perror("nui");
    return 3;
  }
  (void)unixio::set_io_timeout(fd, 3000);

  nui::Request request{};
  nui::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply))) {
    ::close(fd);
    std::puts("NUI I/O failed");
    return 4;
  }
  ::close(fd);

  if (reply.magic != nui::kMagic || reply.version != nui::kVersion) {
    std::puts("NUI ABI mismatch");
    return 5;
  }

  std::printf("NUI v%u result=%d joints=%u max_skeletons=%u capabilities=0x%08x\n",
              reply.version, reply.result, reply.jointCount, reply.maxSkeletons,
              reply.capabilities);
  std::printf("camera=%s\naudio=%s\naudio_control=%s\ncontrol=%s\nskeleton=%s\nsdk=%s\n",
              reply.cameraEndpoint, reply.audioEndpoint, reply.audioControlEndpoint,
              reply.controlEndpoint, reply.skeletonEndpoint, reply.sdkEndpoint);
  return reply.result < 0 ? 6 : 0;
}

int audio_control(const std::string& device_id,
                  audio::ControlCommand command,
                  int32_t value) {
  int fd = unixio::connect_socket(kAudioControlSocket);
  if (fd < 0) {
    std::perror("audio-control");
    return 3;
  }
  (void)unixio::set_io_timeout(fd, 3000);

  audio::ControlRequest request{};
  request.command = command;
  request.value = value;
  if (!copy_device_id(request.deviceId, sizeof(request.deviceId), device_id)) {
    ::close(fd);
    std::puts("Device ID is too long");
    return 2;
  }

  audio::ControlReply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply))) {
    ::close(fd);
    std::puts("audio control I/O failed");
    return 4;
  }
  ::close(fd);

  if (reply.magic != audio::kControlMagic || reply.version != audio::kVersion) {
    std::puts("audio control ABI mismatch");
    return 5;
  }
  if (reply.result < 0) {
    std::printf("ERROR %d (%s)\n", reply.result, std::strerror(-reply.result));
    return 6;
  }

  const char* backend = "software";
  if (reply.backend == audio::VolumeBackend::AlsaMixer) backend = "alsa-mixer";
  if (reply.backend == audio::VolumeBackend::WindowsEndpoint) backend = "windows-endpoint";
  std::printf("volume=%.1f%% mute=%s backend=%s capabilities=0x%08x\n",
              reply.volumeBasisPoints / 100.0,
              reply.muted ? "on" : "off",
              backend,
              reply.capabilities);
  return 0;
}

int sdk_info(const std::string& device_id) {
  int fd = unixio::connect_socket(sdk::kSocket);
  if (fd < 0) {
    std::perror("sdk");
    return 3;
  }
  (void)unixio::set_io_timeout(fd, 3000);

  sdk::Request request{};
  request.command = sdk::Command::RuntimeInfo;
  if (!copy_device_id(request.deviceId, sizeof(request.deviceId), device_id)) {
    ::close(fd);
    std::puts("Device ID is too long");
    return 2;
  }

  sdk::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply))) {
    ::close(fd);
    std::puts("SDK bridge I/O failed");
    return 4;
  }
  ::close(fd);

  if (reply.magic != sdk::kMagic || reply.version != sdk::kVersion) {
    std::puts("SDK bridge ABI mismatch");
    return 5;
  }

  std::printf(
      "SDK bridge v%u result=%d sensors=%u status=%u capabilities=0x%08x "
      "elevation=%d accel=%d,%d,%d\n",
      reply.version, reply.result, reply.sensorCount, reply.status, reply.capabilities,
      reply.elevationDegrees, reply.accelX, reply.accelY, reply.accelZ);
  std::printf("camera=%s\naudio=%s\naudio_control=%s\nskeleton=%s\n",
              reply.cameraEndpoint, reply.audioEndpoint,
              reply.audioControlEndpoint, reply.skeletonEndpoint);
  return reply.result < 0 ? 6 : 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    usage();
    return 2;
  }

  int arg = 1;
  std::string device_id;
  if (arg + 1 < argc && std::string_view(argv[arg]) == "--device") {
    device_id = argv[arg + 1];
    arg += 2;
    if (device_id.empty() || device_id.size() >= kDeviceIdBytes) {
      usage();
      return 2;
    }
  }
  if (arg >= argc) {
    usage();
    return 2;
  }

  const std::string action = argv[arg++];
  if (action == "backend" && arg == argc) {
    std::puts(
        "platform=linux usb=libusb-1.0 kernel=usbfs+udev "
        "audio=02ad-libusb-boot|02bb-02c3-snd-usb-audio-alsa");
    return 0;
  }
  if (action == "nui" && arg == argc) return nui_info();
  if (action == "sdk" && arg == argc) return sdk_info(device_id);

  if (action == "audio-volume") {
    if (arg == argc) {
      return audio_control(device_id, audio::ControlCommand::GetState, 0);
    }
    if (arg + 1 == argc) {
      int percent = 0;
      if (!parse_int(argv[arg], percent) || percent < 0 || percent > 100) {
        usage();
        return 2;
      }
      return audio_control(device_id, audio::ControlCommand::SetVolume, percent * 100);
    }
    usage();
    return 2;
  }

  if (action == "audio-mute" && arg + 1 == argc) {
    const std::string value = argv[arg];
    if (value != "on" && value != "off") {
      usage();
      return 2;
    }
    return audio_control(device_id, audio::ControlCommand::SetMute, value == "on" ? 1 : 0);
  }

  control::Request request{};
  if (!copy_device_id(request.deviceId, sizeof(request.deviceId), device_id)) {
    usage();
    return 2;
  }

  if (action == "ping" && arg == argc) {
    request.command = control::Command::Ping;
  } else if (action == "status" && arg == argc) {
    request.command = control::Command::Status;
  } else if (action == "tilt" && arg + 1 == argc) {
    int degrees = 0;
    if (!parse_int(argv[arg], degrees) || degrees < -27 || degrees > 27) {
      usage();
      return 2;
    }
    request.command = control::Command::Tilt;
    request.value = degrees;
  } else if (action == "led" && arg + 1 == argc) {
    const int value = led_value(argv[arg]);
    if (value < 0) {
      usage();
      return 2;
    }
    request.command = control::Command::Led;
    request.value = value;
  } else {
    usage();
    return 2;
  }

  int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) {
    std::perror("broker");
    return 3;
  }
  (void)unixio::set_io_timeout(fd, 3000);

  control::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply))) {
    ::close(fd);
    std::puts("broker I/O failed");
    return 4;
  }
  ::close(fd);

  if (reply.magic != control::kMagic || reply.version != control::kVersion) {
    std::puts("broker ABI mismatch");
    return 5;
  }
  if (reply.result < 0) {
    std::printf("ERROR %d (%s)\n", reply.result, std::strerror(-reply.result));
    return 5;
  }

  if (action == "status") {
    std::printf("OK device=%s accel=%d,%d,%d tilt=%.1f state=%u\n",
                device_id.empty() ? "auto" : device_id.c_str(),
                reply.accelX, reply.accelY, reply.accelZ,
                reply.tiltTenths / 10.0, reply.state);
  } else {
    std::puts("OK");
  }
  return 0;
}
