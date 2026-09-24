#!/usr/bin/env bash
set -euo pipefail
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
  BUNDLE="$PROJECT/binaries/linux/drivers"
fi
[[ -x "$BUNDLE/bin/kinect360-remoldctl" && -d "$BUNDLE/libexec/kinect360-remold" ]] || { echo 'Built Linux driver runtime not found. Run bash Kinect-Xbox-360-Remold.sh --build-only first.' >&2; exit 2; }
# Installation consumes the prepared runtime bundle and performs no build or network work.
[[ $# -eq 0 ]] || { echo 'INSTALL.sh does not accept options. Build first, then install the prepared bundle.' >&2; exit 2; }

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
EXPECTED_V4L2_VERSION='0.15.4'
EXPECTED_V4L2_SOURCE_SHA='21a17702648aa6a937b88a93bd71ef9f547815ead28719cafcfcc247396643dc'
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
  "$SUPPORT/modules-load/kinect360-remold.conf"
  "$SUPPORT/config/remold.conf"
  "$SUPPORT/firmware/UACFirmware-01.02.709.00"
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

FIRMWARE_SOURCE="$SUPPORT/firmware/UACFirmware-01.02.709.00"
[[ -f "$FIRMWARE_SOURCE" ]] || {
  echo 'Microsoft Kinect UACFirmware 01.02.709.00 is missing from the built Linux runtime.' >&2
  echo 'Rebuild the complete project so the verified firmware is prepared automatically.' >&2
  exit 2
}
EXPECTED_FIRMWARE_SHA='4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9'
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
    pkill -TERM -f '^/usr/libexec/kinect360-remold/' 2>/dev/null || true
    sleep 0.05
    pkill -KILL -f '^/usr/libexec/kinect360-remold/' 2>/dev/null || true
  fi
}

remove_owned_v4l2loopback(){
  local marker=/usr/share/kinect360-remold/v4l2loopback-owned-path old_module old_kernel
  old_module="$(cat "$marker" 2>/dev/null || true)"
  modprobe -r v4l2loopback 2>/dev/null || true
  if [[ "$old_module" == /lib/modules/*/updates/kinect360-remold/v4l2loopback.ko && -f "$old_module" ]]; then
    old_kernel="${old_module#/lib/modules/}"
    old_kernel="${old_kernel%%/*}"
    rm -f "$old_module"
    rmdir "$(dirname "$old_module")" 2>/dev/null || true
    depmod -a "$old_kernel" 2>/dev/null || true
  fi
}

clean_installed_runtime(){
  stop_installed_runtime
  remove_owned_v4l2loopback
  rm -rf /run/kinect360-remold
  rm -f /usr/bin/kinect360-remoldctl
  rm -rf /usr/libexec/kinect360-remold /usr/share/kinect360-remold
  rm -f /etc/systemd/system/kinect360-remold*.service /etc/systemd/system/kinect360-remold.target
  rm -rf /etc/systemd/system/kinect360-remold*.service.d /etc/systemd/system/kinect360-remold.target.d
  rm -f /etc/udev/rules.d/60-kinect360-remold.rules
  rm -f /etc/modprobe.d/kinect360-remold-v4l2.conf /etc/modprobe.d/kinect360-remold-camera.conf /etc/modules-load.d/kinect360-remold.conf
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

clean_installed_runtime

install -D -m 0755 "$BUNDLE/bin/kinect360-remoldctl" /usr/bin/kinect360-remoldctl
install -D -m 0644 "$BUNDLE/VERSION" /usr/share/kinect360-remold/VERSION
install -D -m 0644 "$SUPPORT/kernel/KERNEL-RELEASE" /usr/share/kinect360-remold/KERNEL-RELEASE
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-VERSION" /usr/share/kinect360-remold/V4L2LOOPBACK-VERSION
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256" /usr/share/kinect360-remold/V4L2LOOPBACK-SOURCE-SHA256
install -D -m 0644 "$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256" /usr/share/kinect360-remold/V4L2LOOPBACK-MODULE-SHA256
for f in "$BUNDLE"/libexec/kinect360-remold/*;do install -D -m 0755 "$f" "/usr/libexec/kinect360-remold/$(basename "$f")";done
install -D -m 0644 "$SUPPORT/udev/60-kinect360-remold.rules" /etc/udev/rules.d/60-kinect360-remold.rules
install -D -m 0644 "$SUPPORT/modprobe/kinect360-remold-v4l2.conf" /etc/modprobe.d/kinect360-remold-v4l2.conf
install -D -m 0644 "$SUPPORT/modprobe/kinect360-remold-camera.conf" /etc/modprobe.d/kinect360-remold-camera.conf
install -D -m 0644 "$SUPPORT/modules-load/kinect360-remold.conf" /etc/modules-load.d/kinect360-remold.conf
mkdir -p /etc/kinect360-remold /var/lib/kinect360-remold /usr/share/kinect360-remold
INSTALLED_V4L2="/lib/modules/$KERNEL_RELEASE/updates/kinect360-remold/v4l2loopback.ko"
install -D -m 0644 "$BUNDLED_V4L2" "$INSTALLED_V4L2"
printf '%s\n' "$INSTALLED_V4L2" >/usr/share/kinect360-remold/v4l2loopback-owned-path
depmod -a "$KERNEL_RELEASE"
[[ "$(modinfo -F version "$INSTALLED_V4L2" 2>/dev/null | head -1 | tr -d '[:space:]')" == "$bundled_v4l2_version" ]] || {
  echo 'Installed v4l2loopback module failed verification.' >&2
  exit 3
}
for REQUIRED_GROUP in video audio; do
  if ! getent group "$REQUIRED_GROUP" >/dev/null 2>&1; then groupadd --system "$REQUIRED_GROUP"; fi
done
IP_SERVICE_USER=kinect360-remold-ip
if ! getent group "$IP_SERVICE_USER" >/dev/null 2>&1; then groupadd --system "$IP_SERVICE_USER"; fi
if ! id -u "$IP_SERVICE_USER" >/dev/null 2>&1; then
  NOLOGIN="$(command -v nologin || true)"; [[ -n "$NOLOGIN" ]] || NOLOGIN=/usr/sbin/nologin
  useradd --system --gid "$IP_SERVICE_USER" --no-create-home --home-dir /nonexistent --shell "$NOLOGIN" "$IP_SERVICE_USER"
fi
chown root:"$IP_SERVICE_USER" /etc/kinect360-remold
chmod 0750 /etc/kinect360-remold
CFG=/etc/kinect360-remold/remold.conf
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

for f in "$SUPPORT"/systemd/*;do install -D -m 0644 "$f" "/etc/systemd/system/$(basename "$f")";done
install -m 0644 "$FIRMWARE_SOURCE" /usr/share/kinect360-remold/UACFirmware

verify_installed_file(){
  local source="$1" installed="$2"
  cmp -s "$source" "$installed" || {
    echo "Installed runtime verification failed: $installed does not match the current bundle." >&2
    exit 3
  }
}
verify_installed_file "$BUNDLE/bin/kinect360-remoldctl" /usr/bin/kinect360-remoldctl
verify_installed_file "$BUNDLE/VERSION" /usr/share/kinect360-remold/VERSION
verify_installed_file "$SUPPORT/kernel/KERNEL-RELEASE" /usr/share/kinect360-remold/KERNEL-RELEASE
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-VERSION" /usr/share/kinect360-remold/V4L2LOOPBACK-VERSION
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-SOURCE-SHA256" /usr/share/kinect360-remold/V4L2LOOPBACK-SOURCE-SHA256
verify_installed_file "$SUPPORT/kernel/V4L2LOOPBACK-MODULE-SHA256" /usr/share/kinect360-remold/V4L2LOOPBACK-MODULE-SHA256
for source_file in "$BUNDLE"/libexec/kinect360-remold/*; do
  verify_installed_file "$source_file" "/usr/libexec/kinect360-remold/$(basename "$source_file")"
done
verify_installed_file "$SUPPORT/udev/60-kinect360-remold.rules" /etc/udev/rules.d/60-kinect360-remold.rules
verify_installed_file "$SUPPORT/modprobe/kinect360-remold-v4l2.conf" /etc/modprobe.d/kinect360-remold-v4l2.conf
verify_installed_file "$SUPPORT/modprobe/kinect360-remold-camera.conf" /etc/modprobe.d/kinect360-remold-camera.conf
verify_installed_file "$SUPPORT/modules-load/kinect360-remold.conf" /etc/modules-load.d/kinect360-remold.conf
for source_file in "$SUPPORT"/systemd/*; do
  verify_installed_file "$source_file" "/etc/systemd/system/$(basename "$source_file")"
done
verify_installed_file "$FIRMWARE_SOURCE" /usr/share/kinect360-remold/UACFirmware

verify_installed_file "$BUNDLED_V4L2" "$INSTALLED_V4L2"

systemctl daemon-reload
udevadm control --reload-rules
modprobe -r v4l2loopback 2>/dev/null || true
if ! modprobe v4l2loopback; then
  echo 'Could not load the bundled v4l2loopback module.' >&2
  echo 'Verify the running kernel/headers and kernel module-signing or Secure Boot policy, then rebuild under this kernel.' >&2
  exit 3
fi
modprobe -r gspca_kinect 2>/dev/null || true
udevadm trigger --subsystem-match=usb || true
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

# Wait for the runtime graph, local IPC endpoints and audio transition.
udevadm settle --timeout=10 2>/dev/null || true
for _ in $(seq 1 80); do
  if systemctl is-active --quiet kinect360-remold-broker.service \
      && systemctl is-active --quiet kinect360-remold-camera.service \
      && systemctl is-active --quiet kinect360-remold-audio.service \
      && [[ -S /run/kinect360-remold/control.sock ]] \
      && [[ -S /run/kinect360-remold/sdk.sock ]] \
      && [[ -r /run/kinect360-remold/devices.tsv ]]; then
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
  local service="$1" expected="$2" pid exe
  pid="$(systemctl show -p MainPID --value "$service" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "Runtime service has no live process: $service" >&2; exit 3; }
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [[ "$exe" == "$expected" ]] || {
    echo "Runtime service is not executing the newly installed binary: $service -> ${exe:-unknown}" >&2
    exit 3
  }
}
verify_running_executable kinect360-remold-broker.service /usr/libexec/kinect360-remold/kinect360-remold-broker
verify_running_executable kinect360-remold-camera.service /usr/libexec/kinect360-remold/kinect360-remold-camera
verify_running_executable kinect360-remold-audio.service /usr/libexec/kinect360-remold/kinect360-remold-audio
verify_running_executable kinect360-remold-v4l2.service /usr/libexec/kinect360-remold/kinect360-remold-v4l2
if [[ "$IP_ENABLED" == true || "$IP_ENABLED" == 1 ]]; then
  systemctl is-active --quiet kinect360-remold-camera-ip.service || { echo 'Kinect IP camera service failed to start.' >&2; exit 3; }
  verify_running_executable kinect360-remold-camera-ip.service /usr/libexec/kinect360-remold/kinect360-remold-camera-ip
fi

[[ -S /run/kinect360-remold/control.sock && -S /run/kinect360-remold/sdk.sock ]] || {
  echo 'Kinect runtime local IPC endpoints were not published.' >&2
  exit 3
}

manifest_has_devices(){
  awk -F '\t' '$1 !~ /^#/ && $1 != "" {found=1} END{exit !found}' /run/kinect360-remold/devices.tsv 2>/dev/null
}
manifest_transports_ready(){
  awk -F '\t' '
    $1 !~ /^#/ && $1 != "" {
      found=1
      if ($3 != "Ready" || $4 == "" || $5 == "" || $6 == "" || $7 == "") bad=1
    }
    END{exit !(found && !bad)}
  ' /run/kinect360-remold/devices.tsv 2>/dev/null
}
if manifest_has_devices; then
  for _ in $(seq 1 120); do
    manifest_transports_ready && break
    sleep 0.25
  done
  if ! manifest_transports_ready; then
    echo 'A connected Kinect did not publish all local camera/audio/control transports.' >&2
    cat /run/kinect360-remold/devices.tsv >&2 2>/dev/null || true
    echo 'Audio bridge state:' >&2
    cat /run/kinect360-remold/audio-bridge-status.txt >&2 2>/dev/null || true
    exit 3
  fi
fi

printf 'Kinect Xbox 360 Remold %s installed.\n' "$(tr -d '\r\n' <"$BUNDLE/VERSION")"
