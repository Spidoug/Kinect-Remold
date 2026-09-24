#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <arpa/inet.h>
#include <jpeglib.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "remold/config.hpp"
#include "remold/protocol.hpp"
#include "remold/raw_sensor.hpp"
#include "remold/device_registry.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
constexpr size_t kMaxRequestBytes = 16u * 1024u;
constexpr int kClientIoTimeoutSeconds = 3;
constexpr uint32_t kDefaultMaxClients = 4;
constexpr uint32_t kMaxConfiguredClients = 16;
constexpr uint32_t kAuthFailureLimit = 8;
constexpr uint64_t kAuthWindowMs = 60'000;
constexpr uint64_t kAuthBlockMs = 60'000;
constexpr size_t kMaxAuthPeers = 256;

std::atomic<bool> run{true};
volatile std::sig_atomic_t stop_requested = 0;
volatile std::sig_atomic_t listener_fd = -1;
std::atomic<uint32_t> authenticated_clients{0};
std::atomic<uint32_t> open_clients{0};
std::mutex open_clients_mutex;
std::condition_variable open_clients_cv;
std::mutex demand_mutex;
std::condition_variable demand_cv;

struct AuthState {
  uint32_t failures = 0;
  uint64_t window_start_ms = 0;
  uint64_t blocked_until_ms = 0;
  uint64_t last_seen_ms = 0;
};
std::mutex auth_mutex;
std::unordered_map<std::string, AuthState> auth_states;

void stop_handler(int) {
  stop_requested = 1;
  const int fd = static_cast<int>(listener_fd);
  if (fd >= 0) {
    ::close(fd);  // close(2) is async-signal-safe and releases a blocking accept.
    listener_fd = -1;
  }
}

uint64_t monotonic_ms() { return unixio::monotonic_ms(); }

bool valid_device_id(const std::string& value) {
  if (value.empty()) return true;
  if (value.size() > 96) return false;
  for (unsigned char ch : value) {
    if (!(std::isalnum(ch) || ch == '.' || ch == '_' || ch == '-')) return false;
  }
  return true;
}

std::string lower_ascii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string trim(std::string value) {
  auto not_space = [](unsigned char c) { return !std::isspace(c); };
  value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
  value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
  return value;
}

std::string base64(const std::string& input) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  int value = 0, bits = -6;
  for (unsigned char c : input) {
    value = (value << 8) + c;
    bits += 8;
    while (bits >= 0) {
      output.push_back(alphabet[(value >> bits) & 63]);
      bits -= 6;
    }
  }
  if (bits > -6) output.push_back(alphabet[((value << 8) >> (bits + 8)) & 63]);
  while (output.size() % 4) output.push_back('=');
  return output;
}

bool constant_time_equal(const std::string& a, const std::string& b) {
  const size_t n = std::max(a.size(), b.size());
  unsigned diff = static_cast<unsigned>(a.size() ^ b.size());
  for (size_t i = 0; i < n; ++i) {
    const unsigned char av = i < a.size() ? static_cast<unsigned char>(a[i]) : 0;
    const unsigned char bv = i < b.size() ? static_cast<unsigned char>(b[i]) : 0;
    diff |= static_cast<unsigned>(av ^ bv);
  }
  return diff == 0;
}

std::string header_value(const std::string& request, const std::string& wanted) {
  const std::string wanted_lower = lower_ascii(wanted);
  size_t line_start = request.find("\r\n");
  if (line_start == std::string::npos) return {};
  line_start += 2;
  while (line_start < request.size()) {
    const size_t line_end = request.find("\r\n", line_start);
    if (line_end == std::string::npos || line_end == line_start) break;
    const std::string line = request.substr(line_start, line_end - line_start);
    const size_t colon = line.find(':');
    if (colon != std::string::npos) {
      const std::string key = lower_ascii(trim(line.substr(0, colon)));
      if (key == wanted_lower) return trim(line.substr(colon + 1));
    }
    line_start = line_end + 2;
  }
  return {};
}

bool authorized(const std::string& request, const std::string& expected_auth) {
  const std::string got = header_value(request, "Authorization");
  return !got.empty() && constant_time_equal(got, expected_auth);
}

void prune_auth_states_locked(uint64_t now) {
  if (auth_states.size() <= kMaxAuthPeers) return;
  for (auto it = auth_states.begin(); it != auth_states.end() && auth_states.size() > kMaxAuthPeers / 2;) {
    if (now - it->second.last_seen_ms > kAuthWindowMs) it = auth_states.erase(it);
    else ++it;
  }
  while (auth_states.size() > kMaxAuthPeers) auth_states.erase(auth_states.begin());
}

bool auth_attempt_allowed(const std::string& peer) {
  const uint64_t now = monotonic_ms();
  std::lock_guard<std::mutex> lock(auth_mutex);
  auto it = auth_states.find(peer);
  if (it == auth_states.end()) return true;
  it->second.last_seen_ms = now;
  return now >= it->second.blocked_until_ms;
}

void record_auth_failure(const std::string& peer) {
  const uint64_t now = monotonic_ms();
  std::lock_guard<std::mutex> lock(auth_mutex);
  auto& state = auth_states[peer];
  if (state.window_start_ms == 0 || now - state.window_start_ms > kAuthWindowMs) {
    state.window_start_ms = now;
    state.failures = 0;
  }
  state.last_seen_ms = now;
  ++state.failures;
  if (state.failures >= kAuthFailureLimit) {
    state.blocked_until_ms = now + kAuthBlockMs;
    state.failures = 0;
    state.window_start_ms = now;
  }
  prune_auth_states_locked(now);
}

void clear_auth_failures(const std::string& peer) {
  std::lock_guard<std::mutex> lock(auth_mutex);
  auth_states.erase(peer);
}

bool private_or_loopback(const sockaddr_in& peer) {
  const uint32_t ip = ntohl(peer.sin_addr.s_addr);
  if ((ip & 0xff000000u) == 0x7f000000u) return true;       // 127/8
  if ((ip & 0xff000000u) == 0x0a000000u) return true;       // 10/8
  if ((ip & 0xfff00000u) == 0xac100000u) return true;       // 172.16/12
  if ((ip & 0xffff0000u) == 0xc0a80000u) return true;       // 192.168/16
  if ((ip & 0xffff0000u) == 0xa9fe0000u) return true;       // 169.254/16
  if ((ip & 0xffc00000u) == 0x64400000u) return true;       // 100.64/10
  return false;
}

std::string peer_text(const sockaddr_in& peer) {
  char text[INET_ADDRSTRLEN]{};
  if (!inet_ntop(AF_INET, &peer.sin_addr, text, sizeof(text))) return "unknown";
  return text;
}

std::string security_headers() {
  return
      "X-Content-Type-Options: nosniff\r\n"
      "Referrer-Policy: no-referrer\r\n"
      "Cross-Origin-Resource-Policy: same-origin\r\n"
      "X-Frame-Options: DENY\r\n"
      "Permissions-Policy: camera=(), microphone=(), geolocation=()\r\n";
}

void send_simple(int fd, int status, const char* reason, const std::string& body,
                 const std::string& extra_headers = {}) {
  std::ostringstream out;
  out << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
      << security_headers()
      << "Cache-Control: no-store\r\n"
      << extra_headers
      << "Content-Type: text/plain; charset=utf-8\r\n"
      << "Content-Length: " << body.size() << "\r\n"
      << "Connection: close\r\n\r\n" << body;
  const auto text = out.str();
  (void)unixio::write_all(fd, text.data(), text.size());
}

std::vector<uint8_t> jpeg_bayer(const uint8_t* pixels, int quality) {
  std::vector<uint8_t> rgb;
  rawsensor::bayer_grbg_to_rgb24(pixels, scanner::kWidth, scanner::kHeight, rgb);
  jpeg_compress_struct compressor{};
  jpeg_error_mgr errors{};
  compressor.err = jpeg_std_error(&errors);
  jpeg_create_compress(&compressor);
  unsigned char* output = nullptr;
  unsigned long output_size = 0;
  jpeg_mem_dest(&compressor, &output, &output_size);
  compressor.image_width = scanner::kWidth;
  compressor.image_height = scanner::kHeight;
  compressor.input_components = 3;
  compressor.in_color_space = JCS_RGB;
  jpeg_set_defaults(&compressor);
  jpeg_set_quality(&compressor, quality, TRUE);
  jpeg_start_compress(&compressor, TRUE);
  while (compressor.next_scanline < compressor.image_height) {
    JSAMPROW row = rgb.data() + compressor.next_scanline * scanner::kWidth * 3;
    jpeg_write_scanlines(&compressor, &row, 1);
  }
  jpeg_finish_compress(&compressor);
  std::vector<uint8_t> result(output, output + output_size);
  std::free(output);
  jpeg_destroy_compress(&compressor);
  return result;
}

class Frames {
 public:
  void set(std::vector<uint8_t> frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    jpeg_ = std::move(frame);
    ++sequence_;
    updated_ms_ = monotonic_ms();
    cv_.notify_all();
  }

  uint64_t sequence() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sequence_;
  }

  uint64_t updated_ms() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return updated_ms_;
  }

  bool latest(std::vector<uint8_t>& output) const {
    std::lock_guard<std::mutex> lock(mutex_);
    output = jpeg_;
    return !output.empty();
  }

  bool wait(uint64_t& last, std::vector<uint8_t>& output) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, std::chrono::seconds(2), [&] { return !run || sequence_ != last; });
    if (!run) return false;
    if (sequence_ == last) return true;
    last = sequence_;
    output = jpeg_;
    return true;
  }

  void wake_all() { cv_.notify_all(); }

 private:
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<uint8_t> jpeg_;
  uint64_t sequence_ = 0;
  uint64_t updated_ms_ = 0;
} frames;

class ClientLease {
 public:
  ClientLease() {
    authenticated_clients.fetch_add(1);
    demand_cv.notify_all();
  }
  ~ClientLease() {
    authenticated_clients.fetch_sub(1);
    demand_cv.notify_all();
  }
  ClientLease(const ClientLease&) = delete;
  ClientLease& operator=(const ClientLease&) = delete;
};

class OpenClientLease {
 public:
  OpenClientLease() = default;
  ~OpenClientLease() {
    open_clients.fetch_sub(1);
    open_clients_cv.notify_all();
  }
  OpenClientLease(const OpenClientLease&) = delete;
  OpenClientLease& operator=(const OpenClientLease&) = delete;
};

int subscribe_rgb(const std::string& requested_device_id) {
  const auto manifest = devices::read_manifest();
  const devices::Device* selected = nullptr;
  if (!requested_device_id.empty()) {
    selected = devices::find(manifest, requested_device_id);
    if (!selected || !selected->camera_ready()) return -1;
  } else {
    for (const auto& device : manifest) {
      if (device.camera_ready()) { selected = &device; break; }
    }
  }
  const std::string endpoint = selected ? selected->camera : std::string{};
  int fd = endpoint.empty() ? -1 : unixio::connect_socket(endpoint);
  if (fd < 0) return -1;
  scanner::Request request{};
  request.streamMask = scanner::StreamRgb;
  scanner::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply)) || reply.result < 0 ||
      reply.acceptedMask != request.streamMask) {
    ::close(fd);
    return -1;
  }
  return fd;
}

void feeder(int quality, std::string requested_device_id) {
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  while (run) {
    {
      std::unique_lock<std::mutex> lock(demand_mutex);
      demand_cv.wait(lock, [] { return !run || authenticated_clients.load() > 0; });
    }
    if (!run) break;

    int fd = subscribe_rgb(requested_device_id);
    if (fd < 0) {
      unixio::retry_sleep(300);
      continue;
    }

    while (run && authenticated_clients.load() > 0) {
      scanner::FrameHeader header{};
      if (!unixio::read_exact(fd, &header, sizeof(header)) ||
          header.payloadBytes > payload.size() ||
          !unixio::read_exact(fd, payload.data(), header.payloadBytes)) {
        break;
      }
      if (header.mode == scanner::StreamMode::Rgb &&
          header.pixelFormat == scanner::PixelFormat::BayerGrbg8 &&
          header.payloadBytes == scanner::kRgbRawPayloadBytes) {
        frames.set(jpeg_bayer(payload.data(), quality));
      }
    }
    ::close(fd);
  }
}

bool send_all(int fd, const void* data, size_t bytes) {
  return unixio::write_all(fd, data, bytes);
}

void handle_snapshot(int fd) {
  std::vector<uint8_t> jpeg;
  const uint64_t updated = frames.updated_ms();
  if (!frames.latest(jpeg) || updated == 0 || monotonic_ms() - updated > 5000) {
    send_simple(fd, 503, "Service Unavailable", "RGB source unavailable", "Retry-After: 1\r\n");
    return;
  }
  std::ostringstream headers;
  headers << "HTTP/1.1 200 OK\r\n" << security_headers()
          << "Content-Type: image/jpeg\r\nContent-Length: " << jpeg.size()
          << "\r\nCache-Control: no-store, no-cache, must-revalidate\r\nConnection: close\r\n\r\n";
  const auto text = headers.str();
  if (send_all(fd, text.data(), text.size())) (void)send_all(fd, jpeg.data(), jpeg.size());
}

void handle_root(int fd) {
  static const std::string body =
      "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
      "<title>Kinect Xbox 360 Remold</title></head><body>"
      "<h1>Kinect Xbox 360 Remold</h1><p>Authenticated IP camera.</p>"
      "<img src='/stream.mjpg' alt='Kinect camera stream'><p><a href='/snapshot.jpg'>Snapshot</a> &middot; "
      "<a href='/status.json'>Status</a></p></body></html>";
  std::ostringstream out;
  out << "HTTP/1.1 200 OK\r\n" << security_headers()
      << "Content-Security-Policy: default-src 'self'; img-src 'self'; style-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n"
      << "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
      << body.size() << "\r\nConnection: close\r\n\r\n" << body;
  const auto text = out.str();
  (void)send_all(fd, text.data(), text.size());
}

void handle_status(int fd) {
  const uint64_t updated = frames.updated_ms();
  const bool online = updated != 0 && monotonic_ms() - updated <= 5000;
  std::ostringstream body;
  body << "{\"version\":1,\"component\":\"kinect360-remold-camera-ip\",\"rgbOnline\":"
       << (online ? "true" : "false") << ",\"authenticatedClients\":"
       << authenticated_clients.load() << "}";
  const std::string data = body.str();
  std::ostringstream out;
  out << "HTTP/1.1 200 OK\r\n" << security_headers()
      << "Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
      << data.size() << "\r\nConnection: close\r\n\r\n" << data;
  const auto text = out.str();
  (void)send_all(fd, text.data(), text.size());
}

void handle_stream(int fd, int fps) {
  static constexpr char boundary[] = "kinectremoldframe";
  std::ostringstream initial;
  initial << "HTTP/1.1 200 OK\r\n" << security_headers()
          << "Content-Type: multipart/x-mixed-replace; boundary=" << boundary
          << "\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n";
  const auto initial_text = initial.str();
  if (!send_all(fd, initial_text.data(), initial_text.size())) return;

  uint64_t sequence = frames.sequence();
  const auto interval = std::chrono::milliseconds(std::max(1, 1000 / fps));
  auto next = std::chrono::steady_clock::now();
  while (run) {
    std::vector<uint8_t> jpeg;
    if (!frames.wait(sequence, jpeg)) break;
    if (jpeg.empty()) continue;
    const auto now = std::chrono::steady_clock::now();
    if (now < next) std::this_thread::sleep_until(next);
    next = std::chrono::steady_clock::now() + interval;
    std::ostringstream part;
    part << "--" << boundary << "\r\nContent-Type: image/jpeg\r\nContent-Length: " << jpeg.size()
         << "\r\n\r\n";
    const auto text = part.str();
    if (!send_all(fd, text.data(), text.size()) ||
        !send_all(fd, jpeg.data(), jpeg.size()) ||
        !send_all(fd, "\r\n", 2)) {
      break;
    }
  }
}

void client(int fd, const sockaddr_in peer, const std::string expected_auth, int fps) {
  timeval timeout{};
  timeout.tv_sec = kClientIoTimeoutSeconds;
  (void)::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  (void)::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

  const std::string peer_name = peer_text(peer);
  if (!auth_attempt_allowed(peer_name)) {
    send_simple(fd, 429, "Too Many Requests", "Authentication temporarily blocked", "Retry-After: 60\r\n");
    ::close(fd);
    return;
  }

  std::string request;
  request.reserve(2048);
  char buffer[2048];
  while (request.size() < kMaxRequestBytes && request.find("\r\n\r\n") == std::string::npos) {
    const ssize_t n = ::recv(fd, buffer, sizeof(buffer), 0);
    if (n <= 0) break;
    request.append(buffer, static_cast<size_t>(n));
  }
  if (request.find("\r\n\r\n") == std::string::npos) {
    send_simple(fd, request.size() >= kMaxRequestBytes ? 431 : 400,
                request.size() >= kMaxRequestBytes ? "Request Header Fields Too Large" : "Bad Request", "");
    ::close(fd);
    return;
  }

  std::istringstream first(request.substr(0, request.find("\r\n")));
  std::string method, path, version, extra;
  first >> method >> path >> version >> extra;
  if (!extra.empty() || path.empty() || path.front() != '/' ||
      (version != "HTTP/1.0" && version != "HTTP/1.1")) {
    send_simple(fd, 400, "Bad Request", "");
    ::close(fd);
    return;
  }
  if (method != "GET") {
    send_simple(fd, 405, "Method Not Allowed", "", "Allow: GET\r\n");
    ::close(fd);
    return;
  }
  if (version == "HTTP/1.1" && header_value(request, "Host").empty()) {
    send_simple(fd, 400, "Bad Request", "Missing Host header");
    ::close(fd);
    return;
  }
  if (!header_value(request, "Transfer-Encoding").empty()) {
    send_simple(fd, 400, "Bad Request", "Unexpected Transfer-Encoding");
    ::close(fd);
    return;
  }
  const std::string content_length = header_value(request, "Content-Length");
  if (!content_length.empty() && content_length != "0") {
    send_simple(fd, 400, "Bad Request", "GET request bodies are not accepted");
    ::close(fd);
    return;
  }
  if (!authorized(request, expected_auth)) {
    record_auth_failure(peer_name);
    send_simple(fd, 401, "Unauthorized", "Authentication required",
                "WWW-Authenticate: Basic realm=\"Kinect Xbox 360 Remold\", charset=\"UTF-8\"\r\n");
    ::close(fd);
    return;
  }
  clear_auth_failures(peer_name);

  ClientLease lease;
  if (path == "/" || path == "/index.html") handle_root(fd);
  else if (path == "/snapshot.jpg") handle_snapshot(fd);
  else if (path == "/stream.mjpg") handle_stream(fd, fps);
  else if (path == "/status.json") handle_status(fd);
  else send_simple(fd, 404, "Not Found", "");
  ::shutdown(fd, SHUT_RDWR);
  ::close(fd);
}
}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  if (!config.get_bool("ip.enabled", false)) return 0;

  const std::string bind_address = config.get("ip.bind", "127.0.0.1");
  const std::string user = config.get("ip.user", "admin");
  const std::string password = config.get("ip.password", "");
  const int port = config.get_int("ip.port", 8088);
  const int quality = std::clamp(config.get_int("ip.jpeg_quality", 78), 30, 95);
  const int fps = std::clamp(config.get_int("ip.fps", 8), 1, 15);
  const std::string requested_device_id = config.get("ip.device_id", "");
  const uint32_t max_clients = static_cast<uint32_t>(std::clamp(
      config.get_int("ip.max_clients", static_cast<int>(kDefaultMaxClients)), 1,
      static_cast<int>(kMaxConfiguredClients)));

  if (user.empty() || user.size() > 64 || password.size() < 24 || password.size() > 256) {
    std::fprintf(stderr, "IP-camera credentials are invalid; require a non-empty user and a password of at least 24 characters\n");
    return 2;
  }
  if (port < 1 || port > 65535) {
    std::fprintf(stderr, "ip.port is outside 1..65535\n");
    return 2;
  }
  if (!valid_device_id(requested_device_id)) {
    std::fprintf(stderr, "ip.device_id must be empty or 1..96 characters using only A-Z, a-z, 0-9, '.', '_' or '-'\n");
    return 2;
  }

  in_addr bind_addr{};
  if (inet_pton(AF_INET, bind_address.c_str(), &bind_addr) != 1) {
    std::fprintf(stderr, "ip.bind must be a numeric IPv4 address (recommended: 127.0.0.1 or 0.0.0.0)\n");
    return 2;
  }
  const bool wildcard_bind = bind_addr.s_addr == htonl(INADDR_ANY);

  std::thread feed(feeder, quality, requested_device_id);
  int server = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (server < 0) {
    std::perror("ip camera socket");
    run = false;
    demand_cv.notify_all();
    feed.join();
    return 3;
  }
  int one = 1;
  (void)::setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  address.sin_addr = bind_addr;
  if (::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0 ||
      ::listen(server, 16) < 0) {
    std::perror("ip camera bind/listen");
    ::close(server);
    run = false;
    demand_cv.notify_all();
    feed.join();
    return 3;
  }

  listener_fd = server;
  const std::string expected_auth = "Basic " + base64(user + ":" + password);
  while (run && !stop_requested) {
    sockaddr_in peer{};
    socklen_t peer_len = sizeof(peer);
    int fd = ::accept4(server, reinterpret_cast<sockaddr*>(&peer), &peer_len, SOCK_CLOEXEC);
    if (fd < 0) {
      if (errno == EINTR && !stop_requested) continue;
      break;
    }
    if (wildcard_bind && !private_or_loopback(peer)) {
      send_simple(fd, 403, "Forbidden", "IP-camera LAN mode accepts only private/link-local peers");
      ::close(fd);
      continue;
    }
    const uint32_t previous = open_clients.fetch_add(1);
    if (previous >= max_clients) {
      open_clients.fetch_sub(1);
      send_simple(fd, 503, "Service Unavailable", "Too many clients", "Retry-After: 2\r\n");
      ::close(fd);
      continue;
    }
    try {
      std::thread([fd, peer, expected_auth, fps] {
        OpenClientLease lease;
        try {
          client(fd, peer, expected_auth, fps);
        } catch (const std::exception& error) {
          std::fprintf(stderr, "ip camera client error: %s\n", error.what());
          ::shutdown(fd, SHUT_RDWR);
          ::close(fd);
        } catch (...) {
          std::fprintf(stderr, "ip camera client error: unknown exception\n");
          ::shutdown(fd, SHUT_RDWR);
          ::close(fd);
        }
      }).detach();
    } catch (...) {
      open_clients.fetch_sub(1);
      ::close(fd);
    }
  }

  if (listener_fd >= 0) ::close(server);
  listener_fd = -1;
  run = false;
  demand_cv.notify_all();
  frames.wake_all();
  if (feed.joinable()) feed.join();

  // Client sockets have finite I/O timeouts and streaming loops observe `run`.
  // Drain detached handlers before process teardown so none can touch globals
  // while their destructors are running.
  {
    std::unique_lock<std::mutex> lock(open_clients_mutex);
    open_clients_cv.wait(lock, [] { return open_clients.load() == 0; });
  }
  return 0;
}
