#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

#include "remold/config.hpp"
#include "remold/device_registry.hpp"
#include "remold/hardware_profile.hpp"
#include "remold/protocol.hpp"
#include "remold/raw_sensor.hpp"
#include "remold/smart_tilt.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {

std::atomic<bool> run{true};

void stop_handler(int) {
  run = false;
}

constexpr uint32_t kClientUsageEvent = V4L2_EVENT_PRIVATE_START + 0x08E00000u + 1u;
constexpr int kFirstVideo = 42;
constexpr int kVideoSlots = 8;
constexpr int kReconnectGraceSeconds = 30;
constexpr const char* kSlotMapPath = "/var/lib/kinect360-remold/v4l2-map.tsv";

int xioctl(int fd, unsigned long request, void* argument) {
  int result;
  do {
    result = ::ioctl(fd, request, argument);
  } while (result < 0 && errno == EINTR);
  return result;
}

bool write_frame(int fd, const uint8_t* data, size_t size) {
  size_t written = 0;
  while (written < size) {
    const ssize_t count = ::write(fd, data + written, size - written);
    if (count < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (count == 0) return false;
    written += static_cast<size_t>(count);
  }
  return true;
}

std::vector<uint8_t> black_yuyv_frame(uint32_t width, uint32_t height) {
  std::vector<uint8_t> frame(static_cast<size_t>(width) * height * 2, 0x80);
  for (size_t i = 0; i < frame.size(); i += 4) {
    frame[i] = 16;
    frame[i + 1] = 128;
    frame[i + 2] = 16;
    frame[i + 3] = 128;
  }
  return frame;
}

int open_v4l2(const std::string& device, uint32_t width, uint32_t height) {
  const int fd = ::open(device.c_str(), O_WRONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return -1;

  v4l2_format format{};
  format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  format.fmt.pix.width = width;
  format.fmt.pix.height = height;
  format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
  format.fmt.pix.field = V4L2_FIELD_NONE;
  format.fmt.pix.bytesperline = width * 2;
  format.fmt.pix.sizeimage = width * height * 2;
  if (xioctl(fd, VIDIOC_S_FMT, &format) < 0) {
    ::close(fd);
    return -1;
  }

  const auto black = black_yuyv_frame(width, height);
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (write_frame(fd, black.data(), black.size())) return fd;
    if (errno != EAGAIN && errno != EWOULDBLOCK) break;
    unixio::retry_sleep(25);
  }

  ::close(fd);
  return -1;
}

bool subscribe_client_events(int fd) {
  v4l2_event_subscription subscription{};
  subscription.type = kClientUsageEvent;
  subscription.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
  return xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &subscription) == 0;
}

bool dequeue_client_state(int fd, bool& active) {
  v4l2_event event{};
  if (xioctl(fd, VIDIOC_DQEVENT, &event) < 0 || event.type != kClientUsageEvent) {
    return false;
  }

  uint32_t clientCount = 0;
  std::memcpy(&clientCount, event.u.data, sizeof(clientCount));
  active = clientCount != 0;
  return true;
}

int subscribe_rgb(const std::string& endpoint, bool high_quality) {
  if (endpoint.empty()) return -1;

  const int fd = unixio::connect_socket(endpoint);
  if (fd < 0) return -1;

  scanner::Request request{};
  request.command = scanner::Command::SubscribeStreams;
  request.streamMask = high_quality ? scanner::StreamRgbHighQuality : scanner::StreamRgb;
  scanner::Reply reply{};
  const bool accepted = unixio::write_all(fd, &request, sizeof(request)) &&
      unixio::read_exact(fd, &reply, sizeof(reply)) &&
      reply.result >= 0 &&
      reply.acceptedMask == request.streamMask;
  if (!accepted) {
    ::close(fd);
    return -1;
  }

  return fd;
}

bool query_rgb_hq(const std::string& endpoint, bool& enabled) {
  enabled = false;
  if (endpoint.empty()) return false;
  const int fd = unixio::connect_socket(endpoint);
  if (fd < 0) return false;
  scanner::Request request{};
  request.command = scanner::Command::GetDriverSettings;
  request.streamMask = 0;
  scanner::Reply reply{};
  const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
      unixio::read_exact(fd, &reply, sizeof(reply)) && reply.result == 0;
  ::close(fd);
  if (!ok) return false;
  enabled = (reply.acceptedMask & scanner::DriverSettingRgbHighQuality) != 0;
  return true;
}

int request_tilt(const std::string& id, int degrees) {
  const int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) return -1;

  control::Request request{};
  request.command = control::Command::Tilt;
  request.value = degrees;
  std::strncpy(request.deviceId, id.c_str(), sizeof(request.deviceId) - 1);

  control::Reply response{};
  const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
      unixio::read_exact(fd, &response, sizeof(response));
  ::close(fd);
  return ok ? response.result : -EIO;
}

class FaceTracker {
 public:
  explicit FaceTracker(const Config& config) {
    std::vector<std::string> candidates;
    const std::string configured = config.get("smart_tilt.face_cascade", "");
    if (!configured.empty()) candidates.push_back(configured);

    candidates.push_back(
        "/usr/share/opencv4/haarcascades/haarcascade_frontalface_default.xml");
    candidates.push_back(
        "/usr/share/opencv/haarcascades/haarcascade_frontalface_default.xml");

    for (const auto& path : candidates) {
      if (cascade_.load(path)) {
        ready_ = true;
        break;
      }
    }
  }

  // Group target, the Windows virtual camera default: the common bounding box
  // of every detected face, in frame pixels. RGB HQ frames are analysed at
  // half resolution so detection keeps the face period.
  bool detect(const std::vector<uint8_t>& rgb, uint32_t width, uint32_t height, smart_tilt::FaceBox& box) {
    box = smart_tilt::FaceBox{};
    if (!ready_ || rgb.size() < static_cast<size_t>(width) * height * 3u) return false;

    cv::Mat image(
        static_cast<int>(height),
        static_cast<int>(width),
        CV_8UC3,
        const_cast<uint8_t*>(rgb.data()));
    const int scale = width > scanner::kWidth ? 2 : 1;
    cv::Mat gray;
    cv::cvtColor(image, gray, cv::COLOR_RGB2GRAY);
    if (scale > 1) cv::resize(gray, gray, cv::Size(), 1.0 / scale, 1.0 / scale, cv::INTER_AREA);
    cv::equalizeHist(gray, gray);

    std::vector<cv::Rect> faces;
    cascade_.detectMultiScale(gray, faces, 1.15, 4, 0, cv::Size(48, 48));
    if (faces.empty()) return false;

    cv::Rect group = faces.front();
    for (const auto& face : faces) group |= face;
    box.valid = true;
    box.centerX = (group.x + group.width / 2) * scale;
    box.centerY = (group.y + group.height / 2) * scale;
    box.width = group.width * scale;
    box.height = group.height * scale;
    return true;
  }

 private:
  cv::CascadeClassifier cascade_;
  bool ready_ = false;
};

smart_tilt::Policy smart_tilt_policy(const Config& config) {
  smart_tilt::Policy policy;
  policy.tiltMinDegrees = hardware::kTiltMinDegrees;
  policy.tiltMaxDegrees = hardware::kTiltMaxDegrees;
  policy.startupTiltDegrees = std::clamp(config.get_int("tilt.startup", policy.startupTiltDegrees),
                                         hardware::kTiltMinDegrees, hardware::kTiltMaxDegrees);
  policy.faceVerticalDeadZonePixels =
      config.get_int("smart_tilt.face_vertical_dead_zone_pixels", policy.faceVerticalDeadZonePixels);
  policy.faceErrorFilterAlpha = config.get_double("smart_tilt.face_error_filter_alpha", policy.faceErrorFilterAlpha);
  policy.accelFilterAlpha = config.get_double("smart_tilt.accel_filter_alpha", policy.accelFilterAlpha);
  policy.accelCorrectionFilterAlpha =
      config.get_double("smart_tilt.accel_correction_filter_alpha", policy.accelCorrectionFilterAlpha);
  policy.minCommandDeltaDegrees = config.get_int("smart_tilt.min_command_delta_degrees", policy.minCommandDeltaDegrees);
  policy.motorSettleToleranceDegrees =
      config.get_int("smart_tilt.motor_settle_tolerance_degrees", policy.motorSettleToleranceDegrees);
  policy.motorSettleMs = static_cast<uint64_t>(
      std::max(0, config.get_int("smart_tilt.motor_settle_ms", static_cast<int>(policy.motorSettleMs))));
  policy.commandPeriodMs = static_cast<uint64_t>(
      std::clamp(config.get_int("smart_tilt.command_period_ms", static_cast<int>(policy.commandPeriodMs)), 60, 500));
  return policy;
}

smart_tilt::Settings smart_tilt_settings(const Config& config, const smart_tilt::Policy& policy) {
  smart_tilt::Settings settings;
  settings.autoFraming = config.get_bool("smart_tilt.auto_framing", settings.autoFraming);
  settings.trackingSpeed = std::clamp(config.get_int("smart_tilt.tracking_speed", settings.trackingSpeed), 1, 100);
  settings.stabilization = config.get_bool("smart_tilt.stabilization", settings.stabilization);
  settings.stabilizationStrength =
      std::clamp(config.get_int("smart_tilt.stabilization_strength", settings.stabilizationStrength), 1, 100);
  settings.autoCenter = config.get_bool("smart_tilt.auto_center", settings.autoCenter);
  settings.manualTiltDegrees = policy.startupTiltDegrees;
  return settings;
}

smart_tilt::FramingSettings framing_settings(const Config& config) {
  smart_tilt::FramingSettings settings;
  settings.deadZonePercent = std::clamp(config.get_int("smart_tilt.dead_zone_percent", settings.deadZonePercent), 4, 35);
  settings.digitalZoomLimitPercent =
      std::clamp(config.get_int("smart_tilt.digital_zoom_limit_percent", settings.digitalZoomLimitPercent), 100, 200);
  return settings;
}

uint32_t rgb_width(bool high_quality) {
  return high_quality ? scanner::kRgbHqWidth : scanner::kWidth;
}

uint32_t rgb_height(bool high_quality) {
  return high_quality ? scanner::kRgbHqHeight : scanner::kHeight;
}

smart_tilt::Motion to_smart_tilt_motion(const scanner::MotionSample& sample) {
  smart_tilt::Motion motion;
  motion.accelValid = (sample.flags & scanner::MotionAccelerometerValid) != 0;
  motion.tiltValid = (sample.flags & scanner::MotionTiltValid) != 0;
  motion.accelX = sample.accelX;
  motion.accelY = sample.accelY;
  motion.accelZ = sample.accelZ;
  motion.tiltTenths = sample.tiltTenths;
  motion.tickMs = sample.tickMs;
  return motion;
}

class VirtualCameraWorker {
 public:
  VirtualCameraWorker(std::string id, std::string node, const Config& config)
      : id_(std::move(id)),
        node_(std::move(node)),
        tracker_(config),
        controller_(smart_tilt_policy(config)),
        settings_(smart_tilt_settings(config, controller_.GetPolicy())),
        framing_settings_(framing_settings(config)),
        face_period_ms_(static_cast<uint64_t>(std::clamp(config.get_int("smart_tilt.face_period_ms", 40), 20, 200))) {}

  ~VirtualCameraWorker() {
    stop();
  }

  void start() {
    if (running_.exchange(true)) return;
    thread_ = std::thread([this] { loop(); });
  }

  void stop() {
    if (!running_.exchange(false)) return;
    if (thread_.joinable()) thread_.join();
  }

  void update_camera(std::string endpoint) {
    std::lock_guard<std::mutex> guard(mu_);
    camera_endpoint_ = std::move(endpoint);
    last_seen_ = std::chrono::steady_clock::now();
  }

  void mark_reconnecting() {
    std::lock_guard<std::mutex> guard(mu_);
    camera_endpoint_.clear();
  }

  bool expired(std::chrono::steady_clock::time_point now) const {
    std::lock_guard<std::mutex> guard(mu_);
    return camera_endpoint_.empty() &&
        now - last_seen_ >= std::chrono::seconds(kReconnectGraceSeconds);
  }

 private:
  std::string camera_endpoint() const {
    std::lock_guard<std::mutex> guard(mu_);
    return camera_endpoint_;
  }

  // Logs state transitions only, so the journal stays readable.
  void report(const std::string& state) {
    if (state == last_report_) return;
    last_report_ = state;
    std::fprintf(stderr, "v4l2 %s: %s\n", id_.c_str(), state.c_str());
  }

  // Tilt, stabilization, face tracking and digital framing run only while a
  // V4L2 client consumes frames, exactly like the Windows virtual camera.
  // Activation and deactivation reset the controller and the framing and never
  // move the motor by themselves.
  void set_consumer_active(bool active) {
    if (active == consumer_active_) return;
    consumer_active_ = active;
    controller_.Reset(unixio::monotonic_ms());
    framing_ = smart_tilt::Framing{};
    last_step_ms_ = 0;
  }

  // Same cadence, control law and framing as the Windows SmartEngine: one
  // step per face period, fed by the frame's motion sample.
  void smart_step(const std::vector<uint8_t>& rgb, uint32_t width, uint32_t height,
                  const scanner::MotionSample& sample) {
    const uint64_t now = unixio::monotonic_ms();
    if (last_step_ms_ != 0 && now - last_step_ms_ < face_period_ms_) return;
    last_step_ms_ = now;

    smart_tilt::FaceBox box;
    if (settings_.autoFraming) tracker_.detect(rgb, width, height, box);
    smart_tilt::Face face;
    face.valid = box.valid;
    face.centerY = box.centerY;
    face.frameHeight = static_cast<int>(height);
    const auto step = controller_.Update(now, to_smart_tilt_motion(sample), face, settings_);
    if (settings_.autoFraming) {
      framing_ = smart_tilt::UpdateFraming(framing_, box, static_cast<int>(width), static_cast<int>(height),
                                           step, settings_.trackingSpeed, framing_settings_);
    }
    if (step.command && request_tilt(id_, step.commandDegrees) == 0) {
      controller_.CommandAccepted(step.commandDegrees, now);
    }
  }

  // Converts one sensor frame, applies the digital framing and scales it to
  // the output format.
  bool publish(int output, const std::vector<uint8_t>& payload, const scanner::FrameHeader& header,
               uint32_t output_width, uint32_t output_height) {
    const uint32_t width = header.width;
    const uint32_t height = header.height;
    rawsensor::bayer_grbg_to_rgb24(payload.data(), static_cast<int>(width), static_cast<int>(height), rgb_);
    smart_step(rgb_, width, height, header.motion);
    const auto crop = smart_tilt::FramingCrop(framing_, width, height);
    const bool direct = crop.width == width && crop.height == height &&
        width == output_width && height == output_height;
    if (direct) {
      rawsensor::rgb24_to_yuyv(rgb_.data(), static_cast<int>(width), static_cast<int>(height), yuyv_);
    } else {
      rawsensor::crop_scale_rgb24(rgb_.data(), static_cast<int>(width),
                                  static_cast<int>(crop.x), static_cast<int>(crop.y),
                                  static_cast<int>(crop.width), static_cast<int>(crop.height),
                                  static_cast<int>(output_width), static_cast<int>(output_height), framed_);
      rawsensor::rgb24_to_yuyv(framed_.data(), static_cast<int>(output_width), static_cast<int>(output_height), yuyv_);
    }
    return write_frame(output, yuyv_.data(), yuyv_.size()) || errno == EAGAIN;
  }

  static std::string size_text(uint32_t width, uint32_t height) {
    return std::to_string(width) + "x" + std::to_string(height);
  }

  // The virtual camera always carries the Kinect RGB stream in the RGB mode
  // selected by the driver setting (RGB or RGB HQ). The output format follows
  // the mode whenever no V4L2 client holds the device. While a client streams,
  // it keeps its negotiated format: a mode change resubscribes the sensor at
  // the new mode and frames are scaled to the open format, like the Windows
  // virtual camera does for an open Media Foundation stream.
  void loop() {
    std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);

    while (running_ && run) {
      bool sensor_hq = false;
      if (!query_rgb_hq(camera_endpoint(), sensor_hq)) {
        unixio::retry_sleep(250);
        continue;
      }
      const bool output_hq = sensor_hq;
      const uint32_t output_width = rgb_width(output_hq);
      const uint32_t output_height = rgb_height(output_hq);

      const int output = open_v4l2(node_, output_width, output_height);
      if (output < 0) {
        report("cannot open " + node_ + " as a " + size_text(output_width, output_height) +
               " YUYV output: " + std::strerror(errno));
        unixio::retry_sleep(750);
        continue;
      }
      report("publishing " + node_ + " at " + size_text(output_width, output_height));

      if (!subscribe_client_events(output)) {
        std::fprintf(
            stderr,
            "v4l2: Kinect Xbox 360 Remold requires v4l2loopback >= 0.15.0 "
            "client-usage events\n");
        ::close(output);
        unixio::retry_sleep(1000);
        continue;
      }

      bool active = false;
      int scanner_fd = -1;
      uint64_t last_settings_check = 0;
      bool reformat = false;

      while (running_ && run) {
        set_consumer_active(active);
        if (!active && sensor_hq != output_hq) {
          reformat = true;
          break;
        }
        if (active && scanner_fd < 0) {
          scanner_fd = subscribe_rgb(camera_endpoint(), sensor_hq);
          if (scanner_fd < 0) {
            report("a V4L2 client is open but the Kinect RGB stream could not be subscribed");
            unixio::retry_sleep(250);
          } else {
            report(std::string("streaming Kinect ") + (sensor_hq ? "RGB HQ" : "RGB") + " to " + node_ +
                   " at " + size_text(output_width, output_height));
          }
        } else if (!active && scanner_fd >= 0) {
          ::close(scanner_fd);
          scanner_fd = -1;
          report("no V4L2 client; Kinect RGB released");
        }

        const uint64_t now = unixio::monotonic_ms();
        if (now - last_settings_check >= 750) {
          last_settings_check = now;
          bool current_hq = sensor_hq;
          if (query_rgb_hq(camera_endpoint(), current_hq) && current_hq != sensor_hq) {
            sensor_hq = current_hq;
            if (scanner_fd >= 0) {
              ::close(scanner_fd);
              scanner_fd = -1;
            }
            continue;
          }
        }

        pollfd fds[2]{};
        fds[0].fd = output;
        fds[0].events = POLLPRI;
        fds[1].fd = scanner_fd;
        fds[1].events = scanner_fd >= 0 ? POLLIN : 0;

        const int poll_result = ::poll(fds, 2, 500);
        if (poll_result < 0) {
          if (errno == EINTR) continue;
          break;
        }

        if (fds[0].revents & POLLPRI) {
          bool state = active;
          while (dequeue_client_state(output, state)) active = state;
        }

        if (scanner_fd >= 0 && (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL))) {
          ::close(scanner_fd);
          scanner_fd = -1;
          continue;
        }
        if (scanner_fd < 0 || !(fds[1].revents & POLLIN)) continue;

        scanner::FrameHeader header{};
        const bool frame_read = unixio::read_exact(scanner_fd, &header, sizeof(header)) &&
            header.payloadBytes <= payload.size() &&
            unixio::read_exact(scanner_fd, payload.data(), header.payloadBytes);
        if (!frame_read) {
          ::close(scanner_fd);
          scanner_fd = -1;
          continue;
        }

        const auto expected_mode = sensor_hq ? scanner::StreamMode::RgbHighQuality : scanner::StreamMode::Rgb;
        const uint32_t expected_bytes = sensor_hq ? scanner::kRgbHqPayloadBytes : scanner::kRgbRawPayloadBytes;
        if (header.mode != expected_mode ||
            header.pixelFormat != scanner::PixelFormat::BayerGrbg8 ||
            header.width != rgb_width(sensor_hq) || header.height != rgb_height(sensor_hq) ||
            header.payloadBytes != expected_bytes) {
          continue;
        }

        if (!publish(output, payload, header, output_width, output_height)) break;
      }

      if (scanner_fd >= 0) ::close(scanner_fd);
      set_consumer_active(false);
      ::close(output);
      unixio::retry_sleep(reformat ? 50 : 300);
    }
  }

  std::string id_;
  std::string node_;
  mutable std::mutex mu_;
  std::string camera_endpoint_;
  std::chrono::steady_clock::time_point last_seen_ = std::chrono::steady_clock::now();
  std::atomic<bool> running_{false};
  std::thread thread_;
  FaceTracker tracker_;
  smart_tilt::Controller controller_;
  smart_tilt::Settings settings_;
  smart_tilt::FramingSettings framing_settings_;
  smart_tilt::Framing framing_;
  std::vector<uint8_t> rgb_;
  std::vector<uint8_t> framed_;
  std::vector<uint8_t> yuyv_;
  uint64_t face_period_ms_ = 40;
  uint64_t last_step_ms_ = 0;
  bool consumer_active_ = false;
  std::string last_report_;
};

std::map<std::string, int> load_slots() {
  std::map<std::string, int> slots;
  std::ifstream in(kSlotMapPath);
  std::string id;
  int slot = -1;
  while (in >> id >> slot) {
    if (slot >= 0 && slot < kVideoSlots) slots[id] = slot;
  }
  return slots;
}

void save_slots(const std::map<std::string, int>& slots) {
  std::error_code ec;
  std::filesystem::create_directories("/var/lib/kinect360-remold", ec);
  if (ec) return;

  const std::string temporary = std::string(kSlotMapPath) + ".tmp";
  std::ofstream out(temporary, std::ios::trunc);
  if (!out) return;
  for (const auto& entry : slots) out << entry.first << '\t' << entry.second << '\n';
  out.flush();
  if (!out) {
    std::filesystem::remove(temporary, ec);
    return;
  }
  out.close();

  std::filesystem::rename(temporary, kSlotMapPath, ec);
  if (ec) std::filesystem::remove(temporary, ec);
}

int allocate_slot(const std::map<std::string, int>& slots) {
  for (int slot = 0; slot < kVideoSlots; ++slot) {
    const bool used = std::any_of(
        slots.begin(),
        slots.end(),
        [slot](const auto& entry) { return entry.second == slot; });
    if (!used) return slot;
  }
  return -1;
}

void write_virtual_map(
    const std::map<std::string, int>& slots,
    const std::map<std::string, std::unique_ptr<VirtualCameraWorker>>& workers) {
  std::error_code ec;
  std::filesystem::create_directories(kRuntimeDir, ec);
  if (ec) return;

  const std::string temporary = std::string(kVirtualCameraMap) + ".tmp";
  std::ofstream out(temporary, std::ios::trunc);
  if (!out) return;
  out << "# device-id\tvideo-node\n";

  for (const auto& entry : workers) {
    const auto slot = slots.find(entry.first);
    if (slot != slots.end()) {
      out << entry.first << "\t/dev/video" << (kFirstVideo + slot->second) << '\n';
    }
  }
  out.flush();
  if (!out) {
    std::filesystem::remove(temporary, ec);
    return;
  }
  out.close();

  std::filesystem::rename(temporary, kVirtualCameraMap, ec);
  if (ec) std::filesystem::remove(temporary, ec);
}

}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  auto slots = load_slots();
  std::map<std::string, std::unique_ptr<VirtualCameraWorker>> workers;

  while (run) {
    const auto now = std::chrono::steady_clock::now();
    const auto deviceList = devices::read_manifest();
    std::map<std::string, devices::Device> current;
    for (const auto& device : deviceList) current[device.id] = device;

    for (const auto& entry : current) {
      auto worker = workers.find(entry.first);
      if (worker == workers.end()) {
        int slot = -1;
        const auto existingSlot = slots.find(entry.first);
        if (existingSlot != slots.end()) {
          slot = existingSlot->second;
        } else {
          slot = allocate_slot(slots);
        }
        if (slot < 0) continue;

        slots[entry.first] = slot;
        auto instance = std::make_unique<VirtualCameraWorker>(
            entry.first,
            "/dev/video" + std::to_string(kFirstVideo + slot),
            config);
        instance->start();
        worker = workers.emplace(entry.first, std::move(instance)).first;
      }

      if (!entry.second.camera.empty()) {
        worker->second->update_camera(entry.second.camera);
      } else {
        worker->second->mark_reconnecting();
      }
    }

    for (auto worker = workers.begin(); worker != workers.end();) {
      if (current.count(worker->first) == 0) worker->second->mark_reconnecting();
      if (worker->second->expired(now)) {
        worker->second->stop();
        slots.erase(worker->first);
        worker = workers.erase(worker);
      } else {
        ++worker;
      }
    }

    save_slots(slots);
    write_virtual_map(slots, workers);
    for (int i = 0; i < 10 && run; ++i) unixio::retry_sleep(100);
  }

  for (auto& worker : workers) worker.second->stop();
  ::unlink(kVirtualCameraMap);
  return 0;
}
