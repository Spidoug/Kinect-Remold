#pragma once

#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

namespace remold::unixio {

inline uint64_t monotonic_ms() {
  using namespace std::chrono;
  const auto elapsed = duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
  return elapsed < 0 ? 0u : static_cast<uint64_t>(elapsed);
}

inline void close_fd(int& fd) {
  if (fd >= 0) {
    ::close(fd);
    fd = -1;
  }
}

inline bool set_io_timeout(int fd, int timeout_ms) {
  if (fd < 0 || timeout_ms < 0) {
    errno = EINVAL;
    return false;
  }

  timeval timeout{};
  timeout.tv_sec = timeout_ms / 1000;
  timeout.tv_usec = (timeout_ms % 1000) * 1000;
  return ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
         ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

inline bool read_exact(int fd, void* data, size_t bytes) {
  auto* cursor = static_cast<unsigned char*>(data);
  size_t total = 0;
  while (total < bytes) {
    const ssize_t received = ::recv(fd, cursor + total, bytes - total, 0);
    if (received > 0) {
      total += static_cast<size_t>(received);
      continue;
    }
    if (received == 0) return false;
    if (errno == EINTR) continue;
    return false;
  }
  return true;
}

inline bool write_all(int fd, const void* data, size_t bytes) {
  const auto* cursor = static_cast<const unsigned char*>(data);
  size_t total = 0;
  while (total < bytes) {
    const ssize_t written = ::send(fd, cursor + total, bytes - total, MSG_NOSIGNAL);
    if (written > 0) {
      total += static_cast<size_t>(written);
      continue;
    }
    if (written == 0) {
      errno = EPIPE;
      return false;
    }
    if (errno == EINTR) continue;
    return false;
  }
  return true;
}

inline bool fill_unix_address(const std::string& path, sockaddr_un& address, socklen_t& length) {
  if (path.size() >= sizeof(address.sun_path)) {
    errno = ENAMETOOLONG;
    return false;
  }

  address = {};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  length = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.size() + 1);
  return true;
}

inline int server_socket(const std::string& path, mode_t mode = 0666, int backlog = 16) {
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(path).parent_path(), ec);
  if (ec) {
    errno = ec.value();
    return -1;
  }

  sockaddr_un address{};
  socklen_t address_length = 0;
  if (!fill_unix_address(path, address, address_length)) return -1;

  ::unlink(path.c_str());
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;

  if (::bind(fd, reinterpret_cast<sockaddr*>(&address), address_length) < 0) {
    close_fd(fd);
    return -1;
  }
  if (::chmod(path.c_str(), mode) < 0) {
    close_fd(fd);
    ::unlink(path.c_str());
    return -1;
  }
  if (::listen(fd, backlog) < 0) {
    close_fd(fd);
    ::unlink(path.c_str());
    return -1;
  }
  return fd;
}

inline int connect_socket(const std::string& path) {
  sockaddr_un address{};
  socklen_t address_length = 0;
  if (!fill_unix_address(path, address, address_length)) return -1;

  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;

  if (::connect(fd, reinterpret_cast<sockaddr*>(&address), address_length) < 0) {
    close_fd(fd);
    return -1;
  }
  return fd;
}

inline void retry_sleep(int milliseconds = 500) {
  std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
}

}  // namespace remold::unixio
