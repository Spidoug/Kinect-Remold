#!/usr/bin/env bash
set -euo pipefail
print_banner(){
  [[ "${REMOLD_GUI:-0}" == 1 ]] && return 0
  printf '%s\n' '============================================================'
  printf '%s\n' ' Kinect Remold'
  printf '%s\n' ' by Douglas Santana - @spidoug'
  printf '%s\n' '============================================================'
  printf '%s\n' ' Control panel - Linux'
  printf '\n'
}
stage(){
  printf '%s\n' "$1"
}
summary_item(){
  printf '%-24s : %s\n' "$1" "$2"
}
print_banner
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$HERE/libexec/kinect360-remold" || -x "$HERE/bin/kinect360-remoldctl" ]]; then
  BUNDLE="$HERE"
else
  PROJECT="$HERE"
  for _ in {1..12}; do
    if [[ -f "$PROJECT/VERSION" && -d "$PROJECT/drivers" && -d "$PROJECT/applications" ]]; then break; fi
    parent="$(dirname "$PROJECT")"; [[ "$parent" != "$PROJECT" ]] || break; PROJECT="$parent"
  done
  BUNDLE="$PROJECT/binaries/linux/drivers/kinect-xbox-360-remold"
fi
[[ -x "$BUNDLE/bin/kinect360-remoldctl" && -d "$BUNDLE/libexec/kinect360-remold" ]] || { echo 'Built Linux driver runtime not found. Run ./Kinect-Remold.sh --build-only first.' >&2; exit 2; }
# Installation consumes the prepared runtime bundle and performs no build or network work.
[[ $# -eq 0 ]] || { echo 'INSTALL.sh does not accept options. Build first, then install the prepared bundle.' >&2; exit 2; }
ENV_HELPER="${REMOLD_ENV_HELPER:-$BUNDLE/remold-env.sh}"
BUILD_CONFIG="$BUNDLE/build.env"
LINUX_CONFIG="$BUNDLE/linux.env"
for config_file in "$ENV_HELPER" "$BUILD_CONFIG" "$LINUX_CONFIG"; do [[ -r "$config_file" ]] || { echo "Missing runtime configuration: $config_file" >&2; exit 2; }; done
source "$ENV_HELPER"
for config_file in "$BUILD_CONFIG" "$LINUX_CONFIG"; do
  while IFS='=' read -r key value; do [[ "$key" =~ ^REMOLD_[A-Z0-9_]+$ ]] || continue; [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$value"; done < "$config_file"
done
remold_install_paths || { echo 'Could not resolve Linux installation directories.' >&2; exit 2; }
MODULE_ID='kinect360-remold'
LIBEXEC_DIR="$REMOLD_LIBEXECDIR/$MODULE_ID"
DATA_DIR="$REMOLD_DATADIR/$MODULE_ID"
MAINT_DIR="$DATA_DIR/maintenance"
STATE_DIR="$REMOLD_LOCALSTATEDIR/$MODULE_ID"
RUN_DIR="$REMOLD_RUNDIR/$MODULE_ID"
CONFIG_DIR="$REMOLD_SYSCONFDIR/$MODULE_ID"
CONTROL_PATH="$REMOLD_BINDIR/kinect360-remoldctl"
MODPROBE_DIR="$REMOLD_SYSCONFDIR/modprobe.d"
MODULES_LOAD_DIR="$REMOLD_SYSCONFDIR/modules-load.d"
KERNEL_MODULES_ROOT="$(remold_kernel_modules_root "$(uname -r)")" || { echo 'Could not resolve the kernel module root; set REMOLD_KERNEL_MODULES_ROOT.' >&2; exit 2; }
IP_SERVICE_USER="$REMOLD_K360_IP_SERVICE_USER"
VIDEO_GROUP="$REMOLD_VIDEO_GROUP"
AUDIO_GROUP="$REMOLD_AUDIO_GROUP"

for command_name in \
  awk basename cat chmod chown cmp cut depmod dirname getent groupadd head id install ldd \
  mkdir mktemp modinfo modprobe od readlink rm rmdir sed seq sha256sum sleep systemctl \
  tail tr udevadm uname useradd xargs; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Offline installation prerequisite is missing: $command_name" >&2
    echo 'Run the full Linux build on this machine first so build-time dependencies are installed.' >&2
    exit 2
  }
done

SUPPORT="$BUNDLE/support"
KERNEL_RELEASE="$(uname -r)"
BUNDLED_KERNEL_RELEASE="$(cat "$SUPPORT/kernel/KERNEL-RELEASE" 2>/dev/null || true)"
BUNDLED_V4L2="$SUPPORT/kernel/$KERNEL_RELEASE/v4l2loopback.ko"
[[ "$BUNDLED_KERNEL_RELEASE" == "$KERNEL_RELEASE" && -s "$BUNDLED_V4L2" ]] || {
  echo "The offline driver bundle does not contain v4l2loopback for running kernel $KERNEL_RELEASE." >&2
  echo 'Run the complete Linux build under the current kernel, then install again.' >&2
  exit 2
}
EXPECTED_V4L2_VERSION="$REMOLD_V4L2LOOPBACK_VERSION"
EXPECTED_V4L2_SOURCE_SHA="$REMOLD_V4L2LOOPBACK_SOURCE_SHA256"
bundled_v4l2_version="$(modinfo -F version "$BUNDLED_V4L2" 2>/dev/null | head -1 | tr -d '[:space:]')"
[[ "$bundled_v4l2_version" == "$EXPECTED_V4L2_VERSION" ]] || {
  echo "Unexpected bundled v4l2loopback version: ${bundled_v4l2_version:-unknown}" >&2
  exit 2
}

REQUIRED_BUNDLE_FILES=(
  "$BUNDLE/bin/kinect360-remoldctl"
  "$BUNDLE/VERSION"
  "$BUNDLE/libexec/kinect360-remold/kinect360-remold-broker"
  "$BUNDLE/libexec/kinect360-remold/kinect360-remold-camera"
  "$BUNDLE/libexec/kinect360-remold/kinect360-remold-audio"
  "$BUNDLE/libexec/kinect360-remold/kinect360-remold-v4l2"
  "$BUNDLE/libexec/kinect360-remold/kinect360-remold-camera-ip"
  "$SUPPORT/udev/60-kinect360-remold.rules"
  "$SUPPORT/modprobe/kinect360-remold-v4l2.conf"
  "$SUPPORT/modprobe/kinect360-remold-camera.conf"
  "$SUPPORT/modprobe/kinect360-remold-audio.conf"
  "$SUPPORT/modules-load/kinect360-remold.conf"
  "$SUPPORT/config/remold.conf"
  "$SUPPORT/firmware/UACFirmware-${REMOLD_KINECT_UAC_FIRMWARE_VERSION}"
  "$SUPPORT/kernel/KERNEL-RELEASE"
  "$SUPPORT/kernel/V4L2LOOPBACK-VERSION"
  "$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256"
  "$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256"
  "$BUNDLED_V4L2"
  "$SUPPORT/systemd/kinect360-remold.target"
  "$SUPPORT/systemd/kinect360-remold-broker.service"
  "$SUPPORT/systemd/kinect360-remold-camera.service"
  "$SUPPORT/systemd/kinect360-remold-audio.service"
  "$SUPPORT/systemd/kinect360-remold-v4l2.service"
  "$SUPPORT/systemd/kinect360-remold-camera-ip.service"
)
for required_file in "${REQUIRED_BUNDLE_FILES[@]}"; do
  [[ -f "$required_file" ]] || { echo "Built Linux runtime is incomplete: $required_file" >&2; exit 2; }
done

declared_v4l2_version="$(tr -d '[:space:]' <"$SUPPORT/kernel/V4L2LOOPBACK-VERSION")"
declared_v4l2_source_sha="$(tr -d '[:space:]' <"$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256" | tr '[:upper:]' '[:lower:]')"
declared_v4l2_module_sha="$(tr -d '[:space:]' <"$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256" | tr '[:upper:]' '[:lower:]')"
actual_v4l2_module_sha="$(sha256sum "$BUNDLED_V4L2" | awk '{print tolower($1)}')"
[[ "$declared_v4l2_version" == "$EXPECTED_V4L2_VERSION" && "$declared_v4l2_version" == "$bundled_v4l2_version" ]] || {
  echo 'Bundled v4l2loopback version metadata does not match the compiled module.' >&2
  exit 2
}
[[ "$declared_v4l2_source_sha" == "$EXPECTED_V4L2_SOURCE_SHA" ]] || {
  echo 'Bundled v4l2loopback source integrity metadata is unexpected.' >&2
  exit 2
}
[[ "$declared_v4l2_module_sha" == "$actual_v4l2_module_sha" ]] || {
  echo 'Bundled v4l2loopback module integrity verification failed.' >&2
  exit 2
}

# Check every bundled executable before touching the installed runtime. This
# remains an offline check: any runtime library required by the build must
# already be present because the BUILD stage installed it.
for executable in "$BUNDLE/bin/kinect360-remoldctl" "$BUNDLE"/libexec/kinect360-remold/*; do
  missing_libraries="$(ldd "$executable" 2>/dev/null | awk '/=> not found/{print $1}' | xargs || true)"
  [[ -z "$missing_libraries" ]] || {
    echo "Offline installation cannot continue; $executable is missing runtime libraries: $missing_libraries" >&2
    echo 'Run the complete Linux build on this machine before installing.' >&2
    exit 2
  }
done

FIRMWARE_SOURCE="$SUPPORT/firmware/UACFirmware-${REMOLD_KINECT_UAC_FIRMWARE_VERSION}"
[[ -f "$FIRMWARE_SOURCE" ]] || {
  echo "Microsoft Kinect UACFirmware $REMOLD_KINECT_UAC_FIRMWARE_VERSION is missing from the built Linux runtime." >&2
  echo 'Rebuild the complete project so the verified firmware is prepared automatically.' >&2
  exit 2
}
EXPECTED_FIRMWARE_SHA="$REMOLD_KINECT_UAC_FIRMWARE_SHA256"
ACTUAL_FIRMWARE_SHA="$(sha256sum "$FIRMWARE_SOURCE" | awk '{print tolower($1)}')"
[[ "$ACTUAL_FIRMWARE_SHA" == "$EXPECTED_FIRMWARE_SHA" ]] || {
  echo "Unexpected Kinect UACFirmware integrity: $ACTUAL_FIRMWARE_SHA" >&2
  exit 2
}

RUNTIME_UNITS=(
  kinect360-remold-broker.service
  kinect360-remold-camera.service
  kinect360-remold-audio.service
  kinect360-remold-v4l2.service
  kinect360-remold-camera-ip.service
)

stop_installed_runtime(){
  # Stop the active runtime before replacing installed binaries and units.
  systemctl disable --now kinect360-remold-camera-ip.service 2>/dev/null || true
  systemctl disable --now kinect360-remold.target 2>/dev/null || true
  local unit
  for unit in "${RUNTIME_UNITS[@]}"; do
    systemctl stop "$unit" 2>/dev/null || true
  done
  systemctl stop kinect360-remold.target 2>/dev/null || true
  for unit in "${RUNTIME_UNITS[@]}"; do
    systemctl kill --kill-who=all --signal=TERM "$unit" 2>/dev/null || true
  done
  sleep 0.15
  for unit in "${RUNTIME_UNITS[@]}"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      systemctl kill --kill-who=all --signal=KILL "$unit" 2>/dev/null || true
    fi
  done
  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -f "^$LIBEXEC_DIR/" 2>/dev/null || true
    sleep 0.05
    pkill -KILL -f "^$LIBEXEC_DIR/" 2>/dev/null || true
  fi
}

remove_owned_v4l2loopback(){
  local marker="$DATA_DIR/v4l2loopback-owned-path" old_module old_kernel
  old_module="$(cat "$marker" 2>/dev/null || true)"
  modprobe -r v4l2loopback 2>/dev/null || true
  if [[ -n "$old_module" && "$old_module" == "$KERNEL_MODULES_ROOT"/*/updates/kinect360-remold/v4l2loopback.ko && -f "$old_module" ]]; then
    old_kernel="${old_module#${KERNEL_MODULES_ROOT}/}"
    old_kernel="${old_kernel%%/*}"
    rm -f "$old_module"
    rmdir "$(dirname "$old_module")" 2>/dev/null || true
    depmod -a "$old_kernel" 2>/dev/null || true
  fi
}

clean_installed_runtime(){
  stop_installed_runtime
  remove_owned_v4l2loopback
  rm -rf -- "$RUN_DIR"
  rm -f -- "$CONTROL_PATH"
  rm -rf -- "$LIBEXEC_DIR" "$DATA_DIR"
  rm -f -- "$REMOLD_SYSTEMD_UNIT_DIR"/kinect360-remold*.service "$REMOLD_SYSTEMD_UNIT_DIR/kinect360-remold.target"
  rm -rf -- "$REMOLD_SYSTEMD_UNIT_DIR"/kinect360-remold*.service.d "$REMOLD_SYSTEMD_UNIT_DIR/kinect360-remold.target.d"
  rm -f -- "$REMOLD_UDEV_RULES_DIR/60-kinect360-remold.rules"
  rm -f -- "$MODPROBE_DIR/kinect360-remold-v4l2.conf" "$MODPROBE_DIR/kinect360-remold-camera.conf" "$MODPROBE_DIR/kinect360-remold-audio.conf" "$MODULES_LOAD_DIR/kinect360-remold.conf"
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

stage "[1/5] Removing previous installed runtime and preparing the new bundle..."
clean_installed_runtime

stage "[2/5] Installing Kinect Remold Xbox 360 runtime files..."
install -D -m 0755 "$BUNDLE/bin/kinect360-remoldctl" "$CONTROL_PATH"
install -D -m 0755 "$ENV_HELPER" "$REMOLD_BINDIR/kinect-remold-env.sh"
install -D -m 0644 "$BUNDLE/VERSION" "$DATA_DIR/VERSION"
install -D -m 0644 "$SUPPORT/kernel/KERNEL-RELEASE" "$DATA_DIR/KERNEL-RELEASE"
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-VERSION" "$DATA_DIR/V4L2LOOPBACK-VERSION"
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256" "$DATA_DIR/V4L2LOOPBACK-SOURCE-SHA256"
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256" "$DATA_DIR/V4L2LOOPBACK-MODULE-SHA256"
for f in "$BUNDLE"/libexec/kinect360-remold/*;do install -D -m 0755 "$f" "$LIBEXEC_DIR/$(basename "$f")";done
UDEV_RENDERED="$(mktemp)"
sed -e "s|@REMOLD_VIDEO_GROUP@|$VIDEO_GROUP|g" -e "s|@REMOLD_AUDIO_GROUP@|$AUDIO_GROUP|g" "$SUPPORT/udev/60-kinect360-remold.rules" > "$UDEV_RENDERED"
install -D -m 0644 "$UDEV_RENDERED" "$REMOLD_UDEV_RULES_DIR/60-kinect360-remold.rules"
rm -f "$UDEV_RENDERED"
install -D -m 0644 "$SUPPORT/modprobe/kinect360-remold-v4l2.conf" "$MODPROBE_DIR/kinect360-remold-v4l2.conf"
install -D -m 0644 "$SUPPORT/modprobe/kinect360-remold-camera.conf" "$MODPROBE_DIR/kinect360-remold-camera.conf"
install -D -m 0644 "$SUPPORT/modprobe/kinect360-remold-audio.conf" "$MODPROBE_DIR/kinect360-remold-audio.conf"
install -D -m 0644 "$SUPPORT/modules-load/kinect360-remold.conf" "$MODULES_LOAD_DIR/kinect360-remold.conf"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$DATA_DIR" "$MAINT_DIR"
INSTALLED_V4L2="$KERNEL_MODULES_ROOT/$KERNEL_RELEASE/updates/kinect360-remold/v4l2loopback.ko"
install -D -m 0644 "$BUNDLED_V4L2" "$INSTALLED_V4L2"
printf '%s\n' "$INSTALLED_V4L2" >"$DATA_DIR/v4l2loopback-owned-path"
depmod -a "$KERNEL_RELEASE"
[[ "$(modinfo -F version "$INSTALLED_V4L2" 2>/dev/null | head -1 | tr -d '[:space:]')" == "$bundled_v4l2_version" ]] || {
  echo 'Installed v4l2loopback module failed verification.' >&2
  exit 3
}
for REQUIRED_GROUP in "$VIDEO_GROUP" "$AUDIO_GROUP"; do
  if ! getent group "$REQUIRED_GROUP" >/dev/null 2>&1; then groupadd --system "$REQUIRED_GROUP"; fi
done
# IP service account comes from Linux integration metadata.
if ! getent group "$IP_SERVICE_USER" >/dev/null 2>&1; then groupadd --system "$IP_SERVICE_USER"; fi
if ! id -u "$IP_SERVICE_USER" >/dev/null 2>&1; then
  NOLOGIN="$(command -v nologin || command -v false || true)"; [[ -n "$NOLOGIN" ]] || { echo "No non-login shell was found." >&2; exit 2; }
  useradd --system --gid "$IP_SERVICE_USER" --no-create-home --home-dir "$STATE_DIR/ip-service" --shell "$NOLOGIN" "$IP_SERVICE_USER"
fi
chown root:"$IP_SERVICE_USER" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"
CFG="$CONFIG_DIR/remold.conf"
set_config_value(){
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN{done=0}
    index($0,key"=")==1 {print key"="value;done=1;next}
    {print}
    END{if(!done)print key"="value}
  ' "$CFG" >"$tmp"
  install -o root -g "$IP_SERVICE_USER" -m 0640 "$tmp" "$CFG"
  rm -f "$tmp"
}
has_config_key(){
  awk -v key="$1" 'index($0,key"=")==1{found=1} END{exit !found}' "$CFG"
}
if [[ ! -f "$CFG" ]]; then
  PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
  TMP_CFG="$(mktemp)"
  trap 'rm -f "$TMP_CFG"' EXIT
  sed -e "s/^ip.password=.*/ip.password=$PASS/" "$SUPPORT/config/remold.conf" >"$TMP_CFG"
  install -o root -g "$IP_SERVICE_USER" -m 0640 "$TMP_CFG" "$CFG"
  rm -f "$TMP_CFG"
  trap - EXIT
  echo 'IP camera installed disabled and loopback-only. Use KINECT.sh to enable it and view credentials with administrator permission.'
else
  chmod 0640 "$CFG"
  chown root:"$IP_SERVICE_USER" "$CFG"
  PASSWORD="$(awk -F= '$1=="ip.password"{sub(/^[^=]*=/,"");print;exit}' "$CFG")"
  if (( ${#PASSWORD} < 24 )); then
    PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
    set_config_value ip.password "$PASS"
    echo 'IP camera credential did not meet the minimum length and was rotated.'
  fi
  # Keep user values and add every shipped policy key the file does not define.
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    [[ "$key" == ip.password ]] && continue
    has_config_key "$key" || set_config_value "$key" "${line#*=}"
  done <"$SUPPORT/config/remold.conf"
fi

stage "[3/5] Installing system services, policy and firmware runtime assets..."
VIDEO_GROUP_LINE=""
[[ -n "$VIDEO_GROUP" ]] && VIDEO_GROUP_LINE="SupplementaryGroups=$VIDEO_GROUP"
for f in "$SUPPORT"/systemd/*; do
  target="$REMOLD_SYSTEMD_UNIT_DIR/$(basename "$f")"
  rendered="$(mktemp)"
  sed -e "s|@REMOLD_LIBEXEC_DIR@|$LIBEXEC_DIR|g" \
      -e "s|@REMOLD_STATE_DIR@|$STATE_DIR|g" \
      -e "s|@REMOLD_IP_USER@|$IP_SERVICE_USER|g" \
      -e "s|@REMOLD_IP_GROUP@|$IP_SERVICE_USER|g" \
      -e "s|@REMOLD_VIDEO_GROUP_LINE@|$VIDEO_GROUP_LINE|g" "$f" > "$rendered"
  install -D -m 0644 "$rendered" "$target"
  rm -f "$rendered"
done
install -m 0644 "$FIRMWARE_SOURCE" "$DATA_DIR/UACFirmware"
install -m 0755 "$ENV_HELPER" "$DATA_DIR/remold-env.sh"
install -m 0644 "$BUILD_CONFIG" "$DATA_DIR/build.env"
install -m 0644 "$LINUX_CONFIG" "$DATA_DIR/linux.env"
install -m 0755 "$BUNDLE/INSTALL.sh" "$MAINT_DIR/INSTALL.sh"
install -m 0755 "$BUNDLE/UNINSTALL.sh" "$MAINT_DIR/UNINSTALL.sh"
install -m 0755 "$BUNDLE/KINECT.sh" "$MAINT_DIR/KINECT.sh"
install -m 0755 "$ENV_HELPER" "$MAINT_DIR/remold-env.sh"
install -m 0644 "$BUILD_CONFIG" "$MAINT_DIR/build.env"
install -m 0644 "$LINUX_CONFIG" "$MAINT_DIR/linux.env"

verify_installed_file(){
  local source="$1" installed="$2"
  cmp -s "$source" "$installed" || {
    echo "Installed runtime verification failed: $installed does not match the current bundle." >&2
    exit 3
  }
}
verify_installed_file "$BUNDLE/bin/kinect360-remoldctl" "$CONTROL_PATH"
verify_installed_file "$BUNDLE/VERSION" "$DATA_DIR/VERSION"
verify_installed_file "$SUPPORT/kernel/KERNEL-RELEASE" "$DATA_DIR/KERNEL-RELEASE"
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-VERSION" "$DATA_DIR/V4L2LOOPBACK-VERSION"
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256" "$DATA_DIR/V4L2LOOPBACK-SOURCE-SHA256"
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256" "$DATA_DIR/V4L2LOOPBACK-MODULE-SHA256"
for source_file in "$BUNDLE"/libexec/kinect360-remold/*; do
  verify_installed_file "$source_file" "$LIBEXEC_DIR/$(basename "$source_file")"
done
[[ -s "$REMOLD_UDEV_RULES_DIR/60-kinect360-remold.rules" ]] || { echo "Installed udev policy is missing." >&2; exit 3; }
verify_installed_file "$SUPPORT/modprobe/kinect360-remold-v4l2.conf" "$MODPROBE_DIR/kinect360-remold-v4l2.conf"
verify_installed_file "$SUPPORT/modprobe/kinect360-remold-camera.conf" "$MODPROBE_DIR/kinect360-remold-camera.conf"
verify_installed_file "$SUPPORT/modprobe/kinect360-remold-audio.conf" "$MODPROBE_DIR/kinect360-remold-audio.conf"
verify_installed_file "$SUPPORT/modules-load/kinect360-remold.conf" "$MODULES_LOAD_DIR/kinect360-remold.conf"
for source_file in "$SUPPORT"/systemd/*; do [[ -s "$REMOLD_SYSTEMD_UNIT_DIR/$(basename "$source_file")" ]] || { echo "Installed systemd unit is missing: $(basename "$source_file")" >&2; exit 3; }; done
verify_installed_file "$FIRMWARE_SOURCE" "$DATA_DIR/UACFirmware"

verify_installed_file "$BUNDLED_V4L2" "$INSTALLED_V4L2"

stage "[4/5] Enabling and starting the installed runtime..."
systemctl daemon-reload
udevadm control --reload-rules
modprobe -r v4l2loopback 2>/dev/null || true
if ! modprobe v4l2loopback; then
  echo 'Could not load the bundled v4l2loopback module.' >&2
  echo 'Verify the running kernel/headers and kernel module-signing or Secure Boot policy, then rebuild under this kernel.' >&2
  exit 3
fi
if ! modprobe snd-aloop; then
  echo 'Could not load snd-aloop, which provides the Kinect Remold system microphone endpoint.' >&2
  echo 'Install the running kernel audio modules package and run Install / Repair again.' >&2
  exit 3
fi
modprobe -r gspca_kinect 2>/dev/null || true
udevadm trigger --subsystem-match=usb || true
# Re-evaluate already enumerated ALSA cards so Kinect-specific ACP/Pulse ignore
# policy is visible immediately when possible. Firmware re-enumeration will
# naturally receive the same policy for newly created sound devices.
udevadm trigger --subsystem-match=sound --action=change 2>/dev/null || true
IP_ENABLED="$(awk -F= '$1=="ip.enabled"{gsub(/[[:space:]]/,"",$2);print tolower($2);exit}' "$CFG")"
systemctl enable kinect360-remold.target
if [[ "$IP_ENABLED" == true || "$IP_ENABLED" == 1 ]]; then
  systemctl enable kinect360-remold-camera-ip.service
else
  systemctl disable --now kinect360-remold-camera-ip.service 2>/dev/null || true
fi
systemctl restart kinect360-remold.target
if [[ "$IP_ENABLED" == true || "$IP_ENABLED" == 1 ]]; then
  systemctl restart kinect360-remold-camera-ip.service
fi

stage "[5/5] Verifying runtime services and published transports..."
# Wait for the runtime graph, local IPC endpoints and audio transition.
udevadm settle --timeout=10 2>/dev/null || true
for _ in $(seq 1 80); do
  if systemctl is-active --quiet kinect360-remold-broker.service \
      && systemctl is-active --quiet kinect360-remold-camera.service \
      && systemctl is-active --quiet kinect360-remold-audio.service \
      && [[ -S "$RUN_DIR/control.sock" ]] \
      && [[ -S "$RUN_DIR/sdk.sock" ]] \
      && [[ -r "$RUN_DIR/devices.tsv" ]]; then
    break
  fi
  sleep 0.25
done

for service in broker camera audio v4l2; do
  systemctl is-active --quiet "kinect360-remold-$service.service" || {
    echo "Kinect runtime service failed to start: kinect360-remold-$service.service" >&2
    systemctl --no-pager --plain status "kinect360-remold-$service.service" 2>/dev/null | tail -n 20 >&2 || true
    exit 3
  }
done

verify_running_executable(){
  local service="$1" expected="$2" expected_cwd="$3" pid exe cwd
  pid="$(systemctl show -p MainPID --value "$service" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "Runtime service has no live process: $service" >&2; exit 3; }
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  [[ "$exe" == "$expected" ]] || {
    echo "Runtime service is not executing the installed system binary: $service -> ${exe:-unknown}" >&2
    exit 3
  }
  [[ "$cwd" == "$expected_cwd" ]] || {
    echo "Runtime service is not using its installed state directory: $service -> ${cwd:-unknown}" >&2
    exit 3
  }
  case "$exe:$cwd" in
    "$BUNDLE"*) echo "Runtime service is attached to the build/distribution tree: $service" >&2; exit 3 ;;
  esac
  if [[ -n "${PROJECT:-}" ]]; then
    case "$exe:$cwd" in
      "$PROJECT"*) echo "Runtime service is attached to the repository tree: $service" >&2; exit 3 ;;
    esac
  fi
}
verify_running_executable kinect360-remold-broker.service "$LIBEXEC_DIR/kinect360-remold-broker" "$STATE_DIR"
verify_running_executable kinect360-remold-camera.service "$LIBEXEC_DIR/kinect360-remold-camera" "$STATE_DIR"
verify_running_executable kinect360-remold-audio.service "$LIBEXEC_DIR/kinect360-remold-audio" "$STATE_DIR"
verify_running_executable kinect360-remold-v4l2.service "$LIBEXEC_DIR/kinect360-remold-v4l2" "$STATE_DIR"
if [[ "$IP_ENABLED" == true || "$IP_ENABLED" == 1 ]]; then
  systemctl is-active --quiet kinect360-remold-camera-ip.service || { echo 'Kinect IP camera service failed to start.' >&2; exit 3; }
  verify_running_executable kinect360-remold-camera-ip.service "$LIBEXEC_DIR/kinect360-remold-camera-ip" "$STATE_DIR"
fi

[[ -S "$RUN_DIR/control.sock" && -S "$RUN_DIR/sdk.sock" ]] || {
  echo 'Kinect runtime local IPC endpoints were not published.' >&2
  exit 3
}

manifest_has_devices(){
  awk -F '\t' '$1 !~ /^#/ && $1 != "" {found=1} END{exit !found}' "$RUN_DIR/devices.tsv" 2>/dev/null
}
manifest_transports_ready(){
  awk -F '\t' '
    $1 !~ /^#/ && $1 != "" {
      found=1
      if ($3 != "Ready" || $4 == "" || $5 == "" || $6 == "" || $7 == "") bad=1
    }
    END{exit !(found && !bad)}
  ' "$RUN_DIR/devices.tsv" 2>/dev/null
}
audio_transport_ready(){
  local status="$RUN_DIR/audio-bridge-status.txt" stage channels rate frames age publishers packets
  [[ -r "$status" ]] || return 1
  stage="$(awk -F= '$1=="stage"{print $2;exit}' "$status")"
  channels="$(awk -F= '$1=="capture_channels"{print $2;exit}' "$status")"
  rate="$(awk -F= '$1=="stream_sample_rate"{print $2;exit}' "$status")"
  frames="$(awk -F= '$1=="published_frames"{print $2;exit}' "$status")"
  age="$(awk -F= '$1=="frame_age_ms"{print $2;exit}' "$status")"
  publishers="$(awk -F= '$1=="system_audio_publishers"{print $2;exit}' "$status")"
  packets="$(awk -F= '$1=="system_audio_packets"{print $2;exit}' "$status")"
  [[ "$stage" == uac-runtime-capturing && "${channels:-0}" -ge 4 && "${rate:-0}" -eq 16000 && "${frames:-0}" -gt 0 && "${age:--1}" -ge 0 && "${age:--1}" -le 3000 && "${publishers:-0}" -gt 0 && "${packets:-0}" -gt 0 ]]
}
if manifest_has_devices; then
  for _ in $(seq 1 180); do
    if manifest_transports_ready && audio_transport_ready; then break; fi
    sleep 0.25
  done
  if ! manifest_transports_ready || ! audio_transport_ready; then
    echo 'A connected Kinect did not become fully operational before the verification timeout.' >&2
    echo 'Camera/control sockets alone are not sufficient: microphone PCM and the Linux system-audio endpoint must both be flowing.' >&2
    cat "$RUN_DIR/devices.tsv" >&2 2>/dev/null || true
    echo 'Audio bridge state:' >&2
    cat "$RUN_DIR/audio-bridge-status.txt" >&2 2>/dev/null || true
    exit 3
  fi
fi

printf '
'
printf '%s
' '============================================================'
printf '%s
' ' Installation summary'
printf '%s
' '============================================================'
summary_item 'Broker' 'READY'
summary_item 'Camera' 'READY'
summary_item 'Audio' 'READY'
summary_item 'V4L2' 'READY'
if [[ "$IP_ENABLED" == true || "$IP_ENABLED" == 1 ]]; then
  summary_item 'CameraIp' 'READY'
else
  summary_item 'CameraIp' 'DISABLED'
fi
printf '
'
printf 'Kinect Remold — Xbox 360 installation complete.
'
printf 'No Linux restart is required by the Remold installer.
'
