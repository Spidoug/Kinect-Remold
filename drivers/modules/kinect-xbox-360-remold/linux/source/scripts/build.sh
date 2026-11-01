#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[module] Kinect Remold — Xbox 360'

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
SMART_TILT="$PROJECT_ROOT/drivers/modules/kinect-xbox-360-remold/shared/Kinect360RemoldSmartTilt.h"
[[ -f "$SMART_TILT" ]] || { echo "Missing shared Smart Tilt source: $SMART_TILT" >&2; exit 2; }
WINDOWS_CONTROL="$PROJECT_ROOT/drivers/modules/kinect-xbox-360-remold/windows/source/components/device/shared/Kinect360RemoldControlProtocol.h"
LINUX_CONTROL="$SOURCE_ROOT/sdk/Kinect360RemoldControlProtocol.hpp"
for protocol_file in "$WINDOWS_CONTROL" "$LINUX_CONTROL"; do
  [[ -f "$protocol_file" ]] || { echo "Missing control protocol definition: $protocol_file" >&2; exit 2; }
  grep -Eq 'kMagic[[:space:]]*=[[:space:]]*0x54434D52u' "$protocol_file" || { echo "Control protocol magic mismatch: $protocol_file" >&2; exit 2; }
  grep -Eq 'kVersion[[:space:]]*=[[:space:]]*1;' "$protocol_file" || { echo "Control protocol version mismatch: $protocol_file" >&2; exit 2; }
  grep -Eq 'sizeof\(Request\)[[:space:]]*==[[:space:]]*80' "$protocol_file" || { echo "Control request ABI mismatch: $protocol_file" >&2; exit 2; }
  grep -Eq 'sizeof\(Reply\)[[:space:]]*==[[:space:]]*36' "$protocol_file" || { echo "Control reply ABI mismatch: $protocol_file" >&2; exit 2; }
done
ARCH="$(uname -m)"
ENV_HELPER="$PROJECT_ROOT/scripts/linux/lib/remold-env.sh"
BUILD_CONFIG="$PROJECT_ROOT/config/build.env"
LINUX_CONFIG="$PROJECT_ROOT/config/linux.env"
for config_file in "$ENV_HELPER" "$BUILD_CONFIG" "$LINUX_CONFIG"; do [[ -r "$config_file" ]] || { echo "Missing project configuration: $config_file" >&2; exit 2; }; done
source "$ENV_HELPER"
for config_file in "$BUILD_CONFIG" "$LINUX_CONFIG"; do
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^REMOLD_[A-Z0-9_]+$ ]] || continue
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$value"
  done < "$config_file"
done
CACHE_ROOT="$(remold_xdg_cache_root)" || { echo 'Could not resolve the cache directory.' >&2; exit 2; }
remold_install_paths || { echo 'Could not resolve Linux runtime directories; set the REMOLD_* path variables explicitly.' >&2; exit 2; }
RUNTIME_DIR="$REMOLD_RUNDIR/kinect360-remold"
CONFIG_PATH="$REMOLD_SYSCONFDIR/kinect360-remold/remold.conf"
FIRMWARE_PATH="$REMOLD_DATADIR/kinect360-remold/UACFirmware"
BUILD_ROOT="${REMOLD_BUILD_ROOT:-$CACHE_ROOT/build/linux/drivers/kinect-xbox-360-remold}"
BUILD_DIR="$BUILD_ROOT/linux-$ARCH"
DIST_DIR="${REMOLD_DIST_DIR:-$PROJECT_ROOT/binaries/linux/drivers/kinect-xbox-360-remold}"
SDK_DIR="$PROJECT_ROOT/binaries/linux/sdk/kinect-xbox-360-remold"
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
    sudo env REMOLD_CACHE_ROOT="$CACHE_ROOT" REMOLD_BUILD_ROOT="$BUILD_ROOT" "$@"
    return
  fi
  if command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo env REMOLD_CACHE_ROOT="$CACHE_ROOT" REMOLD_BUILD_ROOT="$BUILD_ROOT" "$@"
    return
  fi
  echo 'Administrator permission is required to install missing Linux build dependencies, but neither sudo nor pkexec is available.' >&2
  return 1
}

build_dependency_report(){
  local missing=() kernel_build='' tool=''

  for tool in cmake c++ make pkg-config python3 cabextract msiextract tar; do
    remold_find_command "$tool" >/dev/null 2>&1 || missing+=("command:$tool")
  done
  if ! remold_find_command curl >/dev/null 2>&1 && ! remold_find_command wget >/dev/null 2>&1; then
    missing+=("command:curl-or-wget")
  fi

  kernel_build="$(remold_kernel_build_dir "$(uname -r)" 2>/dev/null || true)"
  [[ -n "$kernel_build" && -r "$kernel_build/Makefile" ]] || missing+=("kernel-headers:$(uname -r)")

  if remold_find_command pkg-config >/dev/null 2>&1; then
    pkg-config --exists libusb-1.0 || missing+=("pkg-config:libusb-1.0")
    pkg-config --exists alsa || missing+=("pkg-config:alsa")
    pkg-config --exists opencv4 || missing+=("pkg-config:opencv4")
  fi

  if ((${#missing[@]})); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

build_dependencies_ready(){
  build_dependency_report >/dev/null
}

print_missing_build_dependencies(){
  local report=''
  report="$(build_dependency_report 2>/dev/null || true)"
  if [[ -n "$report" ]]; then
    echo 'Missing build requirements:' >&2
    while IFS= read -r item; do
      [[ -n "$item" ]] && printf '  - %s\n' "$item" >&2
    done <<< "$report"
  fi
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
    if ! modinfo snd-aloop >/dev/null 2>&1; then
      kernel_extra="linux-modules-extra-$(uname -r)"
      if apt-cache show "$kernel_extra" >/dev/null 2>&1; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$kernel_extra"
      fi
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
    kernel_root="$(remold_kernel_modules_root "$(uname -r)" 2>/dev/null || true)"
    kernel_pkgbase="$(cat "$kernel_root/$(uname -r)/pkgbase" 2>/dev/null || true)"
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
Install a C++ compiler, CMake, make, pkg-config, curl or wget, Python 3,
cabextract, msitools, the exact running-kernel headers, plus development packages
for libusb-1.0, ALSA, OpenCV and libjpeg. Then run the launcher again.
MSG
  return 2
}

if ! build_dependencies_ready; then
  install_build_dependencies
fi

build_dependencies_ready || {
  echo 'Linux build dependencies are still incomplete after dependency setup.' >&2
  print_missing_build_dependencies
  echo 'Only compilation-time requirements are checked here. systemd/udev, account-management and kmod runtime tools are validated by the installation stage when they are actually needed.' >&2
  exit 2
}

KERNEL_RELEASE="${REMOLD_KERNEL_RELEASE:-$(uname -r)}"
KERNEL_BUILD_DIR="$(remold_kernel_build_dir "$KERNEL_RELEASE")" || {
  echo "Kernel headers were reported ready but the build directory could not be resolved for $KERNEL_RELEASE." >&2
  exit 2
}
export REMOLD_KERNEL_RELEASE="$KERNEL_RELEASE"
export REMOLD_KERNEL_BUILD="$KERNEL_BUILD_DIR"
printf 'Kernel build directory: %s\n' "$KERNEL_BUILD_DIR"

(( CLEAN )) && rm -rf "$BUILD_DIR" "$DIST_DIR" "$SDK_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$SDK_DIR"

cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$DIST_DIR" \
  -DCMAKE_INSTALL_BINDIR=bin \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DREMOLD_RUNTIME_DIR="$RUNTIME_DIR" \
  -DREMOLD_CONFIG_PATH="$CONFIG_PATH" \
  -DREMOLD_FIRMWARE_PATH="$FIRMWARE_PATH" \
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
install -m 0755 "$ENV_HELPER" "$DIST_DIR/remold-env.sh"
install -m 0644 "$BUILD_CONFIG" "$DIST_DIR/build.env"
install -m 0644 "$LINUX_CONFIG" "$DIST_DIR/linux.env"

# Prepare the Kinect UAC firmware required by the audio runtime and 1473 control path.
bash "$SOURCE_ROOT/scripts/prepare-uac-firmware.sh" \
  "$DIST_DIR/support/firmware/UACFirmware-${REMOLD_KINECT_UAC_FIRMWARE_VERSION}"

# Build and bundle the exact v4l2loopback module needed by the running kernel.
# Network/package-manager activity is intentionally confined to this BUILD stage;
# INSTALL.sh consumes this module without downloading anything.
bash "$SOURCE_ROOT/scripts/prepare-v4l2loopback.sh" \
  "$DIST_DIR/support/kernel"

install -m 0755 "$PROJECT_ROOT/drivers/modules/kinect-xbox-360-remold/linux/INSTALL.sh" "$DIST_DIR/INSTALL.sh"
install -m 0755 "$PROJECT_ROOT/drivers/modules/kinect-xbox-360-remold/linux/UNINSTALL.sh" "$DIST_DIR/UNINSTALL.sh"
install -m 0755 "$PROJECT_ROOT/drivers/modules/kinect-xbox-360-remold/linux/KINECT.sh" "$DIST_DIR/KINECT.sh"
install -m 0644 "$PROJECT_ROOT/VERSION" "$DIST_DIR/VERSION"
sed "s|@REMOLD_CONTROL_SOCKET@|$RUNTIME_DIR/control.sock|g" \
  "$SOURCE_ROOT/sdk/Kinect360RemoldControlProtocol.hpp" > "$SDK_DIR/Kinect360RemoldControlProtocol.hpp"
chmod 0644 "$SDK_DIR/Kinect360RemoldControlProtocol.hpp"
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
  "$DIST_DIR/remold-env.sh"
  "$DIST_DIR/build.env"
  "$DIST_DIR/linux.env"
  "$DIST_DIR/support/udev/60-kinect360-remold.rules"
  "$DIST_DIR/support/modprobe/kinect360-remold-v4l2.conf"
  "$DIST_DIR/support/modprobe/kinect360-remold-camera.conf"
  "$DIST_DIR/support/modprobe/kinect360-remold-audio.conf"
  "$DIST_DIR/support/modules-load/kinect360-remold.conf"
  "$DIST_DIR/support/config/remold.conf"
  "$DIST_DIR/support/systemd/kinect360-remold.target"
  "$DIST_DIR/support/systemd/kinect360-remold-broker.service"
  "$DIST_DIR/support/systemd/kinect360-remold-camera.service"
  "$DIST_DIR/support/systemd/kinect360-remold-audio.service"
  "$DIST_DIR/support/systemd/kinect360-remold-v4l2.service"
  "$DIST_DIR/support/systemd/kinect360-remold-camera-ip.service"
  "$DIST_DIR/support/firmware/UACFirmware-${REMOLD_KINECT_UAC_FIRMWARE_VERSION}"
  "$DIST_DIR/support/kernel/KERNEL-RELEASE"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-VERSION"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-SOURCE-SHA256"
  "$DIST_DIR/support/kernel/V4L2LOOPBACK-MODULE-SHA256"
  "$DIST_DIR/support/kernel/$(uname -r)/v4l2loopback.ko"
)
for artifact in "${required_runtime[@]}"; do
  [[ -e "$artifact" ]] || { echo "Linux runtime build did not publish required artifact: $artifact" >&2; exit 3; }
done

cat > "$SDK_DIR/README.md" <<DOC
# Kinect Remold - Xbox 360 SDK endpoint

Linux SDK socket: \`$RUNTIME_DIR/sdk.sock\`, hosted by \`kinect360-remold-broker\`.

Text commands: \`LIST\`, \`GET <deviceId>\`, \`INDEX <sensorIndex>\`. Returned rows use:
\`id, label, state, control, camera, audio, audio-control, virtual-camera, sdk, module-id, generation, capabilities, color-width, color-height, depth-width, depth-height, ir-width, ir-height, color-fps, depth-fps\`.

Device control: \`CONTROL<TAB><deviceId><TAB><action>\` answers one line, \`OK <detail>\` or \`ERR <reason>\`.
Actions: \`Status\` (\`OK <state>\`), \`OpenCamera\` (\`OK Ready\` or \`ERR NOT_READY\`), \`LedOff\`, \`LedGreen\`, \`LedRed\`, \`LedBlink\`.
Unknown actions return \`ERR UNSUPPORTED_ACTION\`; unknown devices return \`ERR NOT_FOUND\`.

SynKinect Studio and external clients discover devices through this endpoint. The runtime manifest is internal and is not part of the SDK surface.

\`Kinect360RemoldControlProtocol.hpp\` and \`Kinect360RemoldAudioControlProtocol.hpp\` define the public binary control protocols.
DOC

printf 'Linux driver: %s\nLinux SDK: %s\n' "$DIST_DIR" "$SDK_DIR"
