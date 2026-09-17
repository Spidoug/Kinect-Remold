#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
PROJECT_ROOT="$(cd "$SOURCE_ROOT/../../.." && pwd)"
ARCH="$(uname -m)"

resolve_caller_home(){
  local user="${SUDO_USER:-}" home=""
  if [[ -n "$user" && "$user" != root ]] && command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$user" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  if [[ -n "$home" ]]; then printf '%s' "$home"; else printf '%s' "${HOME:-/root}"; fi
}

resolve_dist_dir(){
  if [[ -n "${REMOLD_DIST_DIR:-}" ]]; then printf '%s' "$REMOLD_DIST_DIR"; return 0; fi
  local caller_home state_file saved cache_base cached
  caller_home="$(resolve_caller_home)"
  state_file="$caller_home/.local/state/kinect360-remold/linux-driver-dist-$ARCH.path"
  if [[ -r "$state_file" ]]; then
    IFS= read -r saved < "$state_file" || true
    if [[ -n "$saved" && -f "$saved/bin/kinect360-remoldctl" ]]; then printf '%s' "$saved"; return 0; fi
  fi
  cache_base="${XDG_CACHE_HOME:-$caller_home/.cache}"
  cached="$cache_base/kinect360-remold/linux-driver/dist/$ARCH"
  if [[ -f "$cached/bin/kinect360-remoldctl" ]]; then printf '%s' "$cached"; return 0; fi
  printf '%s' "$cached"
}

DIST_DIR="$(resolve_dist_dir)"
NO_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --no-deps) NO_DEPS=1 ;;
    --dist-dir=*) DIST_DIR="${arg#*=}" ;;
    *) echo "Unknown option: $arg" >&2; echo "Usage: sudo bash $0 [--no-deps] [--dist-dir=PATH]" >&2; exit 2 ;;
  esac
done

require_distribution(){
  local expected=(
    "$DIST_DIR/bin/kinect360-remoldctl"
    "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-nui"
    "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-broker"
    "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera"
    "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-audio"
    "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-v4l2"
    "$DIST_DIR/libexec/kinect360-remold/ensure-v4l2-device.sh"
  )
  for file in "${expected[@]}"; do
    [[ -f "$file" ]] || {
      echo "Missing compiled artifact: $file" >&2
      echo "Run drivers/linux/BUILD.sh first. INSTALL consumes the generated runtime distribution and does not compile or download build dependencies." >&2
      exit 3
    }
    chmod 0755 "$file" 2>/dev/null || true
    [[ -x "$file" ]] || {
      echo "Compiled artifact is not executable: $file" >&2
      exit 3
    }
  done
  local optional="$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera-ip"
  if [[ -f "$optional" ]]; then chmod 0755 "$optional" 2>/dev/null || true; fi
}

install_runtime_deps(){
  (( NO_DEPS )) && return 0
  echo '[runtime] Installing Linux runtime dependencies only...'
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    local alsa_pkg=libasound2 jpeg_pkg=libjpeg62-turbo candidate
    for candidate in libasound2t64 libasound2; do if apt-cache show "$candidate" >/dev/null 2>&1; then alsa_pkg="$candidate"; break; fi; done
    for candidate in libjpeg62-turbo libjpeg-turbo8 libjpeg8; do if apt-cache show "$candidate" >/dev/null 2>&1; then jpeg_pkg="$candidate"; break; fi; done
    local -a video_pkgs=(v4l2loopback-dkms v4l-utils)
    if apt-cache show v4l2loopback-utils >/dev/null 2>&1; then video_pkgs+=(v4l2loopback-utils); fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y libusb-1.0-0 "$alsa_pkg" "$jpeg_pkg" "${video_pkgs[@]}" kmod ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y libusb1 alsa-lib libjpeg-turbo v4l2loopback v4l-utils kmod ca-certificates
    if dnf -q list --available v4l2loopback-utils >/dev/null 2>&1; then dnf install -y v4l2loopback-utils; fi
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm libusb alsa-lib libjpeg-turbo v4l2loopback-dkms v4l-utils kmod ca-certificates
    if pacman -Si v4l2loopback-utils >/dev/null 2>&1; then pacman -S --needed --noconfirm v4l2loopback-utils; fi
  else
    echo 'Unsupported package manager. Install libusb-1.0, ALSA, libjpeg, v4l2loopback >= 0.15.0, kmod and CA certificates; then use --no-deps.' >&2
    exit 2
  fi
}

require_v4l2loopback(){
  local required="0.15.0" version="" first="" kernel_version=""
  kernel_version="$(uname -r | sed 's/[-+].*$//')"
  # Upstream 0.15.3 contains the Linux 6.18+ safety behavior; older supported
  # kernels can use 0.15.0+, which is sufficient because the runtime does not depend
  # on private client-usage events.
  if [[ "$(printf '%s\n%s\n' '6.18.0' "$kernel_version" | sort -V | head -n1)" == '6.18.0' ]]; then required="0.15.3"; fi
  command -v modinfo >/dev/null 2>&1 || { echo "kmod/modinfo is required." >&2; exit 2; }
  version="$(modinfo -F version v4l2loopback 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ -n "$version" ]] || { echo "v4l2loopback is not installed. Requires v4l2loopback >= $required." >&2; exit 2; }
  first="$(printf '%s\n%s\n' "$required" "$version" | sort -V | head -n1)"
  [[ "$first" == "$required" ]] || { echo "v4l2loopback $version is too old. Requires >= $required." >&2; exit 2; }
}

usb_attr(){
  local p="$1" f="$2"
  if [[ -r "$p/$f" ]]; then tr '[:upper:]' '[:lower:]' < "$p/$f" | tr -d '[:space:]'; else printf ''; fi
}
detect_kinect_models(){
  local found1414=0 found1473=0 camera_bcd="" vid="" pid=""
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    vid="$(usb_attr "$dev" idVendor)"; [[ "$vid" == "045e" ]] || continue
    pid="$(usb_attr "$dev" idProduct)"
    case "$pid" in
      02b0) found1414=1 ;;
      02c2|02bb|02c3) found1473=1 ;;
      02ae)
        camera_bcd="$(usb_attr "$dev" bcdDevice)"
        if [[ "$camera_bcd" == "010b" ]]; then found1414=1; elif [[ -n "$camera_bcd" ]]; then found1473=1; fi
        ;;
    esac
  done
  if (( found1414 && found1473 )); then echo mixed
  elif (( found1414 )); then echo 1414
  elif (( found1473 )); then echo 1473
  else echo none
  fi
}

write_model_policy(){
  local model="$1"
  mkdir -p /etc/kinect360-remold
  cat > /etc/kinect360-remold/model.conf <<EOF
# Generated by Kinect Xbox 360 Remold V1 installer.
model=$model
camera=045e:02ae
camera.rgb_ir.endpoint=0x81
camera.depth.endpoint=0x82
audio.boot=045e:02ad
audio.runtime=045e:02bb,045e:02c3
audio.capture.endpoint=0x82
audio.stream=/run/kinect360-remold/audio.sock
audio.control=/run/kinect360-remold/audio-control.sock
audio.capture.policy=dsnoop-shared-plughw-hw-fallback
nui.discovery=/run/kinect360-remold/nui.sock
nui.sdk=/run/kinect360-remold/sdk.sock
nui.skeleton=/run/kinect360-remold/nui-skeleton.sock
EOF
  case "$model" in
    1414)
      cat >> /etc/kinect360-remold/model.conf <<'EOF'
control.identity=045e:02b0
control.policy=direct-user-space
EOF
      ;;
    1473)
      cat >> /etc/kinect360-remold/model.conf <<'EOF'
parent.identity=045e:02c2
parent.policy=keep-inbox-hub
control.identity=045e:02bb/MI_00,045e:02c3/MI_00
control.policy=claim-control-interface-only
capture.identity=045e:02bb/MI_02,045e:02c3/MI_02
capture.policy=snd-usb-audio
EOF
      ;;
    mixed)
      cat >> /etc/kinect360-remold/model.conf <<'EOF'
control.policy=1414-direct-and-1473-interface-scoped
parent.policy=1473-02c2-keep-inbox-hub
capture.policy=1473-MI_02-snd-usb-audio
EOF
      ;;
    none)
      echo 'control.policy=auto-detect-at-runtime' >> /etc/kinect360-remold/model.conf
      ;;
  esac
  chmod 0644 /etc/kinect360-remold/model.conf
}

require_distribution
install_runtime_deps
require_v4l2loopback
for binary in "$DIST_DIR"/bin/kinect360-remoldctl "$DIST_DIR"/libexec/kinect360-remold/kinect360-remold-*; do
  [[ -x "$binary" ]] || continue
  if command -v ldd >/dev/null 2>&1 && ldd "$binary" 2>/dev/null | grep -q 'not found'; then
    echo "Unresolved runtime library dependency in $binary:" >&2
    ldd "$binary" 2>/dev/null | grep 'not found' >&2 || true
    exit 2
  fi
done
MODEL="$(detect_kinect_models)"
echo "[model] Detected Kinect installation profile: $MODEL"
case "$MODEL" in
  1414) echo '[model] 1414: 02B0 control/motor is owned directly by the Remold broker.' ;;
  1473) echo '[model] 1473: 02C2 stays on the Linux hub stack; only runtime control is claimed, MI_02 remains USB Audio.' ;;
  mixed) echo '[model] Both 1414 and 1473 are present; enabling both ownership policies.' ;;
  none) echo '[model] No Kinect is connected; installing both supported policies for runtime auto-detection.' ;;
esac

# Install the runtime component set from the compiled distribution.
systemctl stop kinect360-remold.target >/dev/null 2>&1 || true
rm -rf /usr/libexec/kinect360-remold
rm -f /etc/systemd/system/kinect360-remold-*.service /etc/systemd/system/kinect360-remold.target

install -D -m 0755 "$DIST_DIR/bin/kinect360-remoldctl" /usr/bin/kinect360-remoldctl
for binary in kinect360-remold-nui kinect360-remold-broker kinect360-remold-camera kinect360-remold-audio kinect360-remold-v4l2; do
  install -D -m 0755 "$DIST_DIR/libexec/kinect360-remold/$binary" "/usr/libexec/kinect360-remold/$binary"
done
if [[ -x "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera-ip" ]]; then
  install -D -m 0755 "$DIST_DIR/libexec/kinect360-remold/kinect360-remold-camera-ip" /usr/libexec/kinect360-remold/kinect360-remold-camera-ip
fi

install -D -m 0755 "$DIST_DIR/libexec/kinect360-remold/ensure-v4l2-device.sh" /usr/libexec/kinect360-remold/ensure-v4l2-device.sh

install -D -m 0644 "$SOURCE_ROOT/udev/60-kinect360-remold.rules" /etc/udev/rules.d/60-kinect360-remold.rules
# Virtual-camera creation is service-owned so an occupied /dev/videoN cannot break startup.
rm -f /etc/modprobe.d/kinect360-remold-v4l2.conf /etc/modules-load.d/kinect360-remold.conf
mkdir -p /etc/kinect360-remold
write_model_policy "$MODEL"
if [[ ! -f /etc/kinect360-remold/remold.conf ]]; then
  PASS="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  sed -e 's/^ip.enabled=false/ip.enabled=true/' -e "s/^ip.password=.*/ip.password=$PASS/" "$SOURCE_ROOT/config/remold.conf" > /etc/kinect360-remold/remold.conf
  chmod 0640 /etc/kinect360-remold/remold.conf
  echo "IP camera credentials: admin / $PASS"
fi
for f in "$SOURCE_ROOT"/systemd/*; do install -D -m 0644 "$f" "/etc/systemd/system/$(basename "$f")"; done
systemctl daemon-reload
systemctl disable kinect360-remold.target >/dev/null 2>&1 || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb || true
modprobe snd-usb-audio || true
if ! bash /usr/libexec/kinect360-remold/ensure-v4l2-device.sh; then
  echo 'The Kinect virtual camera could not be created. Check DKMS status and Secure Boot module signing.' >&2
  exit 2
fi
if [[ "$MODEL" != none ]]; then systemctl start kinect360-remold.target; fi
USER_TO_ADD="${REMOLD_CALLER_USER:-${SUDO_USER:-}}"
if [[ -n "$USER_TO_ADD" && "$USER_TO_ADD" != root ]]; then usermod -aG video,audio "$USER_TO_ADD" || true; fi

echo "Kinect Xbox 360 Remold installed from compiled distribution: $DIST_DIR"
echo "Model policy: $MODEL (/etc/kinect360-remold/model.conf)"
echo 'Reconnect the Kinect if needed, then run: kinect360-remoldctl status'
