#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

#include <grp.h>
#include <libusb-1.0/libusb.h>
#include <signal.h>

#include "remold/hardware_profile.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
volatile std::sig_atomic_t stop_requested = 0;
volatile std::sig_atomic_t listener_fd = -1;
libusb_context* usb_ctx = nullptr;
std::atomic<uint32_t> active_clients{0};
std::mutex active_clients_mutex;
std::condition_variable active_clients_cv;

constexpr uint32_t kMaxBrokerClients = 64;
constexpr int kClientIoTimeoutMs = 3000;
constexpr unsigned char kAltOut = 0x01;
constexpr unsigned char kAltIn = 0x81;
constexpr uint32_t kAltMagic = 0x06022009u;
constexpr uint32_t kAltReplyMagic = 0x0a6fe000u;
constexpr uint32_t kAltStatus = 0x8032u;
constexpr uint32_t kAltTilt = 0x803bu;
constexpr uint32_t kAltLed = 0x10u;
constexpr int kTiltToleranceTenths = 15;

enum class MotorKind { None, Classic1414, Audio1473 };

#pragma pack(push, 1)
struct AltCommand {
  uint32_t magic;
  uint32_t tag;
  uint32_t arg1;
  uint32_t command;
  uint32_t arg2;
};
struct AltReply {
  uint32_t magic;
  uint32_t tag;
  uint32_t status;
};
#pragma pack(pop)
static_assert(sizeof(AltCommand) == 20);
static_assert(sizeof(AltReply) == 12);

void stop_handler(int) {
  stop_requested = 1;
  const int fd = listener_fd;
  listener_fd = -1;
  if (fd >= 0) ::close(fd);
}

std::string physical_id(libusb_device* device) {
  if (!device) return {};
  std::array<uint8_t, 8> ports{};
  const int count = libusb_get_port_numbers(device, ports.data(), static_cast<int>(ports.size()));
  if (count <= 0) return {};

  // Camera/audio/motor are child functions behind the Kinect's internal USB
  // hub. Removing only that last internal hop gives every function of one
  // physical Kinect the same stable ID while preserving the external hub path.
  const int physical_components = std::max(1, count - 1);
  std::ostringstream id;
  id << "usb-" << std::setfill('0') << std::setw(3)
     << static_cast<unsigned>(libusb_get_bus_number(device)) << '-';
  for (int i = 0; i < physical_components; ++i) {
    if (i) id << '.';
    id << static_cast<unsigned>(ports[static_cast<size_t>(i)]);
  }
  return id.str();
}

std::mutex device_io_mutexes_mutex;
std::map<std::string, std::shared_ptr<std::mutex>> device_io_mutexes;

std::shared_ptr<std::mutex> device_io_mutex_for(const std::string& device_id) {
  const std::string key = device_id.empty() ? "__unknown__" : device_id;
  std::lock_guard<std::mutex> guard(device_io_mutexes_mutex);
  auto& mutex = device_io_mutexes[key];
  if (!mutex) mutex = std::make_shared<std::mutex>();
  return mutex;
}

class MotorSession {
 public:
  explicit MotorSession(std::string device_id) : device_id_(std::move(device_id)) {}
  ~MotorSession() { close_locked(); }

  int status(control::Reply& reply) {
    // Same contract as the Windows broker: Status never queues behind a Tilt.
    // The camera service keeps its last motion sample until it goes stale.
    if (tilt_in_flight_.load(std::memory_order_acquire)) return -EBUSY;
    std::lock_guard<std::mutex> guard(mutex_);
    return with_fresh_handle_retry_locked([&](control::Reply& out) {
      const int rc = read_status_locked(out);
      if (rc == 0) out.transport = control::Transport::PhysicalMotor;
      return rc;
    }, reply);
  }

  int ping(control::Reply& reply) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (!ensure_open_locked()) return -ENODEV;
    reply = {};
    reply.transport = control::Transport::PhysicalMotor;
    return 0;
  }

  int tilt(int requested, control::Reply& reply) {
    const int degrees = std::clamp(requested, hardware::kTiltMinDegrees, hardware::kTiltMaxDegrees);
    const TiltInFlight in_flight(tilt_in_flight_);
    std::lock_guard<std::mutex> guard(mutex_);
    if (!ensure_open_locked()) return -ENODEV;

    if (kind_ == MotorKind::Audio1473) {
      const auto io_mutex = io_mutex_;
      std::lock_guard<std::mutex> io_guard(*io_mutex);
      return tilt_1473_locked(degrees, reply);
    }

    return with_fresh_handle_retry_locked([&](control::Reply& out) {
      const int issue = issue_tilt_1414_locked(degrees);
      if (issue != 0) return issue;
      const int rc = wait_tilt_1414_locked(degrees, out);
      if (rc == 0) out.transport = control::Transport::PhysicalMotor;
      return rc;
    }, reply);
  }

  int led(int mode, control::Reply& reply) {
    if (!(mode == 0 || mode == 1 || mode == 2 || mode == 3 || mode == 4 || mode == 6)) return -EINVAL;
    std::lock_guard<std::mutex> guard(mutex_);
    return with_fresh_handle_retry_locked([&](control::Reply& out) {
      int rc = -ENODEV;
      if (kind_ == MotorKind::Classic1414) rc = set_led_1414_locked(mode);
      else if (kind_ == MotorKind::Audio1473) rc = set_led_1473_locked(mode);
      if (rc == 0) out.transport = control::Transport::PhysicalMotor;
      return rc;
    }, reply);
  }

  int prepare_camera(control::Reply& reply) {
    std::lock_guard<std::mutex> guard(mutex_);
    return with_fresh_handle_retry_locked([&](control::Reply& out) {
      const int rc = kind_ == MotorKind::Audio1473 ? prime_1473_locked() : 0;
      if (rc == 0) out.transport = control::Transport::PhysicalMotor;
      return rc;
    }, reply);
  }

  void close() {
    std::lock_guard<std::mutex> guard(mutex_);
    close_locked();
  }

 private:
  bool ensure_open_locked() {
    if (motor_) return true;

    libusb_device** list = nullptr;
    const ssize_t count = libusb_get_device_list(usb_ctx, &list);
    if (count < 0) return false;

    // Same selection as the Windows broker. A device-scoped request resolves
    // the model from its 02AE camera: 1414 (bcdDevice 0x010B) is pinned to
    // 02B0 and never falls through to 02BB/02C3, which is only its UAC audio
    // function; 1473 is pinned to 02BB/02C3 MI_00. An unscoped diagnostic
    // request, or a sensor whose camera is re-enumerating, prefers the
    // unambiguous 02B0 function.
    hardware::Model model = hardware::Model::Unknown;
    libusb_device* classic = nullptr;
    libusb_device* audio_control = nullptr;

    for (ssize_t i = 0; i < count; ++i) {
      libusb_device_descriptor descriptor{};
      if (libusb_get_device_descriptor(list[i], &descriptor) != 0 ||
          descriptor.idVendor != hardware::kMicrosoftVid) {
        continue;
      }
      if (!device_id_.empty() && physical_id(list[i]) != device_id_) continue;

      const auto camera_model = hardware::model_from_camera(descriptor.idProduct, descriptor.bcdDevice);
      if (!device_id_.empty() && camera_model != hardware::Model::Unknown) model = camera_model;
      if (descriptor.idProduct == hardware::kMotor1414Pid && !classic) classic = list[i];
      if (hardware::is_audio_runtime_pid(descriptor.idProduct) && !audio_control) audio_control = list[i];
    }

    libusb_device* selected = nullptr;
    MotorKind selected_kind = MotorKind::None;
    if (model == hardware::Model::Xbox1414) {
      selected = classic;
      selected_kind = MotorKind::Classic1414;
    } else if (model == hardware::Model::Xbox1473) {
      selected = audio_control;
      selected_kind = MotorKind::Audio1473;
    } else if (classic) {
      selected = classic;
      selected_kind = MotorKind::Classic1414;
    } else {
      selected = audio_control;
      selected_kind = MotorKind::Audio1473;
    }

    if (selected) libusb_ref_device(selected);
    libusb_free_device_list(list, 1);
    if (!selected) return false;

    const int open_rc = libusb_open(selected, &motor_);
    libusb_unref_device(selected);
    if (open_rc != 0 || !motor_) {
      motor_ = nullptr;
      return false;
    }

    kind_ = selected_kind;
    physical_id_ = physical_id(libusb_get_device(motor_));
    io_mutex_ = device_io_mutex_for(physical_id_);
    next_tag_ = 0;
    primed_ = kind_ == MotorKind::Classic1414;
    if (kind_ == MotorKind::Audio1473) {
      // Match the Windows runtime: discover MI_00's live bulk pair/alternate
      // setting instead of assuming interface 0 / alt 0 forever. Prefer the
      // known 0x01/0x81 pair and interface 0 so the USB-Audio capture interface
      // remains owned by ALSA.
      if (!discover_1473_control_locked()) {
        close_locked();
        return false;
      }
      (void)libusb_set_auto_detach_kernel_driver(motor_, 1);
      if (libusb_claim_interface(motor_, control_interface_) != 0) {
        close_locked();
        return false;
      }
      control_claimed_ = true;
      if (control_alt_setting_ != 0 &&
          libusb_set_interface_alt_setting(motor_, control_interface_, control_alt_setting_) != 0) {
        close_locked();
        return false;
      }
    }
    return true;
  }

  void close_locked() {
    if (motor_) {
      if (kind_ == MotorKind::Audio1473 && control_claimed_)
        (void)libusb_release_interface(motor_, control_interface_);
      libusb_close(motor_);
    }
    motor_ = nullptr;
    kind_ = MotorKind::None;
    physical_id_.clear();
    io_mutex_.reset();
    control_interface_ = 0;
    control_alt_setting_ = 0;
    control_in_ = kAltIn;
    control_out_ = kAltOut;
    control_claimed_ = false;
    next_tag_ = 0;
    primed_ = false;
    last_tilt_valid_ = false;
    last_tilt_tenths_ = 0;
  }

  bool discover_1473_control_locked() {
    if (!motor_) return false;
    libusb_device* device = libusb_get_device(motor_);
    if (!device) return false;
    libusb_config_descriptor* config = nullptr;
    if (libusb_get_active_config_descriptor(device, &config) != 0 || !config) {
      if (libusb_get_config_descriptor(device, 0, &config) != 0 || !config) return false;
    }

    struct Candidate {
      int score = -1;
      int interface_number = 0;
      int alt = 0;
      uint8_t in = 0;
      uint8_t out = 0;
    } best;

    for (uint8_t i = 0; i < config->bNumInterfaces; ++i) {
      const libusb_interface& interface = config->interface[i];
      for (int a = 0; a < interface.num_altsetting; ++a) {
        const libusb_interface_descriptor& alternate = interface.altsetting[a];
        uint8_t in = 0, out = 0;
        bool exact_in = false, exact_out = false;
        for (uint8_t e = 0; e < alternate.bNumEndpoints; ++e) {
          const libusb_endpoint_descriptor& endpoint = alternate.endpoint[e];
          if ((endpoint.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
          const uint8_t address = endpoint.bEndpointAddress;
          if ((address & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
            if (!in || address == kAltIn) in = address;
            if (address == kAltIn) exact_in = true;
          } else {
            if (!out || address == kAltOut) out = address;
            if (address == kAltOut) exact_out = true;
          }
        }
        if (!in || !out) continue;
        int score = 0;
        if (alternate.bInterfaceNumber == 0) score += 100;
        if (exact_in) score += 20;
        if (exact_out) score += 20;
        if (alternate.bAlternateSetting == 0) score += 1;
        if (score > best.score) {
          best = {score, alternate.bInterfaceNumber, alternate.bAlternateSetting, in, out};
        }
      }
    }
    libusb_free_config_descriptor(config);
    if (best.score < 0) return false;
    control_interface_ = best.interface_number;
    control_alt_setting_ = best.alt;
    control_in_ = best.in;
    control_out_ = best.out;
    return true;
  }

  int alt_ack_locked(uint32_t expected_tag, unsigned int timeout_ms = 750) {
    AltReply reply{};
    int transferred = 0;
    const int rc = libusb_bulk_transfer(
        motor_, control_in_, reinterpret_cast<unsigned char*>(&reply), sizeof(reply), &transferred, timeout_ms);
    if (rc != 0) return rc;
    if (transferred != static_cast<int>(sizeof(reply)) || reply.magic != kAltReplyMagic || reply.status != 0)
      return -EIO;
    (void)expected_tag;
    return 0;
  }

  int alt_command_locked(uint32_t command, int32_t arg2) {
    const uint32_t tag = next_tag_++;
    AltCommand request{kAltMagic, tag, 0, command, static_cast<uint32_t>(arg2)};
    int transferred = 0;
    const int rc = libusb_bulk_transfer(
        motor_, control_out_, reinterpret_cast<unsigned char*>(&request), sizeof(request), &transferred, 750);
    if (rc != 0) return rc;
    if (transferred != static_cast<int>(sizeof(request))) return -EIO;
    return alt_ack_locked(tag);
  }

  int prime_1473_locked() {
    if (kind_ != MotorKind::Audio1473 || primed_) return 0;
    // A fresh UAC-runtime MI_00 handle starts at tag zero and is primed with
    // the solid-green command before motor/status traffic. Several 1473
    // controllers ignore 0x803B until this initialization completes.
    next_tag_ = 0;
    const int rc = alt_command_locked(kAltLed, 3);
    if (rc == 0) primed_ = true;
    return rc;
  }

  int status_1414_locked(control::Reply& reply) {
    unsigned char bytes[10]{};
    const int rc = libusb_control_transfer(motor_, 0xC0, 0x32, 0, 0, bytes, sizeof(bytes), 1000);
    if (rc != 10) return rc < 0 ? rc : -EIO;
    reply.accelX = static_cast<int16_t>((bytes[2] << 8) | bytes[3]);
    reply.accelY = static_cast<int16_t>((bytes[4] << 8) | bytes[5]);
    reply.accelZ = static_cast<int16_t>((bytes[6] << 8) | bytes[7]);
    reply.tiltTenths = static_cast<int8_t>(bytes[8]) * 5;
    reply.state = bytes[9];
    return 0;
  }

  int status_1473_locked(control::Reply& reply) {
    int rc = prime_1473_locked();
    if (rc != 0) return rc;

    const uint32_t tag = next_tag_++;
    AltCommand request{kAltMagic, tag, 0x68, kAltStatus, 0};
    int transferred = 0;
    rc = libusb_bulk_transfer(
        motor_, control_out_, reinterpret_cast<unsigned char*>(&request), 16, &transferred, 750);
    if (rc != 0 || transferred != 16) return rc != 0 ? rc : -EIO;

    // Tolerate a stale short reply left by a timed-out earlier transaction,
    // but keep normal 1473 control fully synchronized: status consumes both
    // its 104-byte payload and its trailing 12-byte ACK.
    unsigned char buffer[256]{};
    for (int attempt = 0; attempt < 4; ++attempt) {
      transferred = 0;
      rc = libusb_bulk_transfer(motor_, control_in_, buffer, sizeof(buffer), &transferred, 750);
      if (rc != 0) return rc;
      if (transferred == static_cast<int>(sizeof(AltReply))) {
        AltReply ack{};
        std::memcpy(&ack, buffer, sizeof(ack));
        if (ack.magic != kAltReplyMagic || ack.status != 0) return -EIO;
        continue;
      }
      if (transferred != 0x68) return -EIO;

      int32_t values[4]{};
      std::memcpy(values, buffer + 16, sizeof(values));
      reply.accelX = static_cast<int16_t>(values[0]);
      reply.accelY = static_cast<int16_t>(values[1]);
      reply.accelZ = static_cast<int16_t>(values[2]);
      reply.tiltTenths = values[3] * 10;
      reply.state = 0;

      // Complete the status transaction so the bulk IN endpoint is empty
      // before the next LED/Tilt/status command. A delayed ACK does not
      // invalidate the already received status payload.
      const int ack_rc = alt_ack_locked(tag, 1200);
      if (ack_rc != 0 && ack_rc != LIBUSB_ERROR_TIMEOUT) return ack_rc;
      return 0;
    }
    return -ETIMEDOUT;
  }

  int read_status_locked(control::Reply& reply) {
    int rc = -ENODEV;
    if (kind_ == MotorKind::Classic1414) rc = status_1414_locked(reply);
    else if (kind_ == MotorKind::Audio1473) rc = status_1473_locked(reply);
    if (rc == 0) {
      last_tilt_valid_ = true;
      last_tilt_tenths_ = reply.tiltTenths;
    }
    return rc;
  }

  // 1473 travel budget, identical to the Windows broker. MI_00 must stay
  // silent for the whole mechanical travel: any status/LED transaction while
  // the controller moves makes the motor stop and restart. The budget grows
  // with the distance from the last measured angle; an unknown start assumes
  // the full range.
  int tilt_1473_quiet_ms(int degrees) const {
    constexpr int kMinimumQuietMs = 1500;
    constexpr int kSettleMarginMs = 600;
    constexpr int kTravelMsPerDegree = 85;
    const int distance = last_tilt_valid_
        ? (std::abs(degrees * 10 - last_tilt_tenths_) + 9) / 10
        : hardware::kTiltMaxDegrees - hardware::kTiltMinDegrees;
    return std::max(kMinimumQuietMs, kSettleMarginMs + distance * kTravelMsPerDegree);
  }

  int issue_tilt_1414_locked(int degrees) {
    const int16_t half_degrees = static_cast<int16_t>(degrees * 2);
    const int rc = libusb_control_transfer(
        motor_, 0x40, 0x31, static_cast<uint16_t>(half_degrees), 0, nullptr, 0, 1000);
    return rc < 0 ? rc : 0;
  }

  int issue_tilt_1473_locked(int degrees) {
    const int prime = prime_1473_locked();
    if (prime != 0) return prime;

    const uint32_t tag = next_tag_++;
    AltCommand request{kAltMagic, tag, 0, kAltTilt, static_cast<uint32_t>(degrees)};
    int transferred = 0;
    const int rc = libusb_bulk_transfer(
        motor_, control_out_, reinterpret_cast<unsigned char*>(&request), sizeof(request), &transferred, 750);
    if (rc != 0) return rc;
    if (transferred != static_cast<int>(sizeof(request))) return -EIO;

    // 1473 returns a 12-byte ACK for 0x803B. Consume it immediately so MI_00
    // cannot hold a completed reply while the motor controller is travelling.
    // Never resend the motor command solely because this ACK is late: the full
    // 20-byte OUT transfer above is the command commit point.
    const int ack_rc = alt_ack_locked(tag, 2000);
    if (ack_rc != 0 && ack_rc != LIBUSB_ERROR_TIMEOUT) return ack_rc;
    return 0;
  }

  int set_led_1414_locked(int mode) {
    const int rc = libusb_control_transfer(
        motor_, 0x40, 0x06, static_cast<uint16_t>(mode), 0, nullptr, 0, 1000);
    return rc < 0 ? rc : 0;
  }

  int set_led_1473_locked(int mode) {
    int alt = 3;
    if (mode == 0) alt = 1;
    else if (mode == 4) alt = 2;
    else if (mode == 2) alt = 4;
    const int rc = alt_command_locked(kAltLed, alt);
    if (rc == 0) primed_ = true;
    return rc;
  }

  int wait_tilt_1414_locked(int degrees, control::Reply& reply) {
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    const int target = degrees * 10;
    bool got_status = false;
    int first = 0;
    int last = 0;
    bool first_valid = false;
    int last_error = -ETIMEDOUT;

    for (int attempt = 0; attempt < 40; ++attempt) {
      control::Reply latest{};
      const int rc = read_status_locked(latest);
      if (rc == 0) {
        got_status = true;
        reply = latest;
        last = latest.tiltTenths;
        if (!first_valid) {
          first = last;
          first_valid = true;
        }
        if (std::abs(last - target) <= kTiltToleranceTenths) {
          reply.state |= control::kStateTiltVerified;
          return 0;
        }
      } else if (rc != LIBUSB_ERROR_TIMEOUT) {
        last_error = rc;
        return rc;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    if (!got_status) return last_error;
    return first_valid && std::abs(last - first) >= 5 ? -ETIMEDOUT : -EIO;
  }

  int tilt_1473_locked(int degrees, control::Reply& reply) {
    // The Tilt command and its ACK complete first. MI_00 then stays silent for
    // the whole travel and the angle is read exactly once.
    const int quiet_ms = tilt_1473_quiet_ms(degrees);
    const int issue_rc = issue_tilt_1473_locked(degrees);
    if (issue_rc != 0) return issue_rc;
    std::this_thread::sleep_for(std::chrono::milliseconds(quiet_ms));

    const int target = degrees * 10;
    control::Reply latest{};
    if (read_status_locked(latest) == 0) {
      reply = latest;
      reply.transport = control::Transport::PhysicalMotor;
      if (std::abs(latest.tiltTenths - target) <= kTiltToleranceTenths) reply.state |= control::kStateTiltVerified;
      return 0;
    }

    // The complete 20-byte OUT transfer is authoritative. Never resend 0x803B
    // only because the final status did not arrive.
    reply = {};
    reply.transport = control::Transport::PhysicalMotor;
    reply.tiltTenths = target;
    return 0;
  }

  void recover_1473_control_locked() {
    if (!motor_ || kind_ != MotorKind::Audio1473 || !control_claimed_) return;
    // Error-only recovery for MI_00. Do not reset the composite Kinect device:
    // that would tear ALSA audio down. Clearing halted bulk pipes mirrors the
    // Windows driver's fresh-handle recovery without touching MI_02.
    (void)libusb_clear_halt(motor_, control_in_);
    (void)libusb_clear_halt(motor_, control_out_);
  }

  template <class Operation>
  int with_fresh_handle_retry_locked(Operation&& operation, control::Reply& reply) {
    int last = -ENODEV;
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (!ensure_open_locked()) {
        last = -ENODEV;
      } else {
        const auto io_mutex = io_mutex_;
        std::lock_guard<std::mutex> io_guard(*io_mutex);
        reply = {};
        last = operation(reply);
        if (last == 0) return 0;
        recover_1473_control_locked();
      }
      close_locked();
      if (attempt == 0) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return last;
  }

  struct TiltInFlight {
    explicit TiltInFlight(std::atomic<bool>& inFlight) : flag(inFlight) { flag.store(true, std::memory_order_release); }
    ~TiltInFlight() { flag.store(false, std::memory_order_release); }
    TiltInFlight(const TiltInFlight&) = delete;
    TiltInFlight& operator=(const TiltInFlight&) = delete;
    std::atomic<bool>& flag;
  };

  std::string device_id_;
  std::atomic<bool> tilt_in_flight_{false};
  std::mutex mutex_;
  libusb_device_handle* motor_ = nullptr;
  MotorKind kind_ = MotorKind::None;
  int control_interface_ = 0;
  int control_alt_setting_ = 0;
  uint8_t control_in_ = kAltIn;
  uint8_t control_out_ = kAltOut;
  bool control_claimed_ = false;
  std::string physical_id_;
  std::shared_ptr<std::mutex> io_mutex_;
  uint32_t next_tag_ = 0;
  bool primed_ = false;
  bool last_tilt_valid_ = false;
  int last_tilt_tenths_ = 0;
};

std::mutex sessions_mutex;
std::map<std::string, std::shared_ptr<MotorSession>> sessions;

std::shared_ptr<MotorSession> session_for(const std::string& device_id) {
  const std::string key = device_id.empty() ? "__auto__" : device_id;
  std::lock_guard<std::mutex> guard(sessions_mutex);
  auto& session = sessions[key];
  if (!session) session = std::make_shared<MotorSession>(device_id);
  return session;
}

void close_sessions() {
  std::lock_guard<std::mutex> guard(sessions_mutex);
  for (auto& entry : sessions) entry.second->close();
  sessions.clear();
}

class BrokerClientLease {
 public:
  BrokerClientLease() = default;
  ~BrokerClientLease() {
    active_clients.fetch_sub(1);
    active_clients_cv.notify_all();
  }
  BrokerClientLease(const BrokerClientLease&) = delete;
  BrokerClientLease& operator=(const BrokerClientLease&) = delete;
};

void client(int fd) {
  if (!unixio::set_io_timeout(fd, kClientIoTimeoutMs)) return;
  control::Request request{};
  control::Reply reply{};
  if (!unixio::read_exact(fd, &request, sizeof(request)) ||
      request.magic != control::kMagic || request.version != control::kVersion) {
    return;
  }

  const std::string device_id(request.deviceId, strnlen(request.deviceId, sizeof(request.deviceId)));
  if (request.command == control::Command::Ping && device_id.empty()) {
    // Match Windows broker semantics: an unscoped Ping tests broker liveness,
    // not USB availability. A device-scoped Ping still validates its motor path.
    reply.result = 0;
    unixio::write_all(fd, &reply, sizeof(reply));
    return;
  }

  const auto session = session_for(device_id);
  switch (request.command) {
    case control::Command::Ping:
      reply.result = session->ping(reply);
      break;
    case control::Command::Status:
      reply.result = session->status(reply);
      break;
    case control::Command::Tilt:
      reply.result = session->tilt(request.value, reply);
      break;
    case control::Command::Led:
      reply.result = session->led(request.value, reply);
      break;
    case control::Command::PrepareCamera:
      reply.result = session->prepare_camera(reply);
      break;
    default:
      reply.result = -EINVAL;
      break;
  }

  unixio::write_all(fd, &reply, sizeof(reply));
}
}  // namespace

int main() {
  struct sigaction action{};
  action.sa_handler = stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  sigaction(SIGINT, &action, nullptr);
  sigaction(SIGTERM, &action, nullptr);
  std::signal(SIGPIPE, SIG_IGN);

  if (libusb_init(&usb_ctx) != 0) return 2;
  const int server = unixio::local_server_socket(kControlSocket, 16);
  if (server < 0) {
    std::perror("control socket");
    libusb_exit(usb_ctx);
    return 3;
  }
  listener_fd = server;

  while (!stop_requested) {
    const int connection = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (connection < 0) {
      if (stop_requested) break;
      if (errno == EINTR) continue;
      unixio::retry_sleep();
      continue;
    }
    const uint32_t previous = active_clients.fetch_add(1);
    if (previous >= kMaxBrokerClients) {
      active_clients.fetch_sub(1);
      ::close(connection);
      continue;
    }
    try {
      std::thread([connection] {
        BrokerClientLease lease;
        try {
          client(connection);
        } catch (const std::exception& error) {
          std::fprintf(stderr, "broker client error: %s\n", error.what());
        } catch (...) {
          std::fprintf(stderr, "broker client error: unknown exception\n");
        }
        ::shutdown(connection, SHUT_RDWR);
        ::close(connection);
      }).detach();
    } catch (...) {
      active_clients.fetch_sub(1);
      ::close(connection);
    }
  }

  if (listener_fd >= 0) {
    ::close(static_cast<int>(listener_fd));
    listener_fd = -1;
  }
  ::unlink(kControlSocket);
  {
    std::unique_lock<std::mutex> lock(active_clients_mutex);
    active_clients_cv.wait(lock, [] { return active_clients.load() == 0; });
  }
  close_sessions();
  libusb_exit(usb_ctx);
  return 0;
}
