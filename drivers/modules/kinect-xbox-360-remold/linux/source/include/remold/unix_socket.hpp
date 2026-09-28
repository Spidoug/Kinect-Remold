#pragma once

#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <grp.h>
#include <string>
#include <system_error>
#include <thread>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

namespace remold::unixio {

inline uint64_t monotonic_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

inline void close_fd(int& fd) {
  if (fd >= 0) {
    ::close(fd);
    fd = -1;
  }
}

inline bool read_exact(int fd, void* data, size_t bytes) {
  auto* output = static_cast<unsigned char*>(data);
  size_t done = 0;
  while (done < bytes) {
    const ssize_t count = ::recv(fd, output + done, bytes - done, 0);
    if (count == 0) return false;
    if (count < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    done += static_cast<size_t>(count);
  }
  return true;
}

inline bool write_all(int fd, const void* data, size_t bytes) {
  const auto* input = static_cast<const unsigned char*>(data);
  size_t done = 0;
  while (done < bytes) {
    const ssize_t count = ::send(fd, input + done, bytes - done, MSG_NOSIGNAL);
    if (count == 0) return false;
    if (count < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    done += static_cast<size_t>(count);
  }
  return true;
}

// Real-time publishers must never wait behind a slow local consumer. A partial
// nonblocking frame is treated as a failed subscriber and the caller closes it.
inline bool write_all_nonblocking(int fd, const void* data, size_t bytes) {
  const auto* input = static_cast<const unsigned char*>(data);
  size_t done = 0;
  while (done < bytes) {
    const ssize_t count = ::send(
        fd, input + done, bytes - done, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (count == 0) return false;
    if (count < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    done += static_cast<size_t>(count);
  }
  return true;
}

inline bool socket_address(const std::string& path, sockaddr_un& address, socklen_t& length) {
  if (path.empty() || path.size() >= sizeof(address.sun_path)) {
    errno = path.empty() ? EINVAL : ENAMETOOLONG;
    return false;
  }
  address = {};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  length = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.size() + 1);
  return true;
}

inline int server_socket(const std::string& path, mode_t mode = 0660, int backlog = 16,
                         const char* group = nullptr) {
  const std::filesystem::path parent = std::filesystem::path(path).parent_path();
  if (!parent.empty()) {
    std::error_code error;
    std::filesystem::create_directories(parent, error);
    if (error) {
      errno = error.value();
      return -1;
    }
  }

  sockaddr_un address{};
  socklen_t address_length = 0;
  if (!socket_address(path, address, address_length)) return -1;

  ::unlink(path.c_str());
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;

  if (::bind(fd, reinterpret_cast<sockaddr*>(&address), address_length) < 0) {
    close_fd(fd);
    return -1;
  }

  if (group) {
    const struct group* entry = ::getgrnam(group);
    if (!entry || ::chown(path.c_str(), 0, entry->gr_gid) < 0) {
      const int saved = entry ? errno : ENOENT;
      ::unlink(path.c_str());
      close_fd(fd);
      errno = saved;
      return -1;
    }
  }

  if (::chmod(path.c_str(), mode) < 0) {
    const int saved = errno;
    ::unlink(path.c_str());
    close_fd(fd);
    errno = saved;
    return -1;
  }
  if (::listen(fd, backlog) < 0) {
    const int saved = errno;
    ::unlink(path.c_str());
    close_fd(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

// Product-local IPC is intentionally available to the interactive desktop user
// immediately after installation. Relying on supplementary video/audio groups
// here would require a logout/login before an already-running desktop session
// could connect, even though the privileged hardware services are healthy.
inline int local_server_socket(const std::string& path, int backlog = 16) {
  return server_socket(path, 0666, backlog, nullptr);
}

inline int connect_socket(const std::string& path) {
  sockaddr_un address{};
  socklen_t address_length = 0;
  if (!socket_address(path, address, address_length)) return -1;

  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  if (::connect(fd, reinterpret_cast<sockaddr*>(&address), address_length) < 0) {
    close_fd(fd);
    return -1;
  }
  return fd;
}

// Bounds blocking send/recv on a connected socket. A request that outlives
// the timeout fails instead of stalling its caller.
inline bool set_io_timeout(int fd, int ms) {
  if (ms < 0) {
    errno = EINVAL;
    return false;
  }
  timeval timeout{};
  timeout.tv_sec = ms / 1000;
  timeout.tv_usec = (ms % 1000) * 1000;
  return ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
         ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

inline void retry_sleep(int ms = 500) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

}  // namespace remold::unixio
