#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>

#include "remold/device_registry.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
void usage() {
  std::puts(
      "usage: kinect360-remoldctl [--device DEVICE_ID] "
      "ping|status|tilt DEG|led MODE|rgb-hq-status|rgb-hq-on|rgb-hq-off|rgb-hq-toggle|"
      "probe [rgb|rgb-hq|ir|depth|rgb+depth|ir+depth] [SECONDS]");
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

void copy_id(char* destination, size_t capacity, const std::string& id) {
  if (!destination || capacity == 0) return;
  std::memset(destination, 0, capacity);
  std::memcpy(destination, id.data(), std::min(id.size(), capacity - 1));
}

bool is_rgb_hq_action(const std::string& action) {
  return action == "rgb-hq-status" || action == "rgb-hq-on" ||
      action == "rgb-hq-off" || action == "rgb-hq-toggle";
}

bool resolve_camera(const std::string& requested_id, std::string& id, std::string& endpoint) {
  const auto manifest = devices::read_manifest();
  if (!requested_id.empty()) {
    const auto* device = devices::find(manifest, requested_id);
    if (!device || device->camera.empty()) return false;
    id = device->id;
    endpoint = device->camera;
    return true;
  }

  for (const auto& device : manifest) {
    if (device.camera_ready()) {
      id = device.id;
      endpoint = device.camera;
      return true;
    }
  }
  return false;
}

bool exchange_settings(const std::string& endpoint, bool set, uint32_t requested, uint32_t& actual) {
  for (int attempt = 0; attempt < 4; ++attempt) {
    const int fd = unixio::connect_socket(endpoint);
    if (fd >= 0) {
      if (!unixio::set_io_timeout(fd, 3000)) {
        ::close(fd);
        continue;
      }
      scanner::Request request{};
      request.command = set ? scanner::Command::SetDriverSettings : scanner::Command::GetDriverSettings;
      request.streamMask = requested;
      scanner::Reply reply{};
      const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
          unixio::read_exact(fd, &reply, sizeof(reply)) && reply.result == 0;
      ::close(fd);
      if (ok) { actual = reply.acceptedMask; return true; }
    }
    if (attempt < 3) ::usleep(100000);
  }
  return false;
}

int handle_rgb_hq(const std::string& requested_id, const std::string& action) {
  std::string id;
  std::string endpoint;
  if (!resolve_camera(requested_id, id, endpoint)) {
    std::fprintf(stderr, "No Ready Kinect camera instance is available for device=%s.\n",
                 requested_id.empty() ? "auto" : requested_id.c_str());
    return 3;
  }

  uint32_t settings = 0;
  if (!exchange_settings(endpoint, false, 0, settings)) {
    std::fprintf(stderr, "Could not read driver settings for Kinect %s.\n", id.c_str());
    return 4;
  }

  if (action != "rgb-hq-status") {
    bool enable = false;
    if (action == "rgb-hq-on") enable = true;
    else if (action == "rgb-hq-toggle") enable = (settings & scanner::DriverSettingRgbHighQuality) == 0;

    uint32_t requested = settings;
    if (enable) requested |= scanner::DriverSettingRgbHighQuality;
    else requested &= ~scanner::DriverSettingRgbHighQuality;
    if (!exchange_settings(endpoint, true, requested, settings)) {
      std::fprintf(stderr, "Could not update driver settings for Kinect %s.\n", id.c_str());
      return 5;
    }
  }

  const bool enabled = (settings & scanner::DriverSettingRgbHighQuality) != 0;
  std::printf("OK device=%s rgb-hq=%s", id.c_str(), enabled ? "on" : "off");
  if (action != "rgb-hq-status") {
    std::printf("; reopen virtual-camera clients to renegotiate resolution");
  }
  std::putchar('\n');
  return 0;
}
// End-to-end camera self-test through the same ScannerPort contract used by
// SynKinect Studio and the virtual cameras: subscribe, then count complete
// frames per stream and report calibration and motion metadata.
uint32_t probe_mask(const std::string& text) {
  if (text == "rgb") return scanner::StreamRgb;
  if (text == "rgb-hq") return scanner::StreamRgbHighQuality;
  if (text == "ir") return scanner::StreamInfrared;
  if (text == "depth") return scanner::StreamDepth;
  if (text == "rgb+depth") return scanner::StreamRgb | scanner::StreamDepth;
  if (text == "ir+depth") return scanner::StreamInfrared | scanner::StreamDepth;
  return 0;
}

const char* stream_name(scanner::StreamMode mode) {
  switch (mode) {
    case scanner::StreamMode::Rgb: return "rgb";
    case scanner::StreamMode::RgbHighQuality: return "rgb-hq";
    case scanner::StreamMode::Infrared: return "ir";
    case scanner::StreamMode::Depth: return "depth";
  }
  return "?";
}

int handle_probe(const std::string& requested_id, uint32_t mask, int seconds) {
  std::string id;
  std::string endpoint;
  if (!resolve_camera(requested_id, id, endpoint)) {
    std::fprintf(stderr, "No Ready Kinect camera instance is available for device=%s.\n",
                 requested_id.empty() ? "auto" : requested_id.c_str());
    return 3;
  }
  const int fd = unixio::connect_socket(endpoint);
  if (fd < 0) {
    std::perror("camera");
    return 3;
  }
  (void)unixio::set_io_timeout(fd, 5000);
  scanner::Request request{};
  request.streamMask = mask;
  scanner::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) || !unixio::read_exact(fd, &reply, sizeof(reply))) {
    std::puts("probe: no ScannerPort reply");
    ::close(fd);
    return 4;
  }
  std::printf("probe device=%s mask=0x%x result=%d accepted=0x%x depth_calibration=%s capabilities=0x%x\n",
              id.c_str(), mask, reply.result, reply.acceptedMask,
              reply.depthCalibrationValid ? "valid" : "UNAVAILABLE", reply.capabilities);
  if (reply.result < 0) {
    std::printf("probe: subscription refused (%s)\n", std::strerror(-reply.result));
    ::close(fd);
    return 5;
  }

  uint64_t frames[4]{};
  uint64_t bad[4]{};
  uint64_t motion_frames = 0;
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  const uint64_t deadline = unixio::monotonic_ms() + static_cast<uint64_t>(seconds) * 1000u;
  while (unixio::monotonic_ms() < deadline) {
    scanner::FrameHeader header{};
    if (!unixio::read_exact(fd, &header, sizeof(header))) break;
    if (header.magic != scanner::kFrameMagic || header.payloadBytes > payload.size() ||
        !unixio::read_exact(fd, payload.data(), header.payloadBytes)) break;
    const auto index = static_cast<std::size_t>(header.mode);
    if (index >= 4) continue;
    const uint32_t expected = header.mode == scanner::StreamMode::Rgb ? scanner::kRgbRawPayloadBytes :
        header.mode == scanner::StreamMode::RgbHighQuality ? scanner::kRgbHqPayloadBytes :
        header.mode == scanner::StreamMode::Infrared ? scanner::kIrRaw10PayloadBytes :
        scanner::kDepthRaw11PackedPayloadBytes;
    if (header.payloadBytes == expected) ++frames[index]; else ++bad[index];
    if (header.motion.flags & scanner::MotionTiltValid) ++motion_frames;
  }
  ::close(fd);

  int missing = 0;
  for (const auto mode : {scanner::StreamMode::Rgb, scanner::StreamMode::RgbHighQuality,
                          scanner::StreamMode::Infrared, scanner::StreamMode::Depth}) {
    const auto index = static_cast<std::size_t>(mode);
    if ((mask & (1u << index)) == 0) continue;
    std::printf("  %-7s %llu frames (%.1f fps)%s\n", stream_name(mode),
                static_cast<unsigned long long>(frames[index]), static_cast<double>(frames[index]) / seconds,
                bad[index] ? " WITH WRONG PAYLOAD SIZES" : "");
    if (frames[index] == 0) ++missing;
  }
  std::printf("  motion  %llu frames carried a valid accelerometer/tilt sample\n",
              static_cast<unsigned long long>(motion_frames));
  return missing ? 6 : 0;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    usage();
    return 2;
  }

  int index = 1;
  std::string device;
  if (index + 1 < argc && std::string(argv[index]) == "--device") {
    device = argv[index + 1];
    index += 2;
  }
  if (index >= argc) {
    usage();
    return 2;
  }

  const std::string action = argv[index++];
  if (is_rgb_hq_action(action)) return handle_rgb_hq(device, action);
  if (action == "probe") {
    const uint32_t mask = probe_mask(index < argc ? argv[index] : "rgb+depth");
    const int seconds = index + 1 < argc ? std::clamp(std::atoi(argv[index + 1]), 1, 60) : 5;
    if (mask == 0) {
      usage();
      return 2;
    }
    return handle_probe(device, mask, seconds);
  }

  control::Request request{};
  copy_id(request.deviceId, sizeof(request.deviceId), device);
  if (action == "ping") {
    request.command = control::Command::Ping;
  } else if (action == "status") {
    request.command = control::Command::Status;
  } else if (action == "tilt" && index < argc) {
    request.command = control::Command::Tilt;
    request.value = std::atoi(argv[index]);
  } else if (action == "led" && index < argc) {
    const int value = led_value(argv[index]);
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

  const int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) {
    std::perror("broker");
    return 3;
  }

  (void)unixio::set_io_timeout(fd, 3000);
  control::Reply reply{};
  const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
      unixio::read_exact(fd, &reply, sizeof(reply));
  ::close(fd);
  if (!ok) {
    std::puts("broker I/O failed");
    return 4;
  }
  if (reply.result < 0) {
    std::printf("ERROR %d (%s)\n", reply.result, std::strerror(-reply.result));
    return 5;
  }

  if (action == "status") {
    std::printf(
        "OK device=%s accel=%d,%d,%d tilt=%.1f state=%u\n",
        device.empty() ? "auto" : device.c_str(),
        reply.accelX,
        reply.accelY,
        reply.accelZ,
        reply.tiltTenths / 10.0,
        reply.state);
  } else if (action == "tilt") {
    const bool verified = (reply.state & control::kStateTiltVerified) != 0;
    std::printf("OK device=%s requested=%d actual=%.1f verified=%d\n",
                device.empty() ? "auto" : device.c_str(), request.value,
                reply.tiltTenths / 10.0, verified ? 1 : 0);
  } else {
    std::puts("OK");
  }
  return 0;
}
