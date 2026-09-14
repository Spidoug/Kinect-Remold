#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
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

#include "remold/kinect_usb_camera.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
void stop_handler(int) { run = false; }

bool prepare_camera_control(const std::string& device_id) {
  control::Request request{};
  request.command=control::Command::PrepareCamera;
  std::snprintf(request.deviceId,sizeof(request.deviceId),"%s",device_id.c_str());
  control::Reply reply{};
  const int fd=unixio::connect_socket(kControlSocket);
  if(fd<0)return false;
  const bool ok=unixio::write_all(fd,&request,sizeof(request)) &&
                unixio::read_exact(fd,&reply,sizeof(reply));
  ::close(fd);
  return ok && reply.magic==control::kMagic && reply.version==control::kVersion && reply.result==0;
}

struct Frame {
  uint64_t seq = 0;
  uint64_t tick = 0;
  uint32_t width = scanner::kWidth;
  uint32_t height = scanner::kHeight;
  std::vector<uint8_t> data;
};

class CameraHub {
 public:
  explicit CameraHub(kinectusb::DeviceInfo device_info) : device_info_(std::move(device_info)) {}

  ~CameraHub() { shutdown(); }

  void start() { if (running_.exchange(true)) return; worker_ = std::thread([this] { loop(); }); }

  void shutdown() {
    if (!running_.exchange(false)) return;
    cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    close_device();
  }

  const kinectusb::DeviceInfo& info() const { return device_info_; }

  void fill_reply(scanner::Reply& reply) {
    std::lock_guard<std::mutex> lock(dev_mu_);
    const auto calibration=device_.depth_calibration();
    reply.depthCalibrationValid=calibration.valid?1u:0u;
    reply.depthConstShift=calibration.const_shift;
    reply.depthEmitterDistance=calibration.emitter_distance;
    reply.depthReferenceDistance=calibration.reference_distance;
    reply.depthReferencePixelSize=calibration.reference_pixel_size;
  }

  int acquire(uint32_t mask) {
    if (!scanner::valid_mask(mask)) return -EINVAL;
    std::unique_lock<std::mutex> lock(dev_mu_);
    if (!online_) return -ENODEV;
    // Clients may keep a baseline RGB subscription while Scanner requests
    // IR or RGB-HQ. apply_locked()
    // selects the physical 0x81 mode with priority IR > HQ > RGB and restores
    // baseline RGB when the higher-priority client releases it. valid_mask()
    // still rejects impossible RGB+IR combinations inside one request.

    if (mask & scanner::StreamRgb) ++rgb_users_;
    if (mask & scanner::StreamRgbHighQuality) ++hq_rgb_users_;
    if (mask & scanner::StreamInfrared) ++ir_users_;
    if (mask & scanner::StreamDepth) ++depth_users_;

    const int rc = apply_locked();
    if (rc < 0) {
      if (mask & scanner::StreamRgb) --rgb_users_;
      if (mask & scanner::StreamRgbHighQuality) --hq_rgb_users_;
      if (mask & scanner::StreamInfrared) --ir_users_;
      if (mask & scanner::StreamDepth) --depth_users_;
    }
    return rc;
  }

  void release(uint32_t mask) {
    std::lock_guard<std::mutex> lock(dev_mu_);
    if (mask & scanner::StreamRgb) rgb_users_ = std::max(0, rgb_users_ - 1);
    if (mask & scanner::StreamRgbHighQuality) hq_rgb_users_ = std::max(0, hq_rgb_users_ - 1);
    if (mask & scanner::StreamInfrared) ir_users_ = std::max(0, ir_users_ - 1);
    if (mask & scanner::StreamDepth) depth_users_ = std::max(0, depth_users_ - 1);
    (void)apply_locked();
    clear_inactive_queues_locked();
  }

  bool wait_next(uint32_t mask, uint64_t& rgb_seq, uint64_t& hq_rgb_seq, uint64_t& ir_seq, uint64_t& depth_seq,
                 scanner::FrameHeader& header, std::vector<uint8_t>& output) {
    std::unique_lock<std::mutex> lock(frame_mu_);
    cv_.wait_for(lock, std::chrono::milliseconds(1000), [&] {
      return !running_.load() || !run.load() || !online_.load() ||
             ((mask & scanner::StreamRgb) && has_after(rgb_queue_, rgb_seq)) ||
             ((mask & scanner::StreamRgbHighQuality) && has_after(hq_rgb_queue_, hq_rgb_seq)) ||
             ((mask & scanner::StreamInfrared) && has_after(ir_queue_, ir_seq)) ||
             ((mask & scanner::StreamDepth) && has_after(depth_queue_, depth_seq));
    });
    if (!running_.load() || !run.load() || !online_) return false;

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
    header.frameNumber = chosen->seq; header.tickMs = chosen->tick; output = chosen->data;
    if (chosen_mode == scanner::StreamMode::Rgb) rgb_seq = chosen->seq;
    else if (chosen_mode == scanner::StreamMode::RgbHighQuality) hq_rgb_seq = chosen->seq;
    else if (chosen_mode == scanner::StreamMode::Infrared) ir_seq = chosen->seq;
    else depth_seq = chosen->seq;
    return true;
  }

 private:
  static constexpr std::size_t kFrameQueueDepth = 48;
  static constexpr std::size_t kHqFrameQueueDepth = 6;
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
    last_video_frame_ms_ = unixio::monotonic_ms();
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kHeight;
    next.tick = unixio::monotonic_ms(); next.seq = ++rgb_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(rgb_queue_, std::move(next));
  }

  void on_hq_rgb(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kRgbHqPayloadBytes) return;
    const uint64_t tick = unixio::monotonic_ms();
    last_video_frame_ms_ = tick;

    Frame hq;
    hq.data.assign(data, data + bytes);
    hq.width = scanner::kRgbHqWidth;
    hq.height = scanner::kRgbHqHeight;
    hq.tick = tick;
    hq.seq = ++hq_rgb_seq_counter_;

    Frame vga;
    vga.data.resize(scanner::kRgbRawPayloadBytes);
    for (uint32_t y = 0; y < scanner::kHeight; ++y) {
      const uint32_t sy = 32u + 4u * (y / 2u) + (y & 1u);
      for (uint32_t x = 0; x < scanner::kWidth; ++x) {
        const uint32_t sx = 4u * (x / 2u) + (x & 1u);
        vga.data[static_cast<size_t>(y) * scanner::kWidth + x] =
            data[static_cast<size_t>(sy) * scanner::kRgbHqWidth + sx];
      }
    }
    vga.width = scanner::kWidth;
    vga.height = scanner::kHeight;
    vga.tick = tick;
    vga.seq = ++rgb_seq_counter_;

    std::lock_guard<std::mutex> lock(frame_mu_);
    push_frame(hq_rgb_queue_, std::move(hq), kHqFrameQueueDepth);
    push_frame(rgb_queue_, std::move(vga));
  }

  void on_ir(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kIrRaw10PayloadBytes) return;
    last_video_frame_ms_ = unixio::monotonic_ms();
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kIrRawHeight;
    next.tick = unixio::monotonic_ms(); next.seq = ++ir_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(ir_queue_, std::move(next));
  }

  void on_depth(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != scanner::kDepthRaw11PackedPayloadBytes) return;
    last_depth_frame_ms_ = unixio::monotonic_ms();
    Frame next; next.data.assign(data, data + bytes); next.width=scanner::kWidth; next.height=scanner::kHeight;
    next.tick = unixio::monotonic_ms(); next.seq = ++depth_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(depth_queue_, std::move(next));
  }

  int open_device_locked() {
    // The 1414 camera reports 02AE bcdDevice 0x010B. Newer 02AE revisions
    // use a bounded controller keep-alive before the independent camera opens.
    if(device_info_.bcd_device!=0x010B){
      bool prepared=false;
      for(unsigned attempt=0;attempt<20 && running_.load() && run.load();++attempt){
        if(prepare_camera_control(device_info_.id)){prepared=true;break;}
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
      }
      if(!prepared)std::fprintf(stderr,"Kinect 1473 keep-alive unavailable after 5 seconds; continuing camera with recovery enabled.\n");
    }
    const int rc = device_.open(device_info_,
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_rgb(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_hq_rgb(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_ir(p, n, ts); },
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_depth(p, n, ts); });
    if (rc < 0) return rc;
    video_started_ms_ = depth_started_ms_ = 0;
    last_video_frame_ms_ = last_depth_frame_ms_ = 0;
    ir_mode_ = false;
    hq_mode_ = false;
    video_on_ = false;
    depth_on_ = false;
    online_ = true;
    cv_.notify_all();
    return 0;
  }

  void close_device_locked() {
    device_.close();
    video_on_ = false;
    depth_on_ = false;
    video_started_ms_ = depth_started_ms_ = 0;
    last_video_frame_ms_ = last_depth_frame_ms_ = 0;
    online_ = false;
    clear_all_queues_locked();
  }

  void close_device() {
    std::lock_guard<std::mutex> lock(dev_mu_);
    close_device_locked();
  }

  int apply_locked() {
    if (!online_ || !device_.online()) return -ENODEV;
    const bool want_video = (rgb_users_ + hq_rgb_users_ + ir_users_) > 0;
    const bool want_depth = depth_users_ > 0;
    const bool want_ir = ir_users_ > 0;
    const bool want_hq = hq_rgb_users_ > 0;

    if (video_on_ && (!want_video || want_ir != ir_mode_ || want_hq != hq_mode_)) {
      if (device_.stop_video() < 0) return -EIO;
      video_on_ = false;
    }
    if (want_video && !video_on_) {
      ir_mode_ = want_ir; hq_mode_ = want_hq;
      const auto mode = want_ir ? kinectusb::VideoMode::Infrared
                                : (want_hq ? kinectusb::VideoMode::RgbHighQuality
                                           : kinectusb::VideoMode::Rgb);
      // Infrared requires the projector before video start. RGB-HQ performs
      // its own priming; the final reconciliation restores active Depth demand.
      if (want_ir && device_.set_projector(true) < 0) return -EIO;
      if (device_.start_video(mode) < 0) return -EIO;
      video_on_ = true;video_started_ms_ = unixio::monotonic_ms();last_video_frame_ms_ = 0;
    }
    if (depth_on_ && !want_depth) {
      if (device_.stop_depth() < 0) return -EIO;
      depth_on_ = false;
    }
    if (want_depth && !depth_on_) {
      if (device_.start_depth() < 0) return -EIO;
      depth_on_ = true;depth_started_ms_ = unixio::monotonic_ms();last_depth_frame_ms_ = 0;
    }
    // Projector ownership is shared by IR and Depth. Reconcile after every
    // video/depth transition so RGB-HQ priming cannot accidentally leave an
    // already-running Depth stream dark, and RGB restoration turns IR off.
    if (device_.set_projector(want_ir || want_depth) < 0) return -EIO;
    return 0;
  }

  bool streams_stalled_locked(uint64_t now) const {
    constexpr uint64_t kStartupGraceMs = 2600;
    constexpr uint64_t kStallMs = 1800;
    if (video_on_ && (rgb_users_ + hq_rgb_users_ + ir_users_) > 0) {
      const uint64_t ref = last_video_frame_ms_ ? last_video_frame_ms_ : video_started_ms_;
      if (ref && now > ref && now - ref > (last_video_frame_ms_ ? kStallMs : kStartupGraceMs)) return true;
    }
    if (depth_on_ && depth_users_ > 0) {
      const uint64_t ref = last_depth_frame_ms_ ? last_depth_frame_ms_ : depth_started_ms_;
      if (ref && now > ref && now - ref > (last_depth_frame_ms_ ? kStallMs : kStartupGraceMs)) return true;
    }
    return false;
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
        if (rc >= 0 && streams_stalled_locked(unixio::monotonic_ms())) {
          // The camera function is independent from the 1473 UAC/control
          // composite. Recover only the camera device: resetting the audio
          // runtime here races snd-usb-audio and can break both subsystems.
          (void)device_.reset_device();
          rc = -ETIMEDOUT;
        }
        if (rc < 0) close_device_locked();
      }
      if (rc < 0) unixio::retry_sleep(500);
    }
  }

  kinectusb::DeviceInfo device_info_;
  kinectusb::Camera device_;
  std::atomic<bool> running_{false};
  std::thread worker_;
  std::mutex dev_mu_;
  std::mutex frame_mu_;
  std::condition_variable cv_;
  std::atomic<bool> online_{false};
  int rgb_users_ = 0;
  int hq_rgb_users_ = 0;
  int ir_users_ = 0;
  int depth_users_ = 0;
  bool video_on_ = false;
  bool depth_on_ = false;
  uint64_t video_started_ms_ = 0, depth_started_ms_ = 0;
  uint64_t last_video_frame_ms_ = 0, last_depth_frame_ms_ = 0;
  bool ir_mode_ = false;
  bool hq_mode_ = false;
  uint64_t rgb_seq_counter_ = 0, hq_rgb_seq_counter_ = 0, ir_seq_counter_ = 0, depth_seq_counter_ = 0;
  std::deque<Frame> rgb_queue_, hq_rgb_queue_, ir_queue_, depth_queue_;
};

void client(std::shared_ptr<CameraHub> hub, int fd) {
  scanner::Request request{};
  scanner::Reply reply{};
  if (!unixio::read_exact(fd, &request, sizeof(request)) || request.magic != scanner::kMagic ||
      request.version != scanner::kVersion || request.command != scanner::Command::SubscribeStreams) {
    ::close(fd);
    return;
  }

  const int rc = hub->acquire(request.streamMask);
  reply.result = rc;
  if (rc == 0) { reply.acceptedMask = request.streamMask; hub->fill_reply(reply); }
  unixio::write_all(fd, &reply, sizeof(reply));
  if (rc < 0) {
    ::close(fd);
    return;
  }

  uint64_t rgb_seq = 0, hq_rgb_seq = 0, ir_seq = 0, depth_seq = 0;
  while (run) {
    scanner::FrameHeader header{};
    std::vector<uint8_t> data;
    if (!hub->wait_next(request.streamMask, rgb_seq, hq_rgb_seq, ir_seq, depth_seq, header, data)) break;
    if (header.frameNumber == 0) continue;
    if (!unixio::write_all(fd, &header, sizeof(header)) || !unixio::write_all(fd, data.data(), data.size())) break;
  }
  hub->release(request.streamMask);
  ::close(fd);
}
}  // namespace

class CameraNode {
 public:
  explicit CameraNode(const kinectusb::DeviceInfo& info)
      : info_(info), endpoint_(std::string(kRuntimeDir) + "/devices/" + info.id + ".sock"), hub_(std::make_shared<CameraHub>(info)) {}
  const std::string& endpoint() const { return endpoint_; }
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
    const int fd = unixio::server_socket(endpoint_, 0666, 32);
    if (fd < 0) { std::perror(("scanner socket " + endpoint_).c_str()); running_ = false; return; }
    server_ = fd;
    while (running_.load() && run.load()) {
      const int connection = ::accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
      if (connection < 0) {
        if (errno == EINTR) continue;
        if (!running_.load() || !run.load()) break;
        unixio::retry_sleep(50); continue;
      }
      auto hub = hub_;
      std::thread([hub, connection] { client(hub, connection); }).detach();
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

void write_manifest(const std::vector<kinectusb::DeviceInfo>& present,
                    const std::map<std::string, std::unique_ptr<CameraNode>>& nodes) {
  namespace fs = std::filesystem;
  const fs::path dir = fs::path(kRuntimeDir);
  fs::create_directories(dir / "devices");
  const fs::path tmp = dir / "devices.tsv.tmp";
  const fs::path dst = dir / "devices.tsv";
  {
    std::ofstream out(tmp, std::ios::trunc);
    out << "# id\tlabel\tcamera\n";
    for (const auto& info : present) {
      auto it = nodes.find(info.id);
      if (it == nodes.end()) continue;
      out << info.id << '\t' << info.label << '\t' << it->second->endpoint() << '\n';
    }
  }
  std::error_code ec;
  fs::rename(tmp, dst, ec);
  if (ec) { fs::remove(dst, ec); ec.clear(); fs::rename(tmp, dst, ec); }
  if (!ec) ::chmod(dst.c_str(), 0644);
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
  std::vector<std::string> signature;
  while (run.load()) {
    const auto present = kinectusb::enumerate();
    std::vector<std::string> next_signature;
    for (const auto& info : present) {
      next_signature.push_back(info.id);
      if (nodes.find(info.id) == nodes.end()) {
        auto node = std::make_unique<CameraNode>(info);
        node->start();
        nodes.emplace(info.id, std::move(node));
      }
    }

    // Remove physical-camera workers that disappeared. Keeping stale CameraNode
    // instances made Linux retry an unplugged USB path forever and could leave
    // the manifest/runtime sockets out of sync with Windows hot-plug behavior.
    for (auto it = nodes.begin(); it != nodes.end();) {
      if (std::find(next_signature.begin(), next_signature.end(), it->first) == next_signature.end()) {
        it->second->stop();
        it = nodes.erase(it);
      } else {
        ++it;
      }
    }

    if (next_signature != signature) { signature = next_signature; write_manifest(present, nodes); }
    for (int i = 0; i < 10 && run.load(); ++i) unixio::retry_sleep(100);
  }

  for (auto& entry : nodes) entry.second->stop();
  ::unlink((std::string(kRuntimeDir) + "/devices.tsv").c_str());
  return 0;
}
