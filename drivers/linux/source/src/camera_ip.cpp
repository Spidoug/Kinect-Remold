#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <jpeglib.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include "remold/config.hpp"
#include "remold/device_registry.hpp"
#include "remold/protocol.hpp"
#include "remold/raw_sensor.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {

std::atomic<bool> run{true};
std::atomic<uint32_t> active_clients{0};
std::mutex demand_mutex;
std::condition_variable demand_cv;

std::mutex handler_mutex;
std::condition_variable handler_cv;
std::map<int, bool> handler_fds;
std::size_t handler_count = 0;

void stop_handler(int) {
  run = false;
}

std::string trim(std::string value) {
  const auto not_space = [](unsigned char c) { return c != ' ' && c != '\t' && c != '\r'; };
  value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
  value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
  return value;
}

std::string lowercase(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    if (c >= 'A' && c <= 'Z') return static_cast<char>(c - 'A' + 'a');
    return static_cast<char>(c);
  });
  return value;
}

std::string base64(const std::string& input) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  std::string output;
  uint32_t value = 0;
  int bits = -6;
  for (char raw : input) {
    const auto c = static_cast<unsigned char>(raw);
    value = (value << 8) + c;
    bits += 8;
    while (bits >= 0) {
      output.push_back(alphabet[(value >> bits) & 63]);
      bits -= 6;
    }
  }
  if (bits > -6) output.push_back(alphabet[((value << 8) >> (bits + 8)) & 63]);
  while (output.size() % 4 != 0) output.push_back('=');
  return output;
}

std::vector<uint8_t> jpeg_bayer(const uint8_t* pixels, int width, int height, int quality) {
  std::vector<uint8_t> rgb;
  rawsensor::bayer_grbg_to_rgb24(pixels, width, height, rgb);
  if (rgb.empty()) return {};

  jpeg_compress_struct compressor{};
  jpeg_error_mgr errors{};
  compressor.err = jpeg_std_error(&errors);
  jpeg_create_compress(&compressor);

  unsigned char* output = nullptr;
  unsigned long output_size = 0;
  jpeg_mem_dest(&compressor, &output, &output_size);
  compressor.image_width = static_cast<JDIMENSION>(width);
  compressor.image_height = static_cast<JDIMENSION>(height);
  compressor.input_components = 3;
  compressor.in_color_space = JCS_RGB;
  jpeg_set_defaults(&compressor);
  jpeg_set_quality(&compressor, quality, TRUE);
  jpeg_start_compress(&compressor, TRUE);

  while (compressor.next_scanline < compressor.image_height) {
    const std::size_t row_offset = static_cast<std::size_t>(compressor.next_scanline) *
                                   static_cast<std::size_t>(width) * 3u;
    JSAMPROW row = rgb.data() + row_offset;
    jpeg_write_scanlines(&compressor, &row, 1);
  }

  jpeg_finish_compress(&compressor);
  std::vector<uint8_t> result;
  if (output && output_size != 0) result.assign(output, output + output_size);
  std::free(output);
  jpeg_destroy_compress(&compressor);
  return result;
}

class Frames {
 public:
  void set(std::vector<uint8_t> frame) {
    if (frame.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    jpeg_ = std::move(frame);
    ++sequence_;
    cv_.notify_all();
  }

  uint64_t sequence() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sequence_;
  }

  bool wait(uint64_t& last, std::vector<uint8_t>& output, std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, timeout, [&] { return !run.load() || sequence_ != last; });
    if (!run.load()) return false;
    if (sequence_ == last) return true;
    last = sequence_;
    output = jpeg_;
    return true;
  }

  void wake_all() {
    cv_.notify_all();
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<uint8_t> jpeg_;
  uint64_t sequence_ = 0;
} frames;

class ClientLease {
 public:
  ClientLease() {
    active_clients.fetch_add(1);
    demand_cv.notify_all();
  }

  ~ClientLease() {
    active_clients.fetch_sub(1);
    demand_cv.notify_all();
  }

  ClientLease(const ClientLease&) = delete;
  ClientLease& operator=(const ClientLease&) = delete;
};

void finish_handler(int fd) {
  {
    std::lock_guard<std::mutex> lock(handler_mutex);
    handler_fds.erase(fd);
    if (handler_count != 0) --handler_count;
  }
  ::close(fd);
  handler_cv.notify_all();
}

class HandlerGuard {
 public:
  explicit HandlerGuard(int fd) : fd_(fd) {}
  ~HandlerGuard() { finish_handler(fd_); }
  HandlerGuard(const HandlerGuard&) = delete;
  HandlerGuard& operator=(const HandlerGuard&) = delete;

 private:
  int fd_;
};

int subscribe_rgb(bool high_quality) {
  const std::string endpoint = devices::primary_camera_endpoint();
  if (endpoint.empty()) return -1;

  const int fd = unixio::connect_socket(endpoint);
  if (fd < 0) return -1;

  scanner::Request request{};
  request.streamMask = high_quality ? scanner::StreamRgbHighQuality : scanner::StreamRgb;
  scanner::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply)) ||
      reply.magic != scanner::kMagic || reply.version != scanner::kVersion ||
      reply.result < 0 || reply.acceptedMask != request.streamMask) {
    ::close(fd);
    return -1;
  }
  return fd;
}

void feeder(int quality, bool high_quality) {
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  while (run.load()) {
    {
      std::unique_lock<std::mutex> lock(demand_mutex);
      demand_cv.wait(lock, [] { return !run.load() || active_clients.load() > 0; });
    }
    if (!run.load()) break;

    int fd = subscribe_rgb(high_quality);
    if (fd < 0) {
      unixio::retry_sleep(300);
      continue;
    }

    while (run.load() && active_clients.load() > 0) {
      scanner::FrameHeader header{};
      if (!unixio::read_exact(fd, &header, sizeof(header)) ||
          header.magic != scanner::kFrameMagic || header.version != scanner::kVersion ||
          header.payloadBytes > payload.size() ||
          !unixio::read_exact(fd, payload.data(), header.payloadBytes)) {
        break;
      }

      const bool standard_rgb =
          header.mode == scanner::StreamMode::Rgb &&
          header.payloadBytes == scanner::kRgbRawPayloadBytes;
      const bool high_quality_rgb =
          header.mode == scanner::StreamMode::RgbHighQuality &&
          header.payloadBytes == scanner::kRgbHqPayloadBytes;
      if (header.pixelFormat != scanner::PixelFormat::BayerGrbg8 ||
          (!standard_rgb && !high_quality_rgb)) {
        continue;
      }

      const int width = high_quality_rgb ? static_cast<int>(scanner::kRgbHqWidth)
                                         : static_cast<int>(scanner::kWidth);
      const int height = high_quality_rgb ? static_cast<int>(scanner::kRgbHqHeight)
                                          : static_cast<int>(scanner::kHeight);
      frames.set(jpeg_bayer(payload.data(), width, height, quality));
    }
    ::close(fd);
  }
}

bool send_all(int fd, const void* data, size_t bytes) {
  return unixio::write_all(fd, data, bytes);
}

bool send_text_response(int fd,
                        int status,
                        const char* reason,
                        const char* extra_headers = "") {
  std::ostringstream response;
  response << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
           << extra_headers
           << "Content-Length: 0\r\n"
           << "Connection: close\r\n\r\n";
  const std::string text = response.str();
  return send_all(fd, text.data(), text.size());
}

struct HttpRequest {
  std::string method;
  std::string path;
  std::map<std::string, std::string> headers;
};

bool read_http_request(int fd, HttpRequest& output) {
  std::string request;
  char buffer[2048];
  while (request.size() < 8192 && request.find("\r\n\r\n") == std::string::npos) {
    const ssize_t received = ::recv(fd, buffer, sizeof(buffer), 0);
    if (received > 0) {
      request.append(buffer, static_cast<size_t>(received));
      continue;
    }
    if (received < 0 && errno == EINTR) continue;
    return false;
  }

  const std::size_t headers_end = request.find("\r\n\r\n");
  if (headers_end == std::string::npos) return false;

  std::istringstream stream(request.substr(0, headers_end));
  std::string line;
  if (!std::getline(stream, line)) return false;
  if (!line.empty() && line.back() == '\r') line.pop_back();

  std::istringstream first_line(line);
  std::string version;
  if (!(first_line >> output.method >> output.path >> version)) return false;
  std::string extra;
  if (first_line >> extra) return false;
  if (version != "HTTP/1.0" && version != "HTTP/1.1") return false;

  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const std::size_t separator = line.find(':');
    if (separator == std::string::npos) return false;
    const std::string name = lowercase(trim(line.substr(0, separator)));
    if (name.empty()) return false;
    output.headers[name] = trim(line.substr(separator + 1));
  }
  return true;
}

void client(int fd, const std::string& auth) {
  HandlerGuard guard(fd);
  (void)unixio::set_io_timeout(fd, 5000);

  HttpRequest request;
  if (!read_http_request(fd, request)) {
    (void)send_text_response(fd, 400, "Bad Request");
    return;
  }

  if (request.method != "GET") {
    (void)send_text_response(fd, 405, "Method Not Allowed", "Allow: GET\r\n");
    return;
  }

  const auto authorization = request.headers.find("authorization");
  const std::string expected = "Basic " + auth;
  if (authorization == request.headers.end() || authorization->second != expected) {
    (void)send_text_response(
        fd, 401, "Unauthorized",
        "WWW-Authenticate: Basic realm=\"Kinect360Remold\"\r\n");
    return;
  }

  const bool snapshot = request.path == "/snapshot.jpg";
  const bool stream = request.path == "/" || request.path == "/stream.mjpeg" ||
                      request.path == "/mjpeg";
  if (!snapshot && !stream) {
    (void)send_text_response(fd, 404, "Not Found");
    return;
  }

  ClientLease lease;
  uint64_t sequence = frames.sequence();

  if (snapshot) {
    std::vector<uint8_t> jpeg;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (run.load() && jpeg.empty() && std::chrono::steady_clock::now() < deadline) {
      if (!frames.wait(sequence, jpeg, std::chrono::milliseconds(500))) return;
    }

    if (jpeg.empty()) {
      (void)send_text_response(fd, 503, "Service Unavailable", "Retry-After: 1\r\n");
      return;
    }

    std::ostringstream headers;
    headers << "HTTP/1.1 200 OK\r\n"
            << "Content-Type: image/jpeg\r\n"
            << "Content-Length: " << jpeg.size() << "\r\n"
            << "Cache-Control: no-store\r\n"
            << "Connection: close\r\n\r\n";
    const std::string text = headers.str();
    (void)(send_all(fd, text.data(), text.size()) &&
           send_all(fd, jpeg.data(), jpeg.size()));
    return;
  }

  const std::string headers =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
      "Cache-Control: no-store\r\n"
      "Connection: close\r\n\r\n";
  if (!send_all(fd, headers.data(), headers.size())) return;

  while (run.load()) {
    std::vector<uint8_t> jpeg;
    if (!frames.wait(sequence, jpeg, std::chrono::seconds(2))) break;
    if (jpeg.empty()) continue;

    std::ostringstream part;
    part << "--frame\r\n"
         << "Content-Type: image/jpeg\r\n"
         << "Content-Length: " << jpeg.size() << "\r\n\r\n";
    const std::string text = part.str();
    if (!send_all(fd, text.data(), text.size()) ||
        !send_all(fd, jpeg.data(), jpeg.size()) ||
        !send_all(fd, "\r\n", 2)) {
      break;
    }
  }
}

void register_handler(int fd) {
  std::lock_guard<std::mutex> lock(handler_mutex);
  handler_fds.emplace(fd, true);
  ++handler_count;
}

void cancel_handlers() {
  std::lock_guard<std::mutex> lock(handler_mutex);
  for (const auto& item : handler_fds) {
    ::shutdown(item.first, SHUT_RDWR);
  }
}

void wait_for_handlers() {
  std::unique_lock<std::mutex> lock(handler_mutex);
  handler_cv.wait(lock, [] { return handler_count == 0; });
}

}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  if (!config.get_bool("ip.enabled", false)) return 0;

  const std::string user = config.get("ip.user", "admin");
  const std::string password = config.get("ip.password", "");
  if (user.empty() || password.empty()) {
    std::fprintf(stderr, "ip.user/ip.password must not be empty; refusing insecure startup\n");
    return 2;
  }

  const int port = config.get_int("ip.port", 8088);
  if (port < 1 || port > 65535) {
    std::fprintf(stderr, "ip.port must be in the range 1..65535\n");
    return 2;
  }

  const int quality = std::clamp(config.get_int("ip.jpeg_quality", 78), 30, 95);
  const bool high_quality = config.get_bool("rgb.hq.enabled", false);

  std::thread feed(feeder, quality, high_quality);

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
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  if (::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0 ||
      ::listen(server, 16) < 0) {
    std::perror("ip camera");
    ::close(server);
    run = false;
    demand_cv.notify_all();
    feed.join();
    return 3;
  }

  const std::string auth = base64(user + ":" + password);
  while (run.load()) {
    pollfd descriptor{server, POLLIN, 0};
    const int poll_result = ::poll(&descriptor, 1, 250);
    if (poll_result < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (poll_result == 0) continue;
    if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) break;
    if ((descriptor.revents & POLLIN) == 0) continue;

    const int fd = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (fd < 0) {
      if (errno == EINTR) continue;
      break;
    }

    register_handler(fd);
    try {
      std::thread(client, fd, auth).detach();
    } catch (...) {
      finish_handler(fd);
    }
  }

  run = false;
  ::close(server);
  demand_cv.notify_all();
  frames.wake_all();
  cancel_handlers();
  wait_for_handlers();
  if (feed.joinable()) feed.join();
  return 0;
}
