#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

#include "remold/device_registry.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
void usage() {
  std::puts(
      "usage: kinect360-remoldctl [--device DEVICE_ID] "
      "ping|status|tilt DEG|led MODE|rgb-hq-status|rgb-hq-on|rgb-hq-off|rgb-hq-toggle");
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
