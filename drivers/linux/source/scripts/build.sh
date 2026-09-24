#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
find_project_root(){
  local d="$SOURCE_ROOT" parent
  for _ in {1..16}; do
    if [[ -f "$d/VERSION" && -d "$d/drivers" && -d "$d/applications" && -d "$d/scripts" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    parent="$(dirname "$d")"
    [[ "$parent" != "$d" ]] || break
    d="$parent"
  done
  return 1
}
PROJECT_ROOT="$(find_project_root)" || { echo 'Project root not found above Linux driver source tree.' >&2; exit 2; }
ARCH="$(uname -m)"
BUILD_ROOT="${REMOLD_BUILD_ROOT:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/kinect360-remold/build}"
BUILD_DIR="$BUILD_ROOT/linux-$ARCH"
DIST_DIR="${REMOLD_DIST_DIR:-$PROJECT_ROOT/binaries/linux/drivers}"
SDK_DIR="$PROJECT_ROOT/binaries/linux/sdk"
CLEAN=0
CMAKE_ARGS=()

while (($#)); do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --build-dir) [[ $# -ge 2 ]] || { echo '--build-dir requires a path.' >&2; exit 2; }; BUILD_DIR="$2"; shift 2 ;;
    --dist-dir) [[ $# -ge 2 ]] || { echo '--dist-dir requires a path.' >&2; exit 2; }; DIST_DIR="$2"; shift 2 ;;
    --) shift; CMAKE_ARGS+=("$@"); break ;;
    *) CMAKE_ARGS+=("$1"); shift ;;
  esac
done

run_root(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
    sudo "$@"
    return
  fi
  if command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  echo 'Administrator permission is required to install missing Linux build dependencies, but neither sudo nor pkexec is available.' >&2
  return 1
}

build_dependencies_ready(){
  command -v cmake >/dev/null 2>&1 || return 1
  command -v c++ >/dev/null 2>&1 || return 1
  command -v make >/dev/null 2>&1 || return 1
  command -v pkg-config >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  command -v cabextract >/dev/null 2>&1 || return 1
  command -v msiextract >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  command -v modinfo >/dev/null 2>&1 || return 1
  command -v modprobe >/dev/null 2>&1 || return 1
  command -v depmod >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  command -v udevadm >/dev/null 2>&1 || return 1
  command -v getent >/dev/null 2>&1 || return 1
  command -v groupadd >/dev/null 2>&1 || return 1
  command -v useradd >/dev/null 2>&1 || return 1
  command -v ldd >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  [[ -r "/lib/modules/$(uname -r)/build/Makefile" ]] || return 1
  pkg-config --exists libusb-1.0 || return 1
  pkg-config --exists alsa || return 1
  pkg-config --exists opencv4 || return 1
  pkg-config --exists libjpeg || return 1
  return 0
}

install_build_dependencies(){
  echo 'Missing Linux build dependencies were detected.' >&2
  echo 'Administrator permission will be requested to install the compiler and development libraries.' >&2

  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential cmake pkg-config curl ca-certificates python3 cabextract msitools kmod tar \
      systemd udev passwd \
      libusb-1.0-0-dev libasound2-dev libopencv-dev libjpeg-dev
    kernel_headers="linux-headers-$(uname -r)"
    if apt-cache show "$kernel_headers" >/dev/null 2>&1; then
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$kernel_headers"
    fi
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y \
      gcc-c++ make cmake pkgconf-pkg-config curl ca-certificates python3 cabextract msitools kmod tar \
      systemd-udev shadow-utils \
      libusb1-devel alsa-lib-devel opencv-devel libjpeg-turbo-devel
    run_root dnf install -y "kernel-devel-$(uname -r)" 2>/dev/null || true
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    run_root pacman -S --needed --noconfirm \
      base-devel cmake pkgconf curl ca-certificates python cabextract msitools kmod tar \
      systemd shadow \
      libusb alsa-lib opencv libjpeg-turbo
    kernel_pkgbase="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
    if [[ -n "$kernel_pkgbase" ]]; then
      run_root pacman -S --needed --noconfirm "${kernel_pkgbase}-headers" 2>/dev/null || true
    else
      case "$(uname -r)" in
        *-lts*) kernel_headers=linux-lts-headers ;;
        *-zen*) kernel_headers=linux-zen-headers ;;
        *-hardened*) kernel_headers=linux-hardened-headers ;;
        *) kernel_headers=linux-headers ;;
      esac
      run_root pacman -S --needed --noconfirm "$kernel_headers" 2>/dev/null || true
    fi
    return
  fi

  cat >&2 <<'MSG'
Automatic dependency installation supports apt, dnf and pacman.
Install a C++ compiler, CMake, make, pkg-config, curl or wget, kmod, systemd/udev,
account-management utilities, the exact running-kernel headers, plus development
packages for libusb-1.0, ALSA, OpenCV and libjpeg. Then run the launcher again.
MSG
  return 2
}

if ! build_dependencies_ready; then
  install_build_dependencies
fi

build_dependencies_ready || {
  echo 'Linux build dependencies are still incomplete after dependency setup.' >&2
  echo 'Required: C++ compiler, CMake, make, pkg-config, curl/wget, Python 3, cabextract, msitools, kmod, systemd/udev, account-management utilities, exact running-kernel headers, libusb-1.0, ALSA, OpenCV and libjpeg development files.' >&2
  exit 2
}

(( CLEAN )) && rm -rf "$BUILD_DIR" "$DIST_DIR" "$SDK_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$SDK_DIR"

cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_BINDIR=bin \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DREMOLD_BUILD_HARDWARE=ON \
  "${CMAKE_ARGS[@]}"

cmake --build "$BUILD_DIR" --parallel "${REMOLD_BUILD_JOBS:-$(nproc 2>/dev/null || echo 2)}"

rm -rf "$DIST_DIR" "$SDK_DIR"
mkdir -p "$DIST_DIR" "$SDK_DIR"
cmake --install "$BUILD_DIR" --prefix "$DIST_DIR"

mkdir -p "$DIST_DIR/support"
for dir in udev systemd config modprobe modules-load firmware; do
  cp -a "$SOURCE_ROOT/$dir" "$DIST_DIR/support/"
done

# Prepare the Kinect UAC firmware required by the audio runtime and 1473 control path.
bash "$SOURCE_ROOT/scripts/prepare-uac-firmware.sh" \
  "$DIST_DIR/support/firmware/UACFirmware-01.02.709.00"

# Build and bundle the exact v4l2loopback module needed by the running kernel.
# Network/package-manager activity is intentionally confined to this BUILD stage;
# INSTALL.sh consumes this module without downloading anything.
bash "$SOURCE_ROOT/scripts/prepare-v4l2loopback.sh" \
  "$DIST_DIR/support/kernel"

install -m 0755 "$PROJECT_ROOT/drivers/linux/INSTALL.sh" "$DIST_DIR/INSTALL.sh"
install -m 0755 "$PROJECT_ROOT/drivers/linux/UNINSTALL.sh" "$DIST_DIR/UNINSTALL.sh"
install -m 0755 "$PROJECT_ROOT/drivers/linux/KINECT.sh" "$DIST_DIR/KINECT.sh"
install -m 0644 "$PROJECT_ROOT/VERSION" "$DIST_DIR/VERSION"
install -m 0644 "$SOURCE_ROOT/sdk/Kinect360RemoldControlProtocol.hpp" "$SDK_DIR/Kinect360RemoldControlProtocol.hpp"
install -m 0644 "$SOURCE_ROOT/sdk/Kinect360RemoldAudioControlProtocol.hpp" "$SDK_DIR/Kinect360RemoldAudioControlProtocol.hpp"

required_runtime=(
  "$DIST_DIR/bin/kinect360-remoldctl"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-broker"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-audio"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-v4l2"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera-ip"
  "$DIST_DIR/INSTALL.sh"
  "$DIST_DIR/UNINSTALL.sh"
  "$DIST_DIR/KINECT.sh"
  "$DIST_DIR/VERSION"
  "$DIST_DIR/support/udev/60-kinect360-remold.rules"
  "$DIST_DIR/support/modprobe/kinect360-remold-v4l2.conf"
  "$DIST_DIR/support/modprobe/kinect360-remold-camera.conf"
  "$DIST_DIR/support/modules-load/kinect360-remold.conf"
  "$DIST_DIR/support/config/remold.conf"
  "$DIST_DIR/support/systemd/kinect360-remold.target"
  "$DIST_DIR/support/systemd/kinect360-remold-broker.service"
  "$DIST_DIR/support/systemd/kinect360-remold-camera.service"
  "$DIST_DIR/support/systemd/kinect360-remold-audio.service"
  "$DIST_DIR/support/systemd/kinect360-remold-v4l2.service"
  "$DIST_DIR/support/systemd/kinect360-remold-camera-ip.service"
  "$DIST_DIR/support/firmware/UACFirmware-01.02.709.00"
  "$DIST_DIR/support/kernel/KERNEL-RELEASE"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-VERSION"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-SOURCE-SHA256"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-MODULE-SHA256"
  "$DIST_DIR/support/kernel/$(uname -r)/v4l2loopback.ko"
)
for artifact in "${required_runtime[@]}"; do
  [[ -e "$artifact" ]] || { echo "Linux runtime build did not publish required artifact: $artifact" >&2; exit 3; }
done

cat > "$SDK_DIR/README.md" <<'DOC'
# Kinect Xbox 360 Remold SDK endpoint

Linux SDK socket: `/run/kinect360-remold/sdk.sock`, hosted by `kinect360-remold-broker`.

Text commands: `LIST`, `GET <deviceId>`, `INDEX <sensorIndex>`. Returned rows use:
`id, label, state, control, camera, audio, audio-control, virtual-camera, sdk`.

SynKinect Studio and external clients discover devices through this endpoint. The runtime manifest is internal and is not part of the SDK surface.

`Kinect360RemoldControlProtocol.hpp` and `Kinect360RemoldAudioControlProtocol.hpp` define the public binary control contracts.
DOC

printf 'Linux driver: %s\nLinux SDK: %s\n' "$DIST_DIR" "$SDK_DIR"
