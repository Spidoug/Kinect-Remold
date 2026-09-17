#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "remold/config.hpp"
#include "remold/protocol.hpp"
#include "remold/raw_sensor.hpp"
#include "remold/device_registry.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
void stop_handler(int) { run = false; }

constexpr const char* kVirtualCameraLabel = "Kinect Xbox 360 Camera";
constexpr const char* kRuntimeV4l2Path = "/run/kinect360-remold/v4l2-device";

int xioctl(int fd, unsigned long request, void* arg) {
  int rc;
  do rc = ::ioctl(fd, request, arg); while (rc < 0 && errno == EINTR);
  return rc;
}

std::string trim(std::string value) {
  while (!value.empty() && (value.back() == '\n' || value.back() == '\r' || value.back() == ' ' || value.back() == '\t')) value.pop_back();
  std::size_t first = 0;
  while (first < value.size() && (value[first] == ' ' || value[first] == '\t')) ++first;
  return value.substr(first);
}

std::string read_first_line(const std::filesystem::path& path) {
  std::ifstream in(path);
  std::string line;
  if (in && std::getline(in, line)) return trim(line);
  return {};
}

std::string find_device_by_label() {
  namespace fs = std::filesystem;
  std::error_code ec;
  const fs::path root("/sys/class/video4linux");
  if (!fs::exists(root, ec)) return {};
  for (const auto& entry : fs::directory_iterator(root, ec)) {
    if (ec) break;
    if (read_first_line(entry.path() / "name") != kVirtualCameraLabel) continue;
    const std::string node = entry.path().filename().string();
    const fs::path device = fs::path("/dev") / node;
    if (fs::exists(device, ec)) return device.string();
  }
  return {};
}

bool is_remold_v4l2_node(const std::string& device) {
  if (device.empty()) return false;
  const std::filesystem::path sys = std::filesystem::path("/sys/class/video4linux") /
                                    std::filesystem::path(device).filename() / "name";
  return read_first_line(sys) == kVirtualCameraLabel;
}

std::string resolve_v4l2_device(const std::string& configured) {
  namespace fs = std::filesystem;
  std::error_code ec;

  // The privileged helper records the actual node after handling collisions
  // (for example /dev/video42 already belongs to a physical webcam). Prefer
  // that runtime decision, but only when the node still carries our exact
  // label. This prevents a recycled video number from being opened later.
  const std::string runtime = read_first_line(kRuntimeV4l2Path);
  if (!runtime.empty() && fs::exists(runtime, ec) && is_remold_v4l2_node(runtime)) return runtime;

  const std::string labeled = find_device_by_label();
  if (!labeled.empty()) return labeled;

  // A configured path is a preference, not authority: never write YUYV frames
  // into an unrelated physical/virtual camera that happens to own that number.
  if (!configured.empty() && fs::exists(configured, ec) && is_remold_v4l2_node(configured)) return configured;
  return {};
}

void remember_v4l2_device(const std::string& device) {
  namespace fs = std::filesystem;
  std::error_code ec;
  fs::create_directories("/run/kinect360-remold", ec);
  std::ofstream out(std::string(kRuntimeV4l2Path) + ".tmp", std::ios::trunc);
  if (!out) return;
  out << device << '\n';
  out.close();
  fs::rename(std::string(kRuntimeV4l2Path) + ".tmp", kRuntimeV4l2Path, ec);
}

bool write_frame(int fd, const uint8_t* data, size_t size) {
  size_t done = 0;
  while (done < size && run.load()) {
    const ssize_t n = ::write(fd, data + done, size - done);
    if (n > 0) {
      done += static_cast<size_t>(n);
      continue;
    }
    if (n == 0) { errno = EIO; return false; }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      pollfd pfd{fd, POLLOUT, 0};
      const int prc = ::poll(&pfd, 1, 100);
      if (prc > 0 && (pfd.revents & POLLOUT)) continue;
      errno = EAGAIN;
      return false;
    }
    return false;
  }
  return done == size;
}

std::vector<uint8_t> make_black_frame() {
  std::vector<uint8_t> black(scanner::kWidth * scanner::kHeight * 2, 0x80);
  for (size_t i = 0; i + 3 < black.size(); i += 4) {
    black[i] = 16;
    black[i + 1] = 128;
    black[i + 2] = 16;
    black[i + 3] = 128;
  }
  return black;
}

int open_v4l2(const std::string& device) {
  // Revalidate at the last responsible moment. /dev/videoN numbers are reusable;
  // a stale runtime file must never redirect Remold output into a physical camera.
  if (!is_remold_v4l2_node(device)) { errno = ENODEV; return -1; }
  int fd = ::open(device.c_str(), O_WRONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return -1;

  v4l2_capability caps{};
  if (xioctl(fd, VIDIOC_QUERYCAP, &caps) < 0) {
    ::close(fd);
    return -1;
  }

  v4l2_format format{};
  format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  format.fmt.pix.width = scanner::kWidth;
  format.fmt.pix.height = scanner::kHeight;
  format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
  format.fmt.pix.field = V4L2_FIELD_NONE;
  format.fmt.pix.bytesperline = scanner::kWidth * 2;
  format.fmt.pix.sizeimage = scanner::kWidth * scanner::kHeight * 2;
  if (xioctl(fd, VIDIOC_S_FMT, &format) < 0 ||
      format.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
    ::close(fd);
    errno = EINVAL;
    return -1;
  }

  v4l2_streamparm parm{};
  parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  parm.parm.output.timeperframe.numerator = 1;
  parm.parm.output.timeperframe.denominator = 30;
  (void)xioctl(fd, VIDIOC_S_PARM, &parm);

  // v4l2loopback exclusive_caps=1 initially advertises only OUTPUT. Keeping
  // the producer open exposes the node as CAPTURE for desktop/webcam
  // applications. A consumer is NOT required here. Prime one neutral frame when
  // the loopback accepts write() immediately, but EAGAIN must never make us drop
  // the producer and hide the virtual camera again.
  remember_v4l2_device(device);
  const auto black = make_black_frame();
  (void)write_frame(fd, black.data(), black.size());
  return fd;
}

int subscribe_rgb(bool high_quality) {
  const std::string endpoint = devices::primary_camera_endpoint();
  if (endpoint.empty()) { errno = ENODEV; return -1; }
  const int fd = unixio::connect_socket(endpoint);
  if (fd < 0) return -1;
  scanner::Request request{};
  request.streamMask = high_quality ? scanner::StreamRgbHighQuality : scanner::StreamRgb;
  scanner::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply)) || reply.result < 0 ||
      reply.acceptedMask != request.streamMask) {
    ::close(fd);
    errno = reply.result == -ENODEV ? ENODEV : EBUSY;
    return -1;
  }
  return fd;
}

void resize_rgb24(const std::vector<uint8_t>& source, int source_width, int source_height,
                  int target_width, int target_height, std::vector<uint8_t>& target) {
  if (source_width <= 0 || source_height <= 0 || target_width <= 0 || target_height <= 0) {
    target.clear();
    return;
  }

  const std::size_t source_width_u = static_cast<std::size_t>(source_width);
  const std::size_t target_width_u = static_cast<std::size_t>(target_width);
  const std::size_t target_height_u = static_cast<std::size_t>(target_height);
  const std::size_t required_source = source_width_u * static_cast<std::size_t>(source_height) * 3u;
  if (source.size() < required_source) {
    target.clear();
    return;
  }

  target.resize(target_width_u * target_height_u * 3u);
  for (int y = 0; y < target_height; ++y) {
    const int sy = std::min(
        source_height - 1,
        static_cast<int>((static_cast<int64_t>(y) * source_height) / target_height));
    for (int x = 0; x < target_width; ++x) {
      const int sx = std::min(
          source_width - 1,
          static_cast<int>((static_cast<int64_t>(x) * source_width) / target_width));
      const std::size_t source_pixel = static_cast<std::size_t>(sy) * source_width_u +
                                       static_cast<std::size_t>(sx);
      const std::size_t target_pixel = static_cast<std::size_t>(y) * target_width_u +
                                       static_cast<std::size_t>(x);
      const std::size_t source_offset = source_pixel * 3u;
      const std::size_t target_offset = target_pixel * 3u;
      target[target_offset] = source[source_offset];
      target[target_offset + 1] = source[source_offset + 1];
      target[target_offset + 2] = source[source_offset + 2];
    }
  }
}

}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  const std::string configured_device = config.get("v4l2.device", "/dev/video42");
  const bool high_quality = config.get_bool("rgb.hq.enabled", false);
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  std::vector<uint8_t> rgb, scaled_rgb, yuyv;
  const auto black = make_black_frame();

  while (run.load()) {
    const std::string device = resolve_v4l2_device(configured_device);
    if (device.empty()) {
      std::fprintf(stderr, "v4l2: Remold virtual-camera node is not present; waiting for helper/service recovery\n");
      unixio::retry_sleep(1000);
      continue;
    }
    const int out = open_v4l2(device);
    if (out < 0) {
      std::fprintf(stderr, "v4l2: cannot open producer %s: %s\n", device.c_str(), std::strerror(errno));
      unixio::retry_sleep(1000);
      continue;
    }

    std::fprintf(stderr, "v4l2: virtual camera producer active at %s (%s)\n", device.c_str(), kVirtualCameraLabel);
    int scanner_fd = -1;
    uint64_t last_rgb_ms = 0;
    uint64_t next_subscribe_ms = 0;
    uint64_t next_black_ms = unixio::monotonic_ms() + 1000;
    bool reopen_output = false;

    while (run.load() && !reopen_output) {
      const uint64_t now = unixio::monotonic_ms();
      if (scanner_fd < 0 && now >= next_subscribe_ms) {
        scanner_fd = subscribe_rgb(high_quality);
        next_subscribe_ms = now + (scanner_fd >= 0 ? 0 : 500);
        if (scanner_fd >= 0) std::fprintf(stderr, "v4l2: RGB source connected (%s)\n", high_quality ? "HQ" : "standard");
      }

      pollfd pfd{};
      pfd.fd = scanner_fd;
      pfd.events = scanner_fd >= 0 ? POLLIN : 0;
      const int rc = ::poll(scanner_fd >= 0 ? &pfd : nullptr, scanner_fd >= 0 ? 1 : 0, 200);
      if (rc < 0 && errno != EINTR) break;

      if (scanner_fd >= 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
        ::close(scanner_fd);
        scanner_fd = -1;
        next_subscribe_ms = unixio::monotonic_ms() + 300;
      } else if (scanner_fd >= 0 && (pfd.revents & POLLIN)) {
        scanner::FrameHeader header{};
        if (!unixio::read_exact(scanner_fd, &header, sizeof(header)) ||
            header.payloadBytes > payload.size() ||
            !unixio::read_exact(scanner_fd, payload.data(), header.payloadBytes)) {
          ::close(scanner_fd);
          scanner_fd = -1;
          next_subscribe_ms = unixio::monotonic_ms() + 300;
        } else if (header.pixelFormat == scanner::PixelFormat::BayerGrbg8 &&
                   ((header.mode == scanner::StreamMode::Rgb &&
                     header.payloadBytes == scanner::kRgbRawPayloadBytes) ||
                    (header.mode == scanner::StreamMode::RgbHighQuality &&
                     header.payloadBytes == scanner::kRgbHqPayloadBytes))) {
          const int source_width = header.mode == scanner::StreamMode::RgbHighQuality
              ? static_cast<int>(scanner::kRgbHqWidth) : static_cast<int>(scanner::kWidth);
          const int source_height = header.mode == scanner::StreamMode::RgbHighQuality
              ? static_cast<int>(scanner::kRgbHqHeight) : static_cast<int>(scanner::kHeight);
          rawsensor::bayer_grbg_to_rgb24(payload.data(), source_width, source_height, rgb);
          if (source_width != static_cast<int>(scanner::kWidth) || source_height != static_cast<int>(scanner::kHeight)) {
            resize_rgb24(rgb, source_width, source_height, scanner::kWidth, scanner::kHeight, scaled_rgb);
            rawsensor::rgb24_to_yuyv(scaled_rgb.data(), scanner::kWidth, scanner::kHeight, yuyv);
          } else {
            rawsensor::rgb24_to_yuyv(rgb.data(), scanner::kWidth, scanner::kHeight, yuyv);
          }
          if (!write_frame(out, yuyv.data(), yuyv.size()) && errno != EAGAIN && errno != EWOULDBLOCK) {
            reopen_output = true;
          } else {
            last_rgb_ms = unixio::monotonic_ms();
            next_black_ms = last_rgb_ms + 1000;
          }
        }
      }

      // While the physical Kinect is disconnected, or IR/RGB-HQ temporarily
      // preempts the baseline RGB stream, keep the producer alive and publish a
      // neutral frame. This preserves CAPTURE visibility with exclusive_caps=1.
      const uint64_t after_poll = unixio::monotonic_ms();
      if (after_poll >= next_black_ms && (last_rgb_ms == 0 || after_poll - last_rgb_ms >= 900)) {
        if (!write_frame(out, black.data(), black.size()) && errno != EAGAIN && errno != EWOULDBLOCK)
          reopen_output = true;
        next_black_ms = after_poll + 1000;
      }
    }

    if (scanner_fd >= 0) ::close(scanner_fd);
    ::close(out);
    unixio::retry_sleep(300);
  }
  return 0;
}
