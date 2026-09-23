#include <cerrno>
#include <csignal>
#include <cstdio>
#include <string>
#include <unistd.h>

#include "remold/device_registry.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
constexpr int kClientTimeoutMs = 1000;
volatile std::sig_atomic_t stop_requested = 0;
volatile std::sig_atomic_t listener_fd = -1;

void stop_handler(int) {
  stop_requested = 1;
  const int fd = listener_fd;
  listener_fd = -1;
  if (fd >= 0) ::close(fd);
}

std::string row(const devices::Device& device) {
  return device.id + "\t" + device.label + "\t" + device.state + "\t" + device.control +
         "\t" + device.camera + "\t" + device.audio + "\t" + device.audio_control + "\t" +
         device.virtual_camera + "\t" + device.sdk + "\n";
}

void trim_request(std::string& request) {
  while (!request.empty()) {
    const char ch = request.back();
    if (ch != '\r' && ch != '\n' && ch != ' ' && ch != '\t') break;
    request.pop_back();
  }
}

bool parse_index(const std::string& text, size_t& index) {
  if (text.empty()) return false;
  try {
    size_t consumed = 0;
    const unsigned long value = std::stoul(text, &consumed, 10);
    if (consumed != text.size()) return false;
    index = static_cast<size_t>(value);
    return static_cast<unsigned long>(index) == value;
  } catch (...) {
    return false;
  }
}

void client(int fd) {
  (void)unixio::set_io_timeout(fd, kClientTimeoutMs);

  char buffer[512]{};
  const ssize_t count = ::read(fd, buffer, sizeof(buffer) - 1);
  if (count <= 0) return;

  std::string request(buffer, static_cast<size_t>(count));
  trim_request(request);
  const auto list = devices::read_manifest();
  std::string output = "# Kinect360Remold SDK\n";

  if (request == "LIST") {
    for (const auto& device : list) output += row(device);
  } else if (request.rfind("GET ", 0) == 0) {
    const std::string id = request.substr(4);
    const auto* device = devices::find(list, id);
    output += device ? row(*device) : "ERROR\tnot-found\n";
  } else if (request.rfind("INDEX ", 0) == 0) {
    size_t index = 0;
    if (!parse_index(request.substr(6), index)) {
      output += "ERROR\tbad-index\n";
    } else {
      output += index < list.size() ? row(list[index]) : "ERROR\tnot-found\n";
    }
  } else {
    output += "ERROR\tusage LIST | GET <deviceId> | INDEX <sensorIndex>\n";
  }

  (void)unixio::write_all(fd, output.data(), output.size());
}
}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  int server = unixio::local_server_socket(kSdkSocket, 32);
  if (server < 0) {
    std::perror("sdk socket");
    return 3;
  }
  listener_fd = server;

  // SDK requests are tiny and bounded by a 1-second socket timeout. Handling
  // them serially avoids an unbounded detached-thread surface while preserving
  // enough concurrency through the kernel listen backlog.
  while (!stop_requested) {
    int client_fd = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (client_fd < 0) {
      if (stop_requested) break;
      if (errno == EINTR) continue;
      unixio::retry_sleep(50);
      continue;
    }
    client(client_fd);
    ::close(client_fd);
  }

  if (listener_fd >= 0) {
    ::close(static_cast<int>(listener_fd));
    listener_fd = -1;
  }
  ::unlink(kSdkSocket);
  return 0;
}
