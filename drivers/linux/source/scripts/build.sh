#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
PROJECT_ROOT="$(cd "$SOURCE_ROOT/../../.." && pwd)"
ARCH="$(uname -m)"
select_work_root(){
  local candidate="$PROJECT_ROOT/.cache/linux-driver"
  if mkdir -p "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  candidate="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/kinect360-remold/linux-driver"
  mkdir -p "$candidate"
  printf '%s' "$candidate"
}
WORK_ROOT="${REMOLD_WORK_ROOT:-$(select_work_root)}"
BUILD_DIR="${REMOLD_BUILD_DIR:-$WORK_ROOT/build/$ARCH}"
DIST_DIR="${REMOLD_DIST_DIR:-$WORK_ROOT/dist/$ARCH}"
JOBS="${REMOLD_BUILD_JOBS:-}"
INSTALL_DEPS=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--clean] [--no-deps] [--build-dir PATH] [--dist-dir PATH] [--] [CMake options]

Builds the Kinect 360 Remold Linux runtime from source. The Microsoft Kinect
Runtime v1.8 bundle is downloaded and validated during driver compilation;
UACFirmware 01.02.709.00 is extracted and embedded into the Linux audio bridge.
USAGE
}

CLEAN=0
CMAKE_ARGS=()
while (($#)); do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --no-deps) INSTALL_DEPS=0; shift ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --dist-dir) DIST_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; CMAKE_ARGS+=("$@"); break ;;
    *) CMAKE_ARGS+=("$1"); shift ;;
  esac
done

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
missing_build_deps(){
  local missing=0
  for cmd in cmake pkg-config python3 cabextract msiextract; do
    if ! need_cmd "$cmd"; then echo "Missing build tool: $cmd" >&2; missing=1; fi
  done
  if need_cmd pkg-config; then
    pkg-config --exists 'libusb-1.0 >= 1.0.18' || { echo 'Missing libusb-1.0 >= 1.0.18 development package.' >&2; missing=1; }
    pkg-config --exists alsa || { echo 'Missing ALSA development package.' >&2; missing=1; }
  fi
  return "$missing"
}

install_build_deps(){
  (( INSTALL_DEPS )) || return 0
  if missing_build_deps >/dev/null 2>&1; then return 0; fi
  local SUDO=()
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then SUDO=(sudo); else return 1; fi
  fi
  echo '[toolchain] Installing Linux build dependencies...'
  if command -v apt-get >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update || return 1
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential cmake pkg-config libusb-1.0-0-dev libasound2-dev libjpeg-dev \
      cabextract msitools python3 ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install -y gcc-c++ cmake pkgconf-pkg-config libusb1-devel alsa-lib-devel \
      libjpeg-turbo-devel cabextract msitools python3 ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    "${SUDO[@]}" pacman -S --needed --noconfirm base-devel cmake pkgconf libusb alsa-lib \
      libjpeg-turbo cabextract msitools python ca-certificates
  else
    return 1
  fi
}


# The compile stage owns toolchain and dependency acquisition before CMake runs.
if ! install_build_deps; then
  echo 'Automatic build dependency installation is unavailable on this system.' >&2
fi
if ! missing_build_deps; then
  echo 'Linux driver compilation requires CMake, pkg-config, Python 3, cabextract, msitools, libusb-1.0 >= 1.0.18 and ALSA development files.' >&2
  exit 2
fi

if (( CLEAN )); then
  rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR"
rm -rf "$DIST_DIR"

echo '============================================================'
echo ' Kinect Xbox 360 Remold v1.0 - Linux driver build'
echo ' libusb-1.0 camera/control transport + ALSA audio runtime'
echo '============================================================'
echo 'Firmware source : Microsoft Kinect for Windows Runtime v1.8 (1.8.0.595)'
echo 'Firmware image  : UACFirmware 01.02.709.00'
echo 'Runtime SHA-256 : f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9'
echo 'Firmware SHA256 : 4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9'
echo 'Transport       : libusb-1.0 over usbfs + udev; USB Audio through ALSA'
echo

cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON -DREMOLD_FIRMWARE_CACHE_DIR="$WORK_ROOT/downloads" "${CMAKE_ARGS[@]}"

build_targets(){
  if [[ -n "$JOBS" ]]; then cmake --build "$BUILD_DIR" --parallel "$JOBS" --target "$@"
  else cmake --build "$BUILD_DIR" --parallel --target "$@"
  fi
}

echo '[1/4] Building camera and virtual webcam...'
build_targets kinect360-remold-camera kinect360-remold-v4l2
if grep -q '^REMOLD_BUILD_IP_CAMERA:BOOL=ON' "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  build_targets kinect360-remold-camera-ip
fi

echo '[2/4] Building libusb Motor and NUI Audio transport...'
echo '      [device 1/4] Building persistent control broker and NUI compatibility endpoint...'
build_targets kinect360-remold-broker kinect360-remold-nui
echo '      [device 2/4] Building 1414/1473 physical-control transport...'
build_targets kinect360-remold-broker
echo '      [device 3/4] Downloading pinned Runtime v1.8, extracting UACFirmware and building audio bridge...'
build_targets remold-uac-firmware kinect360-remold-audio
echo '      [device 4/4] Device transport outputs complete.'

echo '[3/4] Building setup/control utility...'
build_targets kinect360-remoldctl

echo '[4/4] Creating unified distribution...'
cmake --install "$BUILD_DIR" --prefix "$DIST_DIR"

mkdir -p "$DIST_DIR/support"
for dir in udev systemd config scripts; do
  cp -a "$SOURCE_ROOT/$dir" "$DIST_DIR/support/"
done

expected=(
  "$DIST_DIR/bin/kinect360-remoldctl"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-nui"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-broker"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-audio"
  "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-v4l2"
  "$DIST_DIR/libexec/kinect360-remold/ensure-v4l2-device.sh"
)
for file in "${expected[@]}"; do
  [[ -x "$file" ]] || { echo "Missing expected build artifact: $file" >&2; exit 3; }
done

cat > "$DIST_DIR/BUILD-MANIFEST.txt" <<MANIFEST
Kinect Xbox 360 Remold native Linux runtime
Version: 1.0
Architecture: $ARCH
Source: drivers/linux/source
Build type: Release
USB transport: libusb-1.0 over usbfs/udev
Kinect Runtime source: Microsoft Kinect for Windows Runtime v1.8 (1.8.0.595)
Kinect Runtime SHA-256: f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9
Embedded UACFirmware: 01.02.709.00
UACFirmware SHA-256: 4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9
Models: Kinect Xbox 360 1414, 1473
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

# Remember the exact distribution path outside the source tree as well.  This
# lets INSTALL locate a build that had to fall back to the user's cache when
# the unpacked project itself is read-only.
STATE_DIR="${HOME:-/tmp}/.local/state/kinect360-remold"
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  printf '%s\n' "$DIST_DIR" > "$STATE_DIR/linux-driver-dist-$ARCH.path"
fi
if [[ -n "${XDG_STATE_HOME:-}" && "$XDG_STATE_HOME" != "${HOME:-/tmp}/.local/state" ]]; then
  XDG_REMOLD_STATE="$XDG_STATE_HOME/kinect360-remold"
  if mkdir -p "$XDG_REMOLD_STATE" 2>/dev/null; then
    printf '%s\n' "$DIST_DIR" > "$XDG_REMOLD_STATE/linux-driver-dist-$ARCH.path"
  fi
fi

printf '\nLinux Remold runtime built from current source.\nOutput: %s\n' "$DIST_DIR"
printf 'The audio bridge embeds UACFirmware 01.02.709.00 from Kinect Runtime v1.8.\n'
