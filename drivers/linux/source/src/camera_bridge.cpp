#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <exception>
#include <csignal>
#include <signal.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
#include <map>
#include <memory>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <set>
#include <unordered_map>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include "remold/hardware_profile.hpp"
#include "remold/kinect_usb_camera.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
std::atomic<uint32_t> scanner_clients{0};
std::mutex scanner_clients_mutex;
std::condition_variable scanner_clients_cv;
constexpr uint32_t kMaxScannerClients = 64;
constexpr int kScannerClientTimeoutMs = 3000;
constexpr const char* kDeviceSettingsDirectory = "/var/lib/kinect360-remold/device-settings";
void stop_handler(int) { run = false; }

std::filesystem::path settings_path(const std::string& device_id) {
  return std::filesystem::path(kDeviceSettingsDirectory) / (device_id + ".conf");
}

uint32_t load_driver_settings(const std::string& device_id) {
  std::ifstream input(settings_path(device_id));
  std::string key;
  int value = 0;
  while (input >> key >> value) {
    if (key == "rgb_hq") return value != 0 ? scanner::DriverSettingRgbHighQuality : 0u;
  }
  return 0;
}

bool persist_driver_settings(const std::string& device_id, uint32_t settings) {
  namespace fs = std::filesystem;
  std::error_code ec;
  fs::create_directories(kDeviceSettingsDirectory, ec);
  if (ec) return false;

  const fs::path target = settings_path(device_id);
  const fs::path temporary = target.string() + ".tmp";
  {
    std::ofstream output(temporary, std::ios::trunc);
    if (!output) return false;
    output << "rgb_hq " << ((settings & scanner::DriverSettingRgbHighQuality) ? 1 : 0) << '\n';
    output.flush();
    if (!output) return false;
  }
  fs::rename(temporary, target, ec);
  if (ec) {
    fs::remove(temporary, ec);
    return false;
  }
  ::chmod(target.c_str(), 0644);
  return true;
}

// Upper bound of one broker Status exchange. A 1473 status transaction is a
// bulk OUT, a 104-byte reply and a trailing ACK on MI_00.
constexpr int kBrokerStatusTimeoutMs = 2000;

bool query_broker_motion(const std::string& device_id, scanner::MotionSample& motion) {
  const int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) return false;
  (void)unixio::set_io_timeout(fd, kBrokerStatusTimeoutMs);

  control::Request request{};
  request.command = control::Command::Status;
  std::strncpy(request.deviceId, device_id.c_str(), sizeof(request.deviceId) - 1);
  control::Reply reply{};
  const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
                  unixio::read_exact(fd, &reply, sizeof(reply));
  ::close(fd);
  if (!ok || reply.magic != control::kMagic || reply.version != control::kVersion ||
      reply.result != 0 || reply.transport != control::Transport::PhysicalMotor) {
    return false;
  }

  motion = {};
  motion.flags = scanner::MotionAccelerometerValid | scanner::MotionTiltValid;
  motion.accelX = reply.accelX;
  motion.accelY = reply.accelY;
  motion.accelZ = reply.accelZ;
  motion.tiltTenths = reply.tiltTenths;
  motion.tickMs = unixio::monotonic_ms();
  return true;
}

// Sole periodic owner of the broker Status request for one physical Kinect.
// Polling runs only while the camera session is online and a frame consumer is
// active. Every published frame carries the freshest sample allowed by the
// model-specific stale window.
class MotionSampler {
 public:
  MotionSampler(std::string device_id, std::function<bool()> consumer_active)
      : device_id_(std::move(device_id)), consumer_active_(std::move(consumer_active)) {}
  ~MotionSampler() { stop(); }
  MotionSampler(const MotionSampler&) = delete;
  MotionSampler& operator=(const MotionSampler&) = delete;

  void start() {
    if (thread_.joinable()) return;
    {
      std::lock_guard<std::mutex> lock(stop_mu_);
      stopping_ = false;
    }
    thread_ = std::thread([this] { loop(); });
  }

  void stop() {
    {
      std::lock_guard<std::mutex> lock(stop_mu_);
      stopping_ = true;
    }
    stop_cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    clear();
  }

  void enable(hardware::Model model) {
    const auto policy = hardware::motion_policy(model);
    poll_period_ms_.store(policy.poll_period_ms, std::memory_order_release);
    stale_after_ms_.store(policy.stale_after_ms, std::memory_order_release);
    enabled_.store(true, std::memory_order_release);
  }

  void disable() {
    enabled_.store(false, std::memory_order_release);
    clear();
  }

  scanner::MotionSample current() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (sample_.flags == 0 ||
        unixio::monotonic_ms() - sample_.tickMs > stale_after_ms_.load(std::memory_order_acquire)) return {};
    return sample_;
  }

 private:
  static constexpr uint32_t kIdleWaitMs = 50;

  void clear() {
    std::lock_guard<std::mutex> lock(mu_);
    sample_ = {};
  }

  void loop() {
    while (run.load()) {
      uint32_t wait_ms = kIdleWaitMs;
      if (enabled_.load(std::memory_order_acquire) && consumer_active_()) {
        scanner::MotionSample sample{};
        if (query_broker_motion(device_id_, sample)) {
          std::lock_guard<std::mutex> lock(mu_);
          sample_ = sample;
        }
        wait_ms = poll_period_ms_.load(std::memory_order_acquire);
      } else {
        clear();
      }
      std::unique_lock<std::mutex> lock(stop_mu_);
      if (stop_cv_.wait_for(lock, std::chrono::milliseconds(wait_ms), [this] { return stopping_ || !run.load(); })) break;
    }
  }

  std::string device_id_;
  std::function<bool()> consumer_active_;
  std::thread thread_;
  std::mutex stop_mu_;
  std::condition_variable stop_cv_;
  bool stopping_ = false;
  std::atomic<bool> enabled_{false};
  std::atomic<uint32_t> poll_period_ms_{hardware::motion_policy(hardware::Model::Unknown).poll_period_ms};
  std::atomic<uint32_t> stale_after_ms_{hardware::motion_policy(hardware::Model::Unknown).stale_after_ms};
  mutable std::mutex mu_;
  scanner::MotionSample sample_{};
};

void prepare_physical_camera(const kinectusb::DeviceInfo& info, bool startup_open) {
  // Model 1473 routes LED/tilt/accelerometer through the shared control
  // runtime while the camera transport stays independent. Keep-alive is
  // bounded and best-effort exactly like the Windows backend.
  if (info.model != hardware::Model::Xbox1473) return;

  const int attempts = startup_open ? 20 : 1;
  for (int attempt = 0; attempt < attempts && run.load(); ++attempt) {
    const int fd = unixio::connect_socket(kControlSocket);
    if (fd >= 0) {
      control::Request request{};
      request.command = control::Command::PrepareCamera;
      std::strncpy(request.deviceId, info.id.c_str(), sizeof(request.deviceId) - 1);
      control::Reply reply{};
      const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
                      unixio::read_exact(fd, &reply, sizeof(reply));
      ::close(fd);
      if (ok && reply.magic == control::kMagic && reply.version == control::kVersion && reply.result == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        return;
      }
    }
    if (attempt + 1 < attempts) std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }

  if (startup_open) {
    std::fprintf(stderr, "camera: control keep-alive unavailable for %s; continuing with the independent camera transport\n",
                 info.id.c_str());
  }
}

struct Frame {
  uint64_t seq = 0;
  uint64_t tick = 0;
  uint32_t width = scanner::kWidth;
  uint32_t height = scanner::kHeight;
  scanner::MotionSample motion{};
  std::vector<uint8_t> data;
};

class CameraHub {
 public:
  explicit CameraHub(kinectusb::DeviceInfo device_info)
      : device_info_(std::move(device_info)),
        motion_(device_info_.id, [this] { return active_clients_.load(std::memory_order_acquire) > 0; }),
        driver_settings_(load_driver_settings(device_info_.id)) {}

  ~CameraHub() { shutdown(); }

  void start() {
    if (running_.exchange(true)) return;
    motion_.start();
    worker_ = std::thread([this] { loop(); });
  }

  void shutdown() {
    if (!running_.exchange(false)) return;
    cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    close_device();
    motion_.stop();
  }

  bool online() const noexcept { return online_.load(std::memory_order_acquire); }

  // Effective settings: the persisted request minus RGB HQ when this sensor
  // proved it cannot deliver HQ frames on the current connection.
  uint32_t driver_settings() const noexcept {
    const uint32_t settings = driver_settings_.load(std::memory_order_acquire);
    return rgb_hq_unavailable_.load(std::memory_order_acquire)
        ? settings & ~scanner::DriverSettingRgbHighQuality : settings;
  }

  int set_driver_settings(uint32_t settings) {
    if ((settings & ~scanner::DriverSettingSupported) != 0) return -EINVAL;
    if (!persist_driver_settings(device_info_.id, settings)) return -EIO;
    driver_settings_.store(settings, std::memory_order_release);
    return 0;
  }

  void fill_reply(scanner::Reply& reply) {
    std::lock_guard<std::mutex> lock(dev_mu_);
    const auto calibration=device_.depth_calibration();
    reply.depthCalibrationValid=calibration.valid?1u:0u;
    reply.depthConstShift=calibration.const_shift;
    reply.depthEmitterDistance=calibration.emitter_distance;
    reply.depthReferenceDistance=calibration.reference_distance;
    reply.depthReferencePixelSize=calibration.reference_pixel_size;
    if (rgb_hq_unavailable_.load(std::memory_order_acquire)) reply.capabilities &= ~scanner::CapabilityRgbHighQuality;
  }

  int acquire(uint32_t mask, pid_t pid, int fd, uint64_t& token,
              std::shared_ptr<std::atomic<bool>>& client_alive) {
    token = 0;
    client_alive.reset();
    if (!scanner::valid_mask(mask)) return -EINVAL;
    if ((mask & scanner::StreamRgbHighQuality) && rgb_hq_unavailable_.load(std::memory_order_acquire)) return -ENOTSUP;
    std::unique_lock<std::mutex> lock(dev_mu_);
    if (!online_) return -ENODEV;

    // The newest connection from a process supersedes stale handles from that
    // process so stream-mode changes have one active owner.
    std::vector<ClientLease> superseded;
    if (pid > 0) {
      for (auto it = clients_.begin(); it != clients_.end();) {
        if (it->pid == pid) {
          superseded.push_back(*it);
          adjust_users_locked(it->mask, -1);
          it = clients_.erase(it);
        } else {
          ++it;
        }
      }
    }

    const bool wants_color = (mask & (scanner::StreamRgb | scanner::StreamRgbHighQuality)) != 0;
    if ((wants_color && ir_users_ > 0) ||
        ((mask & scanner::StreamInfrared) && (rgb_users_ + hq_rgb_users_) > 0)) {
      for (const auto& old : superseded) {
        clients_.push_back(old);
        adjust_users_locked(old.mask, +1);
      }
      return -EBUSY;
    }

    adjust_users_locked(mask, +1);
    const int rc = apply_locked();
    if (rc < 0) {
      adjust_users_locked(mask, -1);
      for (const auto& old : superseded) {
        clients_.push_back(old);
        adjust_users_locked(old.mask, +1);
      }
      return rc;
    }

    token = ++next_client_token_;
    client_alive = std::make_shared<std::atomic<bool>>(true);
    clients_.push_back(ClientLease{token, pid, fd, mask, client_alive});
    active_clients_.store(static_cast<int>(clients_.size()), std::memory_order_release);
    lock.unlock();

    // Wake superseded client threads after the new ownership is committed.
    for (const auto& old : superseded) {
      if (old.alive) old.alive->store(false, std::memory_order_release);
      if (old.fd >= 0 && old.fd != fd) (void)::shutdown(old.fd, SHUT_RDWR);
    }
    cv_.notify_all();
    return 0;
  }

  void release(uint64_t token) {
    if (token == 0) return;
    std::lock_guard<std::mutex> lock(dev_mu_);
    const auto it = std::find_if(clients_.begin(), clients_.end(),
        [token](const ClientLease& client) { return client.token == token; });
    if (it == clients_.end()) return; // already superseded by a newer session
    adjust_users_locked(it->mask, -1);
    if (it->alive) it->alive->store(false, std::memory_order_release);
    clients_.erase(it);
    active_clients_.store(static_cast<int>(clients_.size()), std::memory_order_release);
    (void)apply_locked();
    clear_inactive_queues_locked();
    cv_.notify_all();
  }

  bool wait_next(uint32_t mask, uint64_t& rgb_seq, uint64_t& hq_rgb_seq, uint64_t& ir_seq, uint64_t& depth_seq,
                 const std::shared_ptr<std::atomic<bool>>& client_alive,
                 scanner::FrameHeader& header, std::vector<uint8_t>& output) {
    std::unique_lock<std::mutex> lock(frame_mu_);
    cv_.wait_for(lock, std::chrono::milliseconds(1000), [&] {
      return !running_.load() || !run.load() || !online_.load() ||
             !client_alive || !client_alive->load(std::memory_order_acquire) ||
             ((mask & scanner::StreamRgb) && has_after(rgb_queue_, rgb_seq)) ||
             ((mask & scanner::StreamRgbHighQuality) && has_after(hq_rgb_queue_, hq_rgb_seq)) ||
             ((mask & scanner::StreamInfrared) && has_after(ir_queue_, ir_seq)) ||
             ((mask & scanner::StreamDepth) && has_after(depth_queue_, depth_seq));
    });
    if (!running_.load() || !run.load() || !online_ || !client_alive ||
        !client_alive->load(std::memory_order_acquire)) return false;

    const Frame* chosen = nullptr;
    scanner::StreamMode chosen_mode = scanner::StreamMode::Depth;
    scanner::PixelFormat chosen_format = scanner::PixelFormat::DepthRaw11Packed;
    auto consider = [&](const std::deque<Frame>& queue, uint64_t seen, scanner::StreamMode mode, scanner::PixelFormat format) {
      const Frame* candidate = next_after(queue, seen);
      if (candidate && (!chosen || candidate->tick < chosen->tick ||
          (candidate->tick == chosen->tick && mode == scanner::StreamMode::Depth))) {
        chosen = candidate; chosen_mode = mode; chosen_format = format;
      }
    };
    if (mask & scanner::StreamRgb) consider(rgb_queue_, rgb_seq, scanner::StreamMode::Rgb, scanner::PixelFormat::BayerGrbg8);
    if (mask & scanner::StreamRgbHighQuality) consider(hq_rgb_queue_, hq_rgb_seq, scanner::StreamMode::RgbHighQuality, scanner::PixelFormat::BayerGrbg8);
    if (mask & scanner::StreamInfrared) consider(ir_queue_, ir_seq, scanner::StreamMode::Infrared, scanner::PixelFormat::IrRaw10Packed);
    if (mask & scanner::StreamDepth) consider(depth_queue_, depth_seq, scanner::StreamMode::Depth, scanner::PixelFormat::DepthRaw11Packed);
    if (!chosen) return true;

    header = {};
    header.mode = chosen_mode; header.pixelFormat = chosen_format;
    header.width = chosen->width; header.height = chosen->height;
    header.payloadBytes = static_cast<uint32_t>(chosen->data.size());
    header.frameNumber = chosen->seq; header.tickMs = chosen->tick;
    header.motion = chosen->motion;
    output = chosen->data;
    if (chosen_mode == scanner::StreamMode::Rgb) rgb_seq = chosen->seq;
    else if (chosen_mode == scanner::StreamMode::RgbHighQuality) hq_rgb_seq = chosen->seq;
    else if (chosen_mode == scanner::StreamMode::Infrared) ir_seq = chosen->seq;
    else depth_seq = chosen->seq;
    return true;
  }

 private:
  // Keep a bounded queue so scheduler stalls do not accumulate stale frames.
  static constexpr std::size_t kFrameQueueDepth = 6;
  static constexpr std::size_t kHqFrameQueueDepth = 6;
  static constexpr uint64_t kVideoFrameTimeoutMs = 3500;
  static constexpr uint64_t kRgbHqFrameTimeoutMs = 6000;
  static constexpr uint64_t kDepthFrameTimeoutMs = 3500;
  struct ClientLease {
    uint64_t token = 0;
    pid_t pid = 0;
    int fd = -1;
    uint32_t mask = 0;
    std::shared_ptr<std::atomic<bool>> alive;
  };

  void adjust_users_locked(uint32_t mask, int delta) {
    auto adjust = [delta](int& value) { value = std::max(0, value + delta); };
    if (mask & scanner::StreamRgb) adjust(rgb_users_);
    if (mask & scanner::StreamRgbHighQuality) adjust(hq_rgb_users_);
    if (mask & scanner::StreamInfrared) adjust(ir_users_);
    if (mask & scanner::StreamDepth) adjust(depth_users_);
  }
  bool has_after(const std::deque<Frame>& queue, uint64_t seq) const { return !queue.empty() && queue.back().seq > seq; }
  const Frame* next_after(const std::deque<Frame>& queue, uint64_t seq) const {
    for (const auto& frame : queue) if (frame.seq > seq) return &frame;
    return nullptr;
  }
  void push_frame(std::deque<Frame>& queue, Frame&& frame, std::size_t limit=kFrameQueueDepth) {
    queue.push_back(std::move(frame));
    while (queue.size() > limit) queue.pop_front();
    cv_.notify_all();
  }
  void clear_inactive_queues_locked() {
    std::lock_guard<std::mutex> lock(frame_mu_);
    if (rgb_users_ == 0) rgb_queue_.clear();
    if (hq_rgb_users_ == 0) hq_rgb_queue_.clear();
    if (ir_users_ == 0) ir_queue_.clear();
    if (depth_users_ == 0) depth_queue_.clear();
    cv_.notify_all();
  }
  void clear_all_queues_locked() {
    std::lock_guard<std::mutex> lock(frame_mu_);
    rgb_queue_.clear(); hq_rgb_queue_.clear(); ir_queue_.clear(); depth_queue_.clear();
    cv_.notify_all();
  }
  void on_rgb(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kRgbRawPayloadBytes) return;
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kHeight;
    next.tick = unixio::monotonic_ms(); last_video_frame_ms_.store(next.tick, std::memory_order_release);
    next.motion = motion_.current();
    next.seq = ++rgb_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(rgb_queue_, std::move(next));
  }

  void on_hq_rgb(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kRgbHqPayloadBytes) return;
    const uint64_t tick = unixio::monotonic_ms();
    last_video_frame_ms_.store(tick, std::memory_order_release);
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kRgbHqWidth; next.height=scanner::kRgbHqHeight;
    next.tick=tick; next.motion=motion_.current(); next.seq=++hq_rgb_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(hq_rgb_queue_, std::move(next), kHqFrameQueueDepth);
  }

  void on_ir(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kIrRaw10PayloadBytes) return;
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kIrRawHeight;
    next.tick = unixio::monotonic_ms(); last_video_frame_ms_.store(next.tick, std::memory_order_release);
    next.motion = motion_.current();
    next.seq = ++ir_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(ir_queue_, std::move(next));
  }

  void on_depth(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kDepthRaw11PackedPayloadBytes) return;
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kHeight;
    next.tick = unixio::monotonic_ms(); last_depth_frame_ms_.store(next.tick, std::memory_order_release);
    next.motion = motion_.current();
    next.seq = ++depth_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(depth_queue_, std::move(next));
  }

  int open_device_locked() {
    prepare_physical_camera(device_info_, startup_open_);
    const int rc = device_.open(device_info_,
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_rgb(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_hq_rgb(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_ir(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_depth(p, n, ts); });
    if (rc < 0) {
      if (rc != last_open_rc_) log_failure("camera open failed", rc);
      last_open_rc_ = rc;
      return rc;
    }
    last_open_rc_ = 0;
    std::fprintf(stderr, "camera %s (%s): camera opened (bcdDevice %04x)\n", device_info_.id.c_str(),
                 hardware::model_name(device_info_.model), device_info_.bcd_device);
    if (!device_.depth_calibrated()) {
      std::fprintf(stderr, "camera %s (%s): factory depth calibration unavailable; raw depth remains available but metric depth is not\n",
                   device_info_.id.c_str(), hardware::model_name(device_info_.model));
    }
    ir_mode_ = false;
    hq_mode_ = false;
    video_on_ = false;
    video_started_ms_ = 0;
    last_video_frame_ms_.store(0, std::memory_order_release);
    depth_on_ = false;
    depth_started_ms_ = 0;
    last_depth_frame_ms_.store(0, std::memory_order_release);
    online_ = true;
    startup_open_ = false;
    motion_.enable(device_info_.model);
    cv_.notify_all();
    return 0;
  }

  void close_device_locked() {
    motion_.disable();
    device_.close();
    video_on_ = false;
    video_started_ms_ = 0;
    last_video_frame_ms_.store(0, std::memory_order_release);
    depth_on_ = false;
    depth_started_ms_ = 0;
    last_depth_frame_ms_.store(0, std::memory_order_release);
    online_ = false;
    clear_all_queues_locked();
  }

  void close_device() {
    std::lock_guard<std::mutex> lock(dev_mu_);
    close_device_locked();
  }

  void log_stream(const char* what, const kinectusb::StreamStats& stats, uint64_t elapsed_ms) const {
    std::fprintf(stderr,
        "camera %s (%s): %s - %llu ms, %llu packets, %llu frames, %llu sync losses\n",
        device_info_.id.c_str(), hardware::model_name(device_info_.model), what,
        static_cast<unsigned long long>(elapsed_ms), static_cast<unsigned long long>(stats.packets),
        static_cast<unsigned long long>(stats.frames), static_cast<unsigned long long>(stats.sync_losses));
  }

  void log_failure(const char* what, int rc) const {
    std::fprintf(stderr, "camera %s (%s): %s: %s\n", device_info_.id.c_str(),
                 hardware::model_name(device_info_.model), what, kinectusb::error_text(rc));
  }

  // A sensor that cannot complete an RGB HQ frame returns to VGA for the
  // current connection. HQ subscribers are released so they renegotiate.
  void mark_rgb_hq_unavailable_locked(uint64_t elapsed_ms) {
    log_stream("RGB HQ delivered no complete frame; RGB HQ disabled for this connection", device_.video_stats(), elapsed_ms);
    rgb_hq_unavailable_.store(true, std::memory_order_release);
    for (auto it = clients_.begin(); it != clients_.end();) {
      if ((it->mask & scanner::StreamRgbHighQuality) == 0) { ++it; continue; }
      adjust_users_locked(it->mask, -1);
      if (it->alive) it->alive->store(false, std::memory_order_release);
      if (it->fd >= 0) (void)::shutdown(it->fd, SHUT_RDWR);
      it = clients_.erase(it);
    }
    active_clients_.store(static_cast<int>(clients_.size()), std::memory_order_release);
    cv_.notify_all();
  }

  int apply_locked() {
    if (!online_ || !device_.online()) return -ENODEV;
    const uint64_t now = unixio::monotonic_ms();

    if (video_on_ && hq_mode_ && video_started_ms_ != 0 &&
        last_video_frame_ms_.load(std::memory_order_acquire) == 0 &&
        now - video_started_ms_ >= kRgbHqFrameTimeoutMs) {
      mark_rgb_hq_unavailable_locked(now - video_started_ms_);
    }

    const bool want_video = (rgb_users_ + hq_rgb_users_ + ir_users_) > 0;
    const bool want_depth = depth_users_ > 0;
    const bool want_ir = ir_users_ > 0;
    const bool want_hq = hq_rgb_users_ > 0;

    if (video_on_ && want_video && video_started_ms_ != 0) {
      const uint64_t last = last_video_frame_ms_.load(std::memory_order_acquire);
      const uint64_t anchor = last >= video_started_ms_ ? last : video_started_ms_;
      const uint64_t timeout = hq_mode_ ? kRgbHqFrameTimeoutMs : kVideoFrameTimeoutMs;
      if (want_hq == hq_mode_ && now - anchor >= timeout) {
        log_stream(ir_mode_ ? "IR stopped producing frames" : "RGB stopped producing frames",
                   device_.video_stats(), now - video_started_ms_);
        return -ETIMEDOUT;
      }
    }
    if (depth_on_ && want_depth && depth_started_ms_ != 0) {
      const uint64_t last = last_depth_frame_ms_.load(std::memory_order_acquire);
      const uint64_t anchor = last >= depth_started_ms_ ? last : depth_started_ms_;
      if (now - anchor >= kDepthFrameTimeoutMs) {
        log_stream("Depth stopped producing frames", device_.depth_stats(), now - depth_started_ms_);
        return -ETIMEDOUT;
      }
    }

    if (video_on_ && (!want_video || want_ir != ir_mode_ || want_hq != hq_mode_)) {
      if (device_.stop_video() < 0) return -EIO;
      video_on_ = false;
      video_started_ms_ = 0;
      last_video_frame_ms_.store(0, std::memory_order_release);
    }
    if (want_video && !video_on_) {
      ir_mode_ = want_ir; hq_mode_ = want_hq;
      const auto mode = want_ir ? kinectusb::VideoMode::Infrared
                                : (want_hq ? kinectusb::VideoMode::RgbHighQuality
                                           : kinectusb::VideoMode::Rgb);
      const int video_rc = device_.start_video(mode);
      if (video_rc < 0) {
        log_failure(want_ir ? "IR start failed" : (want_hq ? "RGB HQ start failed" : "RGB start failed"), video_rc);
        return -EIO;
      }
      video_on_ = true;
      video_started_ms_ = unixio::monotonic_ms();
      last_video_frame_ms_.store(0, std::memory_order_release);
    }
    if (depth_on_ && !want_depth) {
      if (device_.stop_depth() < 0) return -EIO;
      depth_on_ = false;
      depth_started_ms_ = 0;
      last_depth_frame_ms_.store(0, std::memory_order_release);
    }
    if (want_depth && !depth_on_) {
      const int depth_rc = device_.start_depth();
      if (depth_rc < 0) {
        log_failure("Depth start failed", depth_rc);
        return -EIO;
      }
      depth_on_ = true;
      depth_started_ms_ = unixio::monotonic_ms();
      last_depth_frame_ms_.store(0, std::memory_order_release);
    }
    // The IR projector is reference counted exactly like the Windows bridge:
    // on while IR or Depth is requested, off otherwise.
    const int projector_rc = device_.set_projector(want_ir || want_depth);
    if (projector_rc < 0) {
      log_failure("IR projector control failed", projector_rc);
      return -EIO;
    }
    return 0;
  }

  void loop() {
    while (running_.load() && run.load()) {
      if (!online_) {
        int rc = 0;
        {
          std::lock_guard<std::mutex> lock(dev_mu_);
          rc = open_device_locked();
        }
        if (rc < 0) {
          unixio::retry_sleep(750);
          continue;
        }
      }

      int rc = 0;
      {
        std::lock_guard<std::mutex> lock(dev_mu_);
        rc = device_.process_events(120);
        if (rc >= 0) rc = apply_locked(); // apply current subscriber ownership after USB events
        if (rc < 0) close_device_locked();
      }
      if (rc < 0) unixio::retry_sleep(device_info_.model == hardware::Model::Xbox1473 ? 1500 : 500);
    }
  }

  kinectusb::DeviceInfo device_info_;
  std::atomic<int> active_clients_{0};
  MotionSampler motion_;
  kinectusb::Camera device_;
  std::atomic<bool> running_{false};
  std::thread worker_;
  std::mutex dev_mu_;
  std::mutex frame_mu_;
  std::condition_variable cv_;
  std::atomic<bool> online_{false};
  bool startup_open_ = true;
  std::atomic<uint32_t> driver_settings_{0};
  std::atomic<bool> rgb_hq_unavailable_{false};
  int last_open_rc_ = 0;
  std::vector<ClientLease> clients_;
  uint64_t next_client_token_ = 0;
  int rgb_users_ = 0;
  int hq_rgb_users_ = 0;
  int ir_users_ = 0;
  int depth_users_ = 0;
  bool video_on_ = false;
  bool depth_on_ = false;
  bool ir_mode_ = false;
  bool hq_mode_ = false;
  uint64_t video_started_ms_ = 0;
  uint64_t depth_started_ms_ = 0;
  std::atomic<uint64_t> last_video_frame_ms_{0};
  std::atomic<uint64_t> last_depth_frame_ms_{0};
  uint64_t rgb_seq_counter_ = 0, hq_rgb_seq_counter_ = 0, ir_seq_counter_ = 0, depth_seq_counter_ = 0;
  std::deque<Frame> rgb_queue_, hq_rgb_queue_, ir_queue_, depth_queue_;
};

class ScannerClientLease {
 public:
  ScannerClientLease() = default;
  ~ScannerClientLease() {
    scanner_clients.fetch_sub(1);
    scanner_clients_cv.notify_all();
  }
  ScannerClientLease(const ScannerClientLease&) = delete;
  ScannerClientLease& operator=(const ScannerClientLease&) = delete;
};

class HubSubscriptionLease {
 public:
  HubSubscriptionLease(std::shared_ptr<CameraHub> hub, uint64_t token)
      : hub_(std::move(hub)), token_(token) {}
  ~HubSubscriptionLease() {
    if (hub_ && token_ != 0) hub_->release(token_);
  }
  HubSubscriptionLease(const HubSubscriptionLease&) = delete;
  HubSubscriptionLease& operator=(const HubSubscriptionLease&) = delete;

 private:
  std::shared_ptr<CameraHub> hub_;
  uint64_t token_ = 0;
};

pid_t peer_pid(int fd) {
  struct ucred credentials{};
  socklen_t bytes = sizeof(credentials);
  if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &bytes) == 0 &&
      bytes >= sizeof(credentials)) {
    return credentials.pid;
  }
  return 0;
}

void client(std::shared_ptr<CameraHub> hub, int fd) {
  if (!unixio::set_io_timeout(fd, kScannerClientTimeoutMs)) return;

  scanner::Request request{};
  scanner::Reply reply{};
  if (!unixio::read_exact(fd, &request, sizeof(request)) || request.magic != scanner::kMagic ||
      request.version != scanner::kVersion) {
    return;
  }

  if (request.command == scanner::Command::GetDriverSettings) {
    reply.result = 0;
    reply.acceptedMask = hub->driver_settings();
    (void)unixio::write_all(fd, &reply, sizeof(reply));
    return;
  }

  if (request.command == scanner::Command::SetDriverSettings) {
    reply.result = hub->set_driver_settings(request.streamMask);
    reply.acceptedMask = hub->driver_settings();
    (void)unixio::write_all(fd, &reply, sizeof(reply));
    return;
  }

  if (request.command != scanner::Command::SubscribeStreams) {
    reply.result = -EINVAL;
    (void)unixio::write_all(fd, &reply, sizeof(reply));
    return;
  }

  uint64_t client_token = 0;
  std::shared_ptr<std::atomic<bool>> client_alive;
  const int rc = hub->acquire(request.streamMask, peer_pid(fd), fd, client_token, client_alive);
  reply.result = rc;
  if (rc == 0) {
    reply.acceptedMask = request.streamMask;
    hub->fill_reply(reply);
  }
  if (!unixio::write_all(fd, &reply, sizeof(reply)) || rc < 0) return;

  HubSubscriptionLease subscription(hub, client_token);
  uint64_t rgb_seq = 0;
  uint64_t hq_rgb_seq = 0;
  uint64_t ir_seq = 0;
  uint64_t depth_seq = 0;
  while (run) {
    scanner::FrameHeader header{};
    std::vector<uint8_t> data;
    if (!hub->wait_next(request.streamMask, rgb_seq, hq_rgb_seq, ir_seq, depth_seq,
                        client_alive, header, data)) {
      break;
    }
    if (header.frameNumber == 0) continue;
    if (!unixio::write_all(fd, &header, sizeof(header)) ||
        !unixio::write_all(fd, data.data(), data.size())) {
      break;
    }
  }
}
}  // namespace

class CameraNode {
 public:
  explicit CameraNode(const kinectusb::DeviceInfo& info)
      : info_(info), endpoint_(std::string(kRuntimeDir) + "/devices/" + info.id + ".sock"), hub_(std::make_shared<CameraHub>(info)) {}
  const std::string& endpoint() const { return endpoint_; }
  const kinectusb::DeviceInfo& info() const { return info_; }
  bool ready() const { return hub_->online() && ::access(endpoint_.c_str(), F_OK) == 0; }
  void start() {
    if (running_.exchange(true)) return;
    hub_->start();
    thread_ = std::thread([this] { server_loop(); });
  }
  void stop() {
    if (!running_.exchange(false)) return;
    const int fd = server_.exchange(-1);
    if (fd >= 0) { ::shutdown(fd, SHUT_RDWR); ::close(fd); }
    if (thread_.joinable()) thread_.join();
    hub_->shutdown();
    ::unlink(endpoint_.c_str());
  }
 private:
  void server_loop() {
    const int fd = unixio::local_server_socket(endpoint_, 32);
    if (fd < 0) { std::perror(("scanner socket " + endpoint_).c_str()); running_ = false; return; }
    server_ = fd;
    while (running_.load() && run.load()) {
      const int connection = ::accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
      if (connection < 0) {
        if (errno == EINTR) continue;
        if (!running_.load() || !run.load()) break;
        unixio::retry_sleep(50); continue;
      }
      const uint32_t previous = scanner_clients.fetch_add(1);
      if (previous >= kMaxScannerClients) {
        scanner_clients.fetch_sub(1);
        ::close(connection);
        continue;
      }
      auto hub = hub_;
      try {
        std::thread([hub, connection] {
          ScannerClientLease lease;
          try {
            client(hub, connection);
          } catch (const std::exception& error) {
            std::fprintf(stderr, "camera client error: %s\n", error.what());
          } catch (...) {
            std::fprintf(stderr, "camera client error: unknown exception\n");
          }
          ::shutdown(connection, SHUT_RDWR);
          ::close(connection);
        }).detach();
      } catch (...) {
        scanner_clients.fetch_sub(1);
        ::close(connection);
      }
    }
    int expected = fd;
    if (server_.compare_exchange_strong(expected, -1)) ::close(fd);
    ::unlink(endpoint_.c_str());
  }
  kinectusb::DeviceInfo info_;
  std::string endpoint_;
  std::shared_ptr<CameraHub> hub_;
  std::atomic<bool> running_{false};
  std::atomic<int> server_{-1};
  std::thread thread_;
};

std::map<std::string, std::string> read_virtual_camera_map() {
  std::map<std::string, std::string> result;
  std::ifstream input(kVirtualCameraMap);
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;

    std::istringstream row(line);
    std::string id;
    std::string node;
    if (std::getline(row, id, '\t') && std::getline(row, node) &&
        !id.empty() && !node.empty()) {
      result[id] = node;
    }
  }
  return result;
}

bool endpoint_ready(const std::string& path) {
  return !path.empty() && ::access(path.c_str(), F_OK) == 0;
}

std::string audio_endpoint(const std::string& id) {
  return std::string(kAudioDirectory) + "/" + id + ".sock";
}

std::string audio_control_endpoint(const std::string& id) {
  return std::string(kAudioDirectory) + "/" + id + "-control.sock";
}

bool control_ready(const std::string& id) {
  const int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) return false;

  control::Request request{};
  request.command = control::Command::Ping;
  std::strncpy(request.deviceId, id.c_str(), sizeof(request.deviceId) - 1);
  control::Reply reply{};
  const bool ok = unixio::write_all(fd, &request, sizeof(request)) &&
      unixio::read_exact(fd, &reply, sizeof(reply));
  ::close(fd);

  return ok && reply.magic == control::kMagic &&
      reply.version == control::kVersion && reply.result == 0 &&
      reply.transport == control::Transport::PhysicalMotor;
}

void write_manifest(const std::map<std::string, std::unique_ptr<CameraNode>>& nodes,
                    const std::set<std::string>& present) {
  namespace fs = std::filesystem;
  const fs::path dir = fs::path(kRuntimeDir);
  std::error_code ec;
  fs::create_directories(dir / "devices", ec);
  if (ec) return;

  const auto virtual_map = read_virtual_camera_map();
  const fs::path temporary = dir / "devices.tsv.tmp";
  const fs::path target = dir / "devices.tsv";
  {
    std::ofstream out(temporary, std::ios::trunc);
    if (!out) return;
    out << "# id\tlabel\tstate\tcontrol\tcamera\taudio\taudio-control\tvirtual-camera\tsdk\n";
    for (const auto& entry : nodes) {
      const auto& id = entry.first;
      const auto& node = *entry.second;
      const bool physically_present = present.count(id) != 0;
      const bool camera_ready = physically_present && node.ready();
      const std::string state = !physically_present ? "Reconnecting" : (camera_ready ? "Ready" : "Booting");
      const std::string control = physically_present && control_ready(id) ? kControlSocket : "";
      const std::string camera = camera_ready ? node.endpoint() : "";
      const std::string audio = audio_endpoint(id);
      const std::string audio_control = audio_control_endpoint(id);
      // Per-Kinect audio endpoints remain stable while native capture reconnects.
      const bool raw_audio_ready = physically_present && endpoint_ready(audio);
      const bool control_audio_ready = physically_present && endpoint_ready(audio_control);
      const auto virtual_camera_it = virtual_map.find(id);
      const std::string virtual_camera =
          virtual_camera_it != virtual_map.end() && endpoint_ready(virtual_camera_it->second)
              ? virtual_camera_it->second
              : "";
      const std::string sdk = endpoint_ready(kSdkSocket) ? kSdkSocket : "";

      out << id << '\t' << node.info().label << '\t' << state << '\t' << control << '\t' << camera << '\t'
          << (raw_audio_ready ? audio : "") << '\t'
          << (control_audio_ready ? audio_control : "") << '\t'
          << virtual_camera << '\t' << sdk << '\n';
    }
    out.flush();
    if (!out) {
      fs::remove(temporary, ec);
      return;
    }
  }

  fs::rename(temporary, target, ec);
  if (ec) {
    std::error_code cleanup;
    fs::remove(temporary, cleanup);
    return;
  }
  ::chmod(target.c_str(), 0644);
}

int main() {
  struct sigaction action{};
  action.sa_handler = stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  sigaction(SIGINT, &action, nullptr);
  sigaction(SIGTERM, &action, nullptr);
  std::signal(SIGPIPE, SIG_IGN);

  std::map<std::string, std::unique_ptr<CameraNode>> nodes;
  std::map<std::string,std::chrono::steady_clock::time_point> last_seen;
  constexpr auto reconnect_grace=std::chrono::seconds(30);
  while (run.load()) {
    const auto enumerated = kinectusb::enumerate();
    const auto now=std::chrono::steady_clock::now();
    std::set<std::string> present;
    for (const auto& info : enumerated) {
      present.insert(info.id);last_seen[info.id]=now;
      if (nodes.find(info.id) == nodes.end()) {
        auto node = std::make_unique<CameraNode>(info);
        node->start();
        nodes.emplace(info.id, std::move(node));
      }
    }
    for(auto it=nodes.begin();it!=nodes.end();){
      auto seen=last_seen.find(it->first);
      if(present.count(it->first)==0&&seen!=last_seen.end()&&now-seen->second>=reconnect_grace){
        it->second->stop();last_seen.erase(seen);it=nodes.erase(it);
      }else ++it;
    }
    write_manifest(nodes,present);
    for (int i = 0; i < 10 && run.load(); ++i) unixio::retry_sleep(100);
  }

  for (auto& entry : nodes) entry.second->stop();
  {
    std::unique_lock<std::mutex> lock(scanner_clients_mutex);
    scanner_clients_cv.wait(lock, [] { return scanner_clients.load() == 0; });
  }
  ::unlink((std::string(kRuntimeDir) + "/devices.tsv").c_str());
  return 0;
}
