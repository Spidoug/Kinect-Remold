#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <libusb-1.0/libusb.h>

#include "remold/hardware_profile.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {

std::atomic<bool> run{true};
std::atomic<uint64_t> alsa_reads{0};
std::atomic<uint64_t> published_frames{0};
std::atomic<uint64_t> runtime_sessions{0};
std::atomic<int> last_error{0};
std::atomic<int> capture_sample_rate{0};
std::atomic<int> capture_channels{0};
std::atomic<int> capture_bits{0};

enum class FirmwareState : int { Idle, Uploading, Launched, ErrorRetrying };
std::atomic<FirmwareState> firmware_state{FirmwareState::Idle};

void stop_handler(int) {
  run = false;
}

constexpr uint32_t kCommandMagic = 0x06022009u;
constexpr uint32_t kStatusMagic = 0x0A6FE000u;
constexpr uint32_t kFirmwareLoadAddress = 0x00080000u;
constexpr uint32_t kFirmwareEntryAddress = 0x00080030u;
constexpr int kUsbTimeoutMs = 10000;
constexpr int kPostFirmwareDelayMs = 1500;
constexpr int kAudioRetryMs = 500;
constexpr int kReconnectGraceSeconds = 30;
constexpr int kLocalClientTimeoutMs = 2000;
constexpr std::size_t kMaxAudioSubscribers = 32;

#pragma pack(push, 1)
struct BootCommand {
  uint32_t magic;
  uint32_t tag;
  uint32_t bytes;
  uint32_t command;
  uint32_t address;
  uint32_t unknown;
};

struct BootStatus {
  uint32_t magic;
  uint32_t tag;
  uint32_t status;
};
#pragma pack(pop)

std::string physical_id_from_sysfs(const std::filesystem::path& path) {
  std::error_code ec;
  const auto canonical = std::filesystem::canonical(path, ec);
  if (ec) return {};

  const std::regex usb(R"(^([0-9]+)-([0-9]+(?:\.[0-9]+)*)$)");
  std::smatch match;

  for (auto it = canonical.end(); it != canonical.begin();) {
    --it;
    const std::string part = it->string();
    if (!std::regex_match(part, match, usb)) continue;

    const int bus = std::stoi(match[1].str());
    std::string ports = match[2].str();
    const auto dot = ports.rfind('.');
    if (dot != std::string::npos) ports.erase(dot);

    std::ostringstream out;
    out << "usb-" << std::setfill('0') << std::setw(3) << bus << '-' << ports;
    return out.str();
  }

  return {};
}

bool read_usb_hex(const std::filesystem::path& path, uint16_t& value) {
  std::ifstream input(path);
  std::string text;
  if (!(input >> text)) return false;
  try {
    const unsigned long parsed = std::stoul(text, nullptr, 16);
    if (parsed > 0xfffful) return false;
    value = static_cast<uint16_t>(parsed);
    return true;
  } catch (...) {
    return false;
  }
}

bool is_kinect_runtime_audio_sysfs(const std::filesystem::path& path) {
  std::error_code ec;
  auto current = std::filesystem::canonical(path, ec);
  if (ec) return false;

  while (!current.empty()) {
    uint16_t vid = 0, pid = 0;
    if (read_usb_hex(current / "idVendor", vid) && read_usb_hex(current / "idProduct", pid)) {
      return vid == hardware::kMicrosoftVid && hardware::is_audio_runtime_pid(pid);
    }
    const auto parent = current.parent_path();
    if (parent == current) break;
    current = parent;
  }
  return false;
}

struct PcmInfo {
  std::string id;
  std::string name;
};

std::string physical_id_from_usb(libusb_device* device) {
  std::array<uint8_t, 8> ports{};
  const int count = libusb_get_port_numbers(device, ports.data(), static_cast<int>(ports.size()));
  if (count <= 0) return {};
  const int physical_components = std::max(1, count - 1);
  std::ostringstream out;
  out << "usb-" << std::setfill('0') << std::setw(3)
      << static_cast<unsigned>(libusb_get_bus_number(device)) << '-';
  for (int i = 0; i < physical_components; ++i) {
    if (i) out << '.';
    out << static_cast<unsigned>(ports[static_cast<size_t>(i)]);
  }
  return out.str();
}

std::vector<std::string> find_physical_sensors(libusb_context* context) {
  std::vector<std::string> result;
  libusb_device** devices = nullptr;
  const ssize_t count = libusb_get_device_list(context, &devices);
  if (count < 0) return result;

  for (ssize_t i = 0; i < count; ++i) {
    libusb_device_descriptor descriptor{};
    if (libusb_get_device_descriptor(devices[i], &descriptor) != 0 || descriptor.idVendor != hardware::kMicrosoftVid) continue;
    // 02C2 is the 1473 parent hub/controller, not a sibling function. It has
    // a different topology depth and must not create a phantom physical ID.
    const bool known = descriptor.idProduct == hardware::kMotor1414Pid ||
        descriptor.idProduct == hardware::kCameraPid ||
        descriptor.idProduct == hardware::kAudioBootPid ||
        hardware::is_audio_runtime_pid(descriptor.idProduct);
    if (!known) continue;
    const std::string id = physical_id_from_usb(devices[i]);
    if (!id.empty()) result.push_back(id);
  }
  libusb_free_device_list(devices, 1);
  std::sort(result.begin(), result.end());
  result.erase(std::unique(result.begin(), result.end()), result.end());
  return result;
}

// The camera function anchors the physical sensor identity. Audio functions may
// re-enumerate at a different USB depth and are associated back to that identity.
std::vector<std::string> find_camera_sensors(libusb_context* context) {
  std::vector<std::string> result;
  libusb_device** devices = nullptr;
  const ssize_t count = libusb_get_device_list(context, &devices);
  if (count < 0) return result;

  for (ssize_t i = 0; i < count; ++i) {
    libusb_device_descriptor descriptor{};
    if (libusb_get_device_descriptor(devices[i], &descriptor) != 0 ||
        descriptor.idVendor != hardware::kMicrosoftVid ||
        descriptor.idProduct != hardware::kCameraPid) {
      continue;
    }
    const std::string id = physical_id_from_usb(devices[i]);
    if (!id.empty()) result.push_back(id);
  }

  libusb_free_device_list(devices, 1);
  std::sort(result.begin(), result.end());
  result.erase(std::unique(result.begin(), result.end()), result.end());
  return result;
}

std::vector<PcmInfo> find_pcms() {
  std::vector<PcmInfo> result;
  std::error_code ec;
  std::filesystem::directory_iterator it("/sys/class/sound", ec);
  const std::filesystem::directory_iterator end;
  if (ec) return result;

  for (; it != end; it.increment(ec)) {
    if (ec) {
      ec.clear();
      continue;
    }

    const std::string entryName = it->path().filename().string();
    if (entryName.rfind("card", 0) != 0) continue;

    const std::string card = entryName.substr(4);
    const bool numericCard = !card.empty() &&
        std::all_of(card.begin(), card.end(), [](unsigned char c) {
          return std::isdigit(c) != 0;
        });
    if (!numericCard) continue;

    const auto sysfs_device = it->path() / "device";
    // Do not bind an arbitrary USB microphone to a Kinect physical ID. Only
    // accept the Microsoft Kinect UAC runtime functions (02BB/02C3).
    if (!is_kinect_runtime_audio_sysfs(sysfs_device)) continue;
    const std::string id = physical_id_from_sysfs(sysfs_device);
    if (id.empty()) continue;

    for (int device = 0; device < 8; ++device) {
      const auto capture = std::filesystem::path("/sys/class/sound") /
          ("pcmC" + card + "D" + std::to_string(device) + "c");
      if (std::filesystem::exists(capture, ec)) {
        result.push_back({id, "hw:" + card + "," + std::to_string(device)});
        break;
      }
      ec.clear();
    }
  }

  std::sort(result.begin(), result.end(), [](const PcmInfo& a, const PcmInfo& b) {
    if (a.id != b.id) return a.id < b.id;
    return a.name < b.name;
  });
  return result;
}

struct PcmBindings {
  std::map<std::string, std::string> current;
  std::size_t topology_matches = 0;
  std::size_t fallback_matches = 0;
};

// Bind by physical USB identity first. An unresolved Kinect UAC endpoint is
// assigned only when the remaining sensor association is unambiguous.
PcmBindings bind_pcms_to_sensors(
    const std::vector<PcmInfo>& pcms,
    const std::vector<std::string>& sensors) {
  PcmBindings bindings;
  std::set<std::string> assigned;
  std::vector<const PcmInfo*> unresolved;

  for (const auto& pcm : pcms) {
    if (std::find(sensors.begin(), sensors.end(), pcm.id) != sensors.end() &&
        assigned.count(pcm.id) == 0) {
      bindings.current[pcm.id] = pcm.name;
      assigned.insert(pcm.id);
      ++bindings.topology_matches;
    } else {
      unresolved.push_back(&pcm);
    }
  }

  std::vector<std::string> remaining;
  for (const auto& id : sensors) {
    if (assigned.count(id) == 0) remaining.push_back(id);
  }

  if (unresolved.size() == 1u && remaining.size() == 1u) {
    bindings.current[remaining.front()] = unresolved.front()->name;
    ++bindings.fallback_matches;
  } else if (sensors.size() == 1u && bindings.current.empty() && !unresolved.empty()) {
    // A Kinect UAC runtime exposes one capture PCM in normal operation. If a
    // distro happens to enumerate aliases for it, use the first deterministic
    // ALSA hardware PCM rather than creating phantom Kinect identities.
    bindings.current[sensors.front()] = unresolved.front()->name;
    ++bindings.fallback_matches;
  }

  return bindings;
}

class Fanout {
 public:
  explicit Fanout(std::string path) : path_(std::move(path)) {}

  ~Fanout() {
    stop();
  }

  bool start() {
    stopping_ = false;
    server_ = unixio::local_server_socket(path_, 32);
    if (server_ < 0) return false;

    thread_ = std::thread([this] { accept_loop(); });
    return true;
  }

  void stop() {
    stopping_ = true;
    if (server_ >= 0) {
      ::shutdown(server_, SHUT_RDWR);
      ::close(server_);
      server_ = -1;
    }

    if (thread_.joinable()) thread_.join();

    std::lock_guard<std::mutex> guard(mu_);
    for (const int client : clients_) ::close(client);
    clients_.clear();
    ::unlink(path_.c_str());
  }

  void publish(const int32_t* data, uint32_t channel_mask, uint64_t frame, int volume, bool muted) {
    std::array<int32_t, audio::kChannels * audio::kSamples> adjusted{};
    const double gain = muted ? 0.0 : std::clamp(volume, 0, 100) / 100.0;

    for (size_t i = 0; i < adjusted.size(); ++i) {
      const double value = static_cast<double>(data[i]) * gain;
      adjusted[i] = static_cast<int32_t>(std::clamp(
          value,
          static_cast<double>(INT32_MIN),
          static_cast<double>(INT32_MAX)));
    }

    audio::FrameHeader header{};
    header.channelMask = channel_mask;
    header.frameNumber = frame;
    header.tickMs = unixio::monotonic_ms();

    std::lock_guard<std::mutex> guard(mu_);
    for (auto it = clients_.begin(); it != clients_.end();) {
      const bool headerWritten = unixio::write_all_nonblocking(*it, &header, sizeof(header));
      const bool payloadWritten = headerWritten &&
          unixio::write_all_nonblocking(*it, adjusted.data(), audio::kPayloadBytes);
      if (!payloadWritten) {
        ::close(*it);
        it = clients_.erase(it);
      } else {
        ++it;
      }
    }
  }

 private:
  void accept_loop() {
    while (!stopping_ && run) {
      const int client = ::accept4(server_, nullptr, nullptr, SOCK_CLOEXEC);
      if (client < 0) {
        if (errno == EINTR) continue;
        if (stopping_) break;
        unixio::retry_sleep(50);
        continue;
      }
      if (!unixio::set_io_timeout(client, kLocalClientTimeoutMs)) {
        ::close(client);
        continue;
      }

      audio::Request request{};
      audio::Reply reply{};
      const bool accepted = unixio::read_exact(client, &request, sizeof(request)) &&
          request.magic == audio::kMagic &&
          request.version == audio::kVersion &&
          request.command == audio::Command::SubscribeMicrophones &&
          unixio::write_all(client, &reply, sizeof(reply));
      if (!accepted) {
        ::close(client);
        continue;
      }

      std::lock_guard<std::mutex> guard(mu_);
      if (clients_.size() >= kMaxAudioSubscribers) {
        ::close(client);
        continue;
      }
      clients_.push_back(client);
    }
  }

  std::string path_;
  int server_ = -1;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  std::mutex mu_;
  std::vector<int> clients_;
};

class AudioNode {
 public:
  explicit AudioNode(std::string id)
      : id_(std::move(id)),
        audio_path_(std::string(kAudioDirectory) + "/" + id_ + ".sock"),
        control_path_(std::string(kAudioDirectory) + "/" + id_ + "-control.sock"),
        fanout_(audio_path_) {}

  ~AudioNode() {
    stop();
  }

  bool start() {
    if (started_.exchange(true)) return true;

    if (!fanout_.start()) {
      started_ = false;
      return false;
    }

    control_server_ = unixio::local_server_socket(control_path_, 16);
    if (control_server_ < 0) {
      fanout_.stop();
      started_ = false;
      return false;
    }

    capture_thread_ = std::thread([this] { capture_loop(); });
    control_thread_ = std::thread([this] { control_loop(); });
    return true;
  }

  void mark_present() {
    std::lock_guard<std::mutex> guard(mu_);
    last_seen_ = std::chrono::steady_clock::now();
  }

  void update_pcm(const std::string& pcm) {
    std::lock_guard<std::mutex> guard(mu_);
    pcm_ = pcm;
    last_seen_ = std::chrono::steady_clock::now();
  }

  void mark_missing() {
    {
      std::lock_guard<std::mutex> guard(mu_);
      pcm_.clear();
    }
  }

  bool expired(std::chrono::steady_clock::time_point now) const {
    std::lock_guard<std::mutex> guard(mu_);
    return pcm_.empty() &&
        now - last_seen_ >= std::chrono::seconds(kReconnectGraceSeconds);
  }

  void stop() {
    if (!started_.exchange(false)) return;

    if (control_server_ >= 0) {
      ::shutdown(control_server_, SHUT_RDWR);
      ::close(control_server_);
      control_server_ = -1;
    }

    if (control_thread_.joinable()) control_thread_.join();
    if (capture_thread_.joinable()) capture_thread_.join();

    fanout_.stop();
    ::unlink(control_path_.c_str());
  }

 private:
  std::string current_pcm() const {
    std::lock_guard<std::mutex> guard(mu_);
    return pcm_;
  }

  // Native sample encodings accepted from the Kinect UAC capture interface.
  static int32_t read_sample(const uint8_t* sample, snd_pcm_format_t format) {
    switch (format) {
      case SND_PCM_FORMAT_S16_LE: {
        int16_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return static_cast<int32_t>(value) * 65536;
      }
      case SND_PCM_FORMAT_S24_3LE: {
        int32_t value = static_cast<int32_t>(sample[0]) | (static_cast<int32_t>(sample[1]) << 8) |
            (static_cast<int32_t>(sample[2]) << 16);
        if (value & 0x00800000) value |= static_cast<int32_t>(0xff000000u);
        return value * 256;
      }
      case SND_PCM_FORMAT_S24_LE: {
        int32_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        value &= 0x00ffffff;
        if (value & 0x00800000) value |= static_cast<int32_t>(0xff000000u);
        return value * 256;
      }
      case SND_PCM_FORMAT_S32_LE: {
        int32_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return value;
      }
      case SND_PCM_FORMAT_FLOAT_LE: {
        float value = 0.0f;
        std::memcpy(&value, sample, sizeof(value));
        if (!std::isfinite(value)) value = 0.0f;
        value = std::clamp(value, -1.0f, 1.0f);
        return static_cast<int32_t>(static_cast<double>(value) * 2147483647.0);
      }
      default:
        return 0;
    }
  }

  // Opens the capture PCM in its native format, like a shared WASAPI stream on
  // Windows: S32LE is preferred, other integer/float encodings, up to four
  // channels and any rate from 16 kHz up are converted to the product frame.
  bool configure_capture(snd_pcm_t* pcm, snd_pcm_format_t& format, unsigned& channels, unsigned& rate) {
    snd_pcm_hw_params_t* hardware = nullptr;
    snd_pcm_hw_params_alloca(&hardware);
    auto ok = [](int result) {
      if (result >= 0) return true;
      last_error = result;
      return false;
    };
    if (!ok(snd_pcm_hw_params_any(pcm, hardware)) ||
        !ok(snd_pcm_hw_params_set_access(pcm, hardware, SND_PCM_ACCESS_RW_INTERLEAVED))) return false;

    format = SND_PCM_FORMAT_UNKNOWN;
    for (const auto candidate : {SND_PCM_FORMAT_S32_LE, SND_PCM_FORMAT_S24_LE, SND_PCM_FORMAT_S24_3LE,
                                 SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_FLOAT_LE}) {
      if (snd_pcm_hw_params_test_format(pcm, hardware, candidate) == 0) {
        format = candidate;
        break;
      }
    }
    if (format == SND_PCM_FORMAT_UNKNOWN) {
      last_error = -EINVAL;
      return false;
    }
    if (!ok(snd_pcm_hw_params_set_format(pcm, hardware, format))) return false;

    channels = audio::kChannels;
    if (!ok(snd_pcm_hw_params_set_channels_near(pcm, hardware, &channels))) return false;
    rate = audio::kSampleRate;
    if (!ok(snd_pcm_hw_params_set_rate_near(pcm, hardware, &rate, nullptr))) return false;
    if (rate < audio::kSampleRate || rate > 192000 || channels == 0) {
      last_error = -EINVAL;
      return false;
    }

    snd_pcm_uframes_t period = audio::kSamples;
    if (!ok(snd_pcm_hw_params_set_period_size_near(pcm, hardware, &period, nullptr))) return false;
    // A few periods of buffering absorbs ordinary scheduler jitter without
    // changing the product's fixed 256-sample application frame.
    snd_pcm_uframes_t buffer_frames = std::max<snd_pcm_uframes_t>(period * 4u, audio::kSamples * 4u);
    const int buffer_rc = snd_pcm_hw_params_set_buffer_size_near(pcm, hardware, &buffer_frames);
    if (buffer_rc < 0 && buffer_rc != -EINVAL) return ok(buffer_rc);
    return ok(snd_pcm_hw_params(pcm, hardware));
  }

  void capture_loop() {
    uint64_t frame = 0;
    std::vector<int32_t> product(audio::kChannels * audio::kSamples);
    std::vector<uint8_t> native;

    while (started_ && run) {
      const std::string name = current_pcm();
      if (name.empty()) {
        unixio::retry_sleep(200);
        continue;
      }

      snd_pcm_t* pcm = nullptr;
      int rc = snd_pcm_open(&pcm, name.c_str(), SND_PCM_STREAM_CAPTURE, 0);
      if (rc < 0) {
        last_error = rc;
        unixio::retry_sleep(400);
        continue;
      }

      snd_pcm_format_t format = SND_PCM_FORMAT_UNKNOWN;
      unsigned channels = 0;
      unsigned rate = 0;
      if (!configure_capture(pcm, format, channels, rate) || (rc = snd_pcm_prepare(pcm)) < 0) {
        if (rc < 0) last_error = rc;
        snd_pcm_close(pcm);
        unixio::retry_sleep(400);
        continue;
      }

      const std::size_t sample_bytes = static_cast<std::size_t>(snd_pcm_format_physical_width(format) / 8);
      const std::size_t frame_bytes = sample_bytes * channels;
      const unsigned active_channels = std::min<unsigned>(channels, audio::kChannels);
      const uint32_t channel_mask = (1u << active_channels) - 1u;
      capture_sample_rate = static_cast<int>(rate);
      capture_channels = static_cast<int>(channels);
      capture_bits = snd_pcm_format_physical_width(format);
      if (current_pcm() != name) {
        snd_pcm_close(pcm);
        continue;
      }
      runtime_sessions.fetch_add(1, std::memory_order_relaxed);
      last_error = 0;

      // Rates above 16 kHz are decimated with one phase accumulator for all
      // channels so their relative timing stays aligned exactly as on Windows.
      constexpr snd_pcm_uframes_t kReadFrames = audio::kSamples;
      native.resize(frame_bytes * kReadFrames);
      uint64_t phase = 0;
      uint32_t filled = 0;
      while (started_ && run && current_pcm() == name) {
        const snd_pcm_sframes_t read = snd_pcm_readi(pcm, native.data(), kReadFrames);
        if (read < 0) {
          last_error = static_cast<int>(read);
          // snd_pcm_recover covers XRUN (-EPIPE) and suspend (-ESTRPIPE)
          // without disturbing Kinect MI_00 control.
          const int recover = snd_pcm_recover(pcm, static_cast<int>(read), 1);
          filled = 0;
          if (recover < 0) {
            last_error = recover;
            break;
          }
          continue;
        }
        if (read == 0) continue;
        alsa_reads.fetch_add(1, std::memory_order_relaxed);
        for (snd_pcm_sframes_t i = 0; i < read; ++i) {
          phase += audio::kSampleRate;
          if (phase < rate) continue;
          phase -= rate;
          const uint8_t* source = native.data() + static_cast<std::size_t>(i) * frame_bytes;
          int32_t* target = product.data() + static_cast<std::size_t>(filled) * audio::kChannels;
          for (unsigned channel = 0; channel < audio::kChannels; ++channel) {
            target[channel] = channel < active_channels ? read_sample(source + channel * sample_bytes, format) : 0;
          }
          if (++filled == audio::kSamples) {
            fanout_.publish(product.data(), channel_mask, ++frame, volume_.load(), muted_.load());
            published_frames.fetch_add(1, std::memory_order_relaxed);
            last_error = 0;
            filled = 0;
          }
        }
      }

      snd_pcm_close(pcm);
      unixio::retry_sleep(150);
    }
  }

  void control_loop() {
    while (started_ && run) {
      const int client = ::accept4(control_server_, nullptr, nullptr, SOCK_CLOEXEC);
      if (client < 0) {
        if (errno == EINTR) continue;
        if (!started_) break;
        unixio::retry_sleep(50);
        continue;
      }
      if (!unixio::set_io_timeout(client, kLocalClientTimeoutMs)) {
        ::close(client);
        continue;
      }

      audio_control::Request request{};
      audio_control::Reply reply{};
      const bool valid = unixio::read_exact(client, &request, sizeof(request)) &&
          request.magic == audio_control::kMagic &&
          request.version == audio_control::kVersion;
      if (!valid) {
        ::close(client);
        continue;
      }

      switch (request.command) {
        case audio_control::Command::Ping:
        case audio_control::Command::Get:
          // Per-Kinect mixer state stays available while capture reconnects.
          break;
        case audio_control::Command::SetVolume:
          volume_ = std::clamp(request.value, 0, 100);
          break;
        case audio_control::Command::SetMute:
          muted_ = request.value ? 1 : 0;
          break;
        default:
          reply.result = -EINVAL;
          break;
      }

      reply.volume = volume_.load();
      reply.muted = muted_.load();
      (void)unixio::write_all(client, &reply, sizeof(reply));
      ::close(client);
    }
  }

  std::string id_;
  std::string audio_path_;
  std::string control_path_;
  Fanout fanout_;
  mutable std::mutex mu_;
  std::string pcm_;
  std::chrono::steady_clock::time_point last_seen_ = std::chrono::steady_clock::now();
  std::atomic<bool> started_{false};
  std::atomic<int> volume_{100};
  std::atomic<int> muted_{0};
  int control_server_ = -1;
  std::thread capture_thread_;
  std::thread control_thread_;
};

struct UsbBoot {
  std::string physical_id;
  libusb_device_handle* handle = nullptr;
  int interface_number = -1;
  int alternate_setting = 0;
  uint8_t endpoint_in = 0x81;
  uint8_t endpoint_out = 0x01;
  bool claimed = false;

  ~UsbBoot() {
    if (!handle) return;
    if (claimed) libusb_release_interface(handle, interface_number);
    libusb_close(handle);
  }
};

std::unique_ptr<UsbBoot> open_boot_device(libusb_device* device) {
  libusb_device_handle* handle = nullptr;
  if (libusb_open(device, &handle) != 0 || !handle) return {};

  auto session = std::make_unique<UsbBoot>();
  session->physical_id = physical_id_from_usb(device);
  session->handle = handle;

  libusb_config_descriptor* config = nullptr;
  if (libusb_get_active_config_descriptor(device, &config) != 0 &&
      libusb_get_config_descriptor(device, 0, &config) != 0) {
    return {};
  }

  for (uint8_t i = 0; i < config->bNumInterfaces && session->interface_number < 0; ++i) {
    const libusb_interface& interface = config->interface[i];
    for (int a = 0; a < interface.num_altsetting; ++a) {
      const libusb_interface_descriptor& alternate = interface.altsetting[a];
      bool hasIn = false;
      bool hasOut = false;

      for (uint8_t e = 0; e < alternate.bNumEndpoints; ++e) {
        const libusb_endpoint_descriptor& endpoint = alternate.endpoint[e];
        if ((endpoint.bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
        if (endpoint.bEndpointAddress == session->endpoint_in) hasIn = true;
        if (endpoint.bEndpointAddress == session->endpoint_out) hasOut = true;
      }

      if (hasIn && hasOut) {
        session->interface_number = alternate.bInterfaceNumber;
        session->alternate_setting = alternate.bAlternateSetting;
        break;
      }
    }
  }

  libusb_free_config_descriptor(config);
  if (session->interface_number < 0) return {};

  if (libusb_kernel_driver_active(handle, session->interface_number) == 1) {
    (void)libusb_detach_kernel_driver(handle, session->interface_number);
  }
  if (libusb_claim_interface(handle, session->interface_number) != 0) return {};
  session->claimed = true;
  if (session->alternate_setting != 0 &&
      libusb_set_interface_alt_setting(
          handle,
          session->interface_number,
          session->alternate_setting) != 0) {
    return {};
  }

  return session;
}

std::vector<std::unique_ptr<UsbBoot>> open_boot_devices(libusb_context* context) {
  std::vector<std::unique_ptr<UsbBoot>> result;
  libusb_device** devices = nullptr;
  const ssize_t count = libusb_get_device_list(context, &devices);
  if (count < 0) return result;

  for (ssize_t i = 0; i < count; ++i) {
    libusb_device_descriptor descriptor{};
    if (libusb_get_device_descriptor(devices[i], &descriptor) != 0) continue;
    if (descriptor.idVendor != hardware::kMicrosoftVid || descriptor.idProduct != hardware::kAudioBootPid) continue;

    if (auto session = open_boot_device(devices[i])) result.push_back(std::move(session));
  }

  libusb_free_device_list(devices, 1);
  return result;
}

bool bulk_write(UsbBoot& session, const void* data, int bytes) {
  int transferred = 0;
  const int rc = libusb_bulk_transfer(
      session.handle,
      session.endpoint_out,
      static_cast<unsigned char*>(const_cast<void*>(data)),
      bytes,
      &transferred,
      kUsbTimeoutMs);
  if (rc != 0) {
    last_error = rc;
    return false;
  }
  if (transferred != bytes) {
    last_error = -EIO;
    return false;
  }
  return true;
}

bool bulk_read_packet(
    UsbBoot& session,
    void* data,
    int capacity,
    int expected_bytes = 0,
    int* transfer_error = nullptr) {
  int transferred = 0;
  const int rc = libusb_bulk_transfer(
      session.handle,
      session.endpoint_in,
      static_cast<unsigned char*>(data),
      capacity,
      &transferred,
      kUsbTimeoutMs);
  if (transfer_error) *transfer_error = rc;
  if (rc != 0) {
    last_error = rc;
    return false;
  }
  const bool valid = expected_bytes > 0 ? transferred == expected_bytes : transferred > 0;
  if (!valid) {
    if (transfer_error) *transfer_error = -EMSGSIZE;
    last_error = -EMSGSIZE;
  }
  return valid;
}

bool is_launch_disconnect(int error) {
  // Only transport errors that indicate device removal complete the firmware
  // handoff. A timeout keeps the 02AD boot state eligible for another attempt.
  return error == LIBUSB_ERROR_NO_DEVICE ||
      error == LIBUSB_ERROR_IO ||
      error == LIBUSB_ERROR_INTERRUPTED;
}

bool boot_status_ok(UsbBoot& session, uint32_t tag) {
  std::array<uint8_t, 512> reply{};
  if (!bulk_read_packet(session, reply.data(), static_cast<int>(reply.size()), sizeof(BootStatus))) return false;
  BootStatus status{};
  std::memcpy(&status, reply.data(), sizeof(status));
  return status.magic == kStatusMagic &&
      status.tag == tag &&
      status.status == 0;
}

bool upload_firmware(UsbBoot& session, const std::vector<uint8_t>& firmware) {
  uint32_t tag = 1;
  BootCommand probe{kCommandMagic, tag, 0x60, 0, 0x15, 0};
  // The version reply is variable-length; any non-empty packet followed by a
  // successful boot status is accepted.
  std::array<uint8_t, 512> versionReply{};
  if (!bulk_write(session, &probe, sizeof(probe)) ||
      !bulk_read_packet(session, versionReply.data(), static_cast<int>(versionReply.size())) ||
      !boot_status_ok(session, tag)) {
    return false;
  }

  ++tag;
  uint32_t address = kFirmwareLoadAddress;
  for (size_t offset = 0; offset < firmware.size() && run;) {
    const uint32_t page = static_cast<uint32_t>(
        std::min<size_t>(16 * 1024, firmware.size() - offset));
    BootCommand command{kCommandMagic, tag, page, 3, address, 0};
    if (!bulk_write(session, &command, sizeof(command))) return false;

    for (uint32_t pageOffset = 0; pageOffset < page;) {
      const uint32_t chunk = std::min<uint32_t>(512, page - pageOffset);
      if (!bulk_write(session, firmware.data() + offset + pageOffset, chunk)) return false;
      pageOffset += chunk;
    }

    if (!boot_status_ok(session, tag)) return false;
    offset += page;
    address += page;
    ++tag;
  }

  BootCommand launch{kCommandMagic, tag, 0, 4, kFirmwareEntryAddress, 0};
  if (!bulk_write(session, &launch, sizeof(launch))) return false;

  std::array<uint8_t, 512> reply{};
  int finalReadError = 0;
  if (!bulk_read_packet(
          session, reply.data(), static_cast<int>(reply.size()), sizeof(BootStatus),
          &finalReadError)) {
    // Device disappearance after launch indicates a successful firmware handoff.
    // Timeout and short-reply failures remain retryable.
    return is_launch_disconnect(finalReadError);
  }
  BootStatus status{};
  std::memcpy(&status, reply.data(), sizeof(status));
  return status.magic == kStatusMagic && status.tag == tag && status.status == 0;
}

std::vector<uint8_t> read_firmware() {
  std::ifstream file(kFirmwarePath, std::ios::binary);
  if (!file) return {};
  return std::vector<uint8_t>(
      std::istreambuf_iterator<char>(file),
      std::istreambuf_iterator<char>());
}

void write_runtime_status(
    size_t nodes,
    const std::string& stage,
    size_t sensors = 0,
    size_t pcm_candidates = 0,
    size_t topology_bindings = 0,
    size_t fallback_bindings = 0) {
  std::error_code directory_error;
  std::filesystem::create_directories(kRuntimeDir, directory_error);
  if (directory_error) return;

  const std::string target = kAudioStatus;
  const std::string temporary = target + ".tmp";

  std::ofstream out(temporary, std::ios::trunc);
  if (!out) return;
  out << "version=1\n"
      << "heartbeat_ms=" << unixio::monotonic_ms() << "\n"
      << "audio_transport_model=usb-boot-uac-runtime-alsa\n"
      << "boot_usb_pid=02ad\n"
      << "runtime_usb_pid_family=02bb,02c3\n"
      << "runtime_capture=alsa-hardware\n"
      << "raw_audio_bus=per-device-multi-client\n"
      << "uac_channels=4\n"
      << "uac_sample_rate=16000\n"
      << "uac_bits_per_sample=32\n"
      << "audio_nodes=" << nodes << "\n"
      << "physical_sensors=" << sensors << "\n"
      << "pcm_candidates=" << pcm_candidates << "\n"
      << "pcm_topology_bindings=" << topology_bindings << "\n"
      << "pcm_fallback_bindings=" << fallback_bindings << "\n"
      << "stage=" << stage << "\n"
      << "last_error=" << last_error.load(std::memory_order_relaxed) << "\n"
      << "runtime_sessions=" << runtime_sessions.load(std::memory_order_relaxed) << "\n"
      << "alsa_reads=" << alsa_reads.load(std::memory_order_relaxed) << "\n"
      << "published_frames=" << published_frames.load(std::memory_order_relaxed) << "\n"
      << "capture_sample_rate=" << capture_sample_rate.load(std::memory_order_relaxed) << "\n"
      << "capture_channels=" << capture_channels.load(std::memory_order_relaxed) << "\n"
      << "capture_bits=" << capture_bits.load(std::memory_order_relaxed) << "\n";
  out.close();

  std::error_code ec;
  std::filesystem::rename(temporary, target, ec);
  if (ec) {
    std::error_code cleanup;
    std::filesystem::remove(temporary, cleanup);
  }
}

std::string current_runtime_stage(bool physical_empty, bool runtime_bound) {
  switch (firmware_state.load(std::memory_order_acquire)) {
    case FirmwareState::Uploading: return "uac-firmware-uploading";
    case FirmwareState::Launched: return "uac-firmware-launched";
    case FirmwareState::ErrorRetrying: return "uac-firmware-error-retrying";
    case FirmwareState::Idle: break;
  }
  if (runtime_bound) return "uac-runtime-capturing";
  return physical_empty ? "starting" : "uac-search-runtime";
}

void firmware_loop(libusb_context* context, const std::vector<uint8_t>& firmware) {
  // Firmware transition runs independently from endpoint discovery and capture.
  std::set<std::string> launched;
  std::map<std::string, unsigned> absent_passes;
  constexpr unsigned kDisconnectPasses = 6;  // ~3 s at the 500 ms cadence.

  while (run) {
    const auto physical = find_physical_sensors(context);
    for (auto it = launched.begin(); it != launched.end();) {
      if (std::find(physical.begin(), physical.end(), *it) != physical.end()) {
        absent_passes[*it] = 0;
        ++it;
        continue;
      }
      unsigned& passes = absent_passes[*it];
      if (++passes >= kDisconnectPasses) {
        absent_passes.erase(*it);
        it = launched.erase(it);
      } else {
        ++it;
      }
    }

    bool attempted = false;
    bool launched_any = false;
    bool failed = false;
    if (!firmware.empty()) {
      auto boot_devices = open_boot_devices(context);
      for (auto& boot : boot_devices) {
        if (!run) break;
        if (boot->physical_id.empty() || launched.count(boot->physical_id) != 0) continue;
        attempted = true;
        firmware_state.store(FirmwareState::Uploading, std::memory_order_release);
        if (upload_firmware(*boot, firmware)) {
          launched.insert(boot->physical_id);
          absent_passes[boot->physical_id] = 0;
          last_error = 0;
          launched_any = true;
          firmware_state.store(FirmwareState::Launched, std::memory_order_release);
        } else {
          failed = true;
          if (last_error.load(std::memory_order_relaxed) == 0) last_error = -EIO;
          firmware_state.store(FirmwareState::ErrorRetrying, std::memory_order_release);
        }
      }
    }

    if (launched_any) {
      for (int slept = 0; slept < kPostFirmwareDelayMs && run; slept += 50) unixio::retry_sleep(50);
    } else {
      if (!attempted) firmware_state.store(FirmwareState::Idle, std::memory_order_release);
      for (int slept = 0; slept < kAudioRetryMs && run; slept += 50) unixio::retry_sleep(50);
    }
    if (!failed && !launched_any) firmware_state.store(FirmwareState::Idle, std::memory_order_release);
  }
}

void audio_coordinator_loop(libusb_context* context) {
  // Keep one stable logical audio node per physical Kinect.
  std::map<std::string, std::unique_ptr<AudioNode>> nodes;
  while (run) {
    const auto now = std::chrono::steady_clock::now();
    const auto physical = find_physical_sensors(context);
    auto sensors = find_camera_sensors(context);
    if (sensors.empty()) sensors = physical;
    const auto pcms = find_pcms();
    const auto bindings = bind_pcms_to_sensors(pcms, sensors);
    const auto& current = bindings.current;

    for (const auto& id : sensors) {
      auto it = nodes.find(id);
      if (it == nodes.end()) {
        auto node = std::make_unique<AudioNode>(id);
        if (!node->start()) continue;
        it = nodes.emplace(id, std::move(node)).first;
      }
      it->second->mark_present();
    }

    for (const auto& entry : current) {
      auto it = nodes.find(entry.first);
      if (it == nodes.end()) {
        auto node = std::make_unique<AudioNode>(entry.first);
        if (!node->start()) continue;
        it = nodes.emplace(entry.first, std::move(node)).first;
      }
      it->second->update_pcm(entry.second);
    }

    for (auto it = nodes.begin(); it != nodes.end();) {
      if (current.count(it->first) == 0) it->second->mark_missing();
      if (it->second->expired(now)) {
        it->second->stop();
        it = nodes.erase(it);
      } else {
        ++it;
      }
    }

    write_runtime_status(
        nodes.size(), current_runtime_stage(physical.empty(), !current.empty()),
        sensors.size(), pcms.size(), bindings.topology_matches, bindings.fallback_matches);
    for (int slept = 0; slept < kAudioRetryMs && run; slept += 50) unixio::retry_sleep(50);
  }

  for (auto& node : nodes) node.second->stop();
}

}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);
  std::error_code directory_error;
  std::filesystem::create_directories(kAudioDirectory, directory_error);
  if (directory_error) return 3;

  libusb_context* firmware_context = nullptr;
  if (libusb_init(&firmware_context) != 0) return 3;
  libusb_context* coordinator_context = nullptr;
  if (libusb_init(&coordinator_context) != 0) {
    libusb_exit(firmware_context);
    return 3;
  }

  const auto firmware = read_firmware();
  std::thread firmware_thread([&] { firmware_loop(firmware_context, firmware); });
  std::thread coordinator_thread([&] { audio_coordinator_loop(coordinator_context); });

  while (run) unixio::retry_sleep(100);

  if (coordinator_thread.joinable()) coordinator_thread.join();
  if (firmware_thread.joinable()) firmware_thread.join();
  libusb_exit(coordinator_context);
  libusb_exit(firmware_context);
  return 0;
}
