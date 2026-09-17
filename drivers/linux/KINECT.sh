#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

restore_linux_script_permissions(){
  local script
  while IFS= read -r -d '' script; do
    chmod u+x "$script" 2>/dev/null || true
  done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -print0 2>/dev/null)
}

PROJECT_ROOT="$(cd "$ROOT/../.." && pwd)"
restore_linux_script_permissions
PRODUCT_NAME="Kinect Xbox 360 Remold"
ACTION="Menu"
TARGET_DEVICE=""
while (($#)); do
  case "$1" in
    --action) ACTION="${2:-Menu}"; shift 2 || true ;;
    --device) TARGET_DEVICE="${2:-}"; shift 2 || true ;;
    *) break ;;
  esac
done

pause_menu(){
  printf '\nPress Enter to continue'
  IFS= read -r _ || true
}

header(){
  command -v clear >/dev/null 2>&1 && clear || true
  printf '%s\n' '============================================================'
  printf ' %s - Linux control panel\n' "$PRODUCT_NAME"
  printf '%s\n' '============================================================'
}

caller_user(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then id -un; return; fi
  if [[ -n "${REMOLD_CALLER_USER:-}" && "${REMOLD_CALLER_USER}" != root ]]; then printf '%s\n' "$REMOLD_CALLER_USER"; return; fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then printf '%s\n' "$SUDO_USER"; return; fi
  if [[ -n "${PKEXEC_UID:-}" ]] && command -v getent >/dev/null 2>&1; then
    getent passwd "$PKEXEC_UID" | awk -F: '$1!="root"{print $1;exit}'
  fi
}

run_root(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
    return
  fi
  local user
  user="$(caller_user)"
  if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
    sudo env REMOLD_CALLER_USER="$user" "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec env REMOLD_CALLER_USER="$user" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo env REMOLD_CALLER_USER="$user" "$@"
  else
    printf 'Administrator permission is required for this system change; neither sudo nor pkexec is available.\n' >&2
    return 1
  fi
}

resolve_dist_dir(){
  local arch="$(uname -m)" candidate state_file saved
  state_file="${HOME:-/tmp}/.local/state/kinect360-remold/linux-driver-dist-$arch.path"
  if [[ -r "$state_file" ]]; then
    IFS= read -r saved < "$state_file" || true
    if [[ -n "$saved" && -f "$saved/bin/kinect360-remoldctl" ]]; then printf '%s\n' "$saved"; return 0; fi
  fi
  candidate="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/kinect360-remold/linux-driver/dist/$arch"
  printf '%s\n' "$candidate"
}

distribution_ready(){
  local dist="$(resolve_dist_dir)" file
  local expected=(
    "$dist/bin/kinect360-remoldctl"
    "$dist/libexec/kinect360-remold/kinect360-remold-nui"
    "$dist/libexec/kinect360-remold/kinect360-remold-broker"
    "$dist/libexec/kinect360-remold/kinect360-remold-camera"
    "$dist/libexec/kinect360-remold/kinect360-remold-audio"
    "$dist/libexec/kinect360-remold/kinect360-remold-v4l2"
    "$dist/libexec/kinect360-remold/ensure-v4l2-device.sh"
  )
  for file in "${expected[@]}"; do
    [[ -f "$file" ]] || return 1
    chmod u+x "$file" 2>/dev/null || true
    [[ -x "$file" ]] || return 1
  done
  return 0
}

find_ctl(){
  local dist="$(resolve_dist_dir)"
  local candidates=(
    "/usr/bin/kinect360-remoldctl"
    "$dist/bin/kinect360-remoldctl"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      chmod u+x "$candidate" 2>/dev/null || true
      if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
    fi
  done
  return 1
}

run_ctl(){
  local ctl args=()
  ctl="$(find_ctl)" || return 127
  [[ -n "$TARGET_DEVICE" ]] && args+=(--device "$TARGET_DEVICE")
  "$ctl" "${args[@]}" "$@"
}

show_status(){
  if find_ctl >/dev/null; then
    run_ctl status || true
  else
    printf 'kinect360-remoldctl was not found. Install / Reinstall the driver first.\n'
  fi
  show_rgb_hq
  printf '\nServices:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --plain status kinect360-remold.target 2>/dev/null | sed -n '1,12p' || true
  else
    printf 'systemctl is not available on this system.\n'
  fi
}

virtual_camera_name(){
  local node="$1" base
  base="$(basename "$node")"
  [[ -r "/sys/class/video4linux/$base/name" ]] || return 1
  cat "/sys/class/video4linux/$base/name"
}

resolve_virtual_camera(){
  local label='Kinect Xbox 360 Camera' candidate='' p name cfg='/etc/kinect360-remold/remold.conf'
  if [[ -r /run/kinect360-remold/v4l2-device ]]; then
    candidate="$(head -n1 /run/kinect360-remold/v4l2-device | tr -d '\r\n')"
    if [[ -e "$candidate" && "$(virtual_camera_name "$candidate" 2>/dev/null || true)" == "$label" ]]; then printf '%s\n' "$candidate"; return 0; fi
  fi
  for p in /sys/class/video4linux/video*; do
    [[ -r "$p/name" ]] || continue
    name="$(cat "$p/name" 2>/dev/null || true)"
    if [[ "$name" == "$label" && -e "/dev/${p##*/}" ]]; then printf '/dev/%s\n' "${p##*/}"; return 0; fi
  done
  if [[ -r "$cfg" ]]; then
    candidate="$(awk -F= '$1=="v4l2.device"{sub(/^[^=]*=/,""); print; exit}' "$cfg" | tr -d '\r' | xargs 2>/dev/null || true)"
    if [[ -e "$candidate" && "$(virtual_camera_name "$candidate" 2>/dev/null || true)" == "$label" ]]; then printf '%s\n' "$candidate"; return 0; fi
  fi
  return 1
}

ensure_virtual_camera_service(){
  command -v systemctl >/dev/null 2>&1 || return 0
  if ! systemctl is-active --quiet kinect360-remold-v4l2.service 2>/dev/null; then
    run_root systemctl start kinect360-remold-v4l2.service >/dev/null 2>&1 || true
  fi
}

show_virtual_camera(){
  local device='' i
  ensure_virtual_camera_service
  for i in {1..30}; do
    if device="$(resolve_virtual_camera 2>/dev/null)"; then break; fi
    sleep 0.1
  done
  if [[ -n "$device" && -e "$device" ]]; then
    printf 'Kinect virtual camera: %s\n' "$device"
    printf 'Device name: %s\n' "$(virtual_camera_name "$device" 2>/dev/null || printf unknown)"
    ls -l "$device"
    if command -v v4l2-ctl >/dev/null 2>&1; then v4l2-ctl -d "$device" --all 2>/dev/null | sed -n '1,18p' || true; fi
    printf '%s\n' "$device"
    return 0
  fi

  printf 'Kinect virtual camera was not found.\n' >&2
  if command -v systemctl >/dev/null 2>&1; then
    printf 'v4l2 service: ' >&2; systemctl is-active kinect360-remold-v4l2.service 2>/dev/null || true
    systemctl --no-pager --plain status kinect360-remold-v4l2.service 2>/dev/null | sed -n '1,14p' >&2 || true
  fi
  if command -v modinfo >/dev/null 2>&1; then
    printf 'v4l2loopback version: ' >&2; modinfo -F version v4l2loopback 2>/dev/null | head -n1 >&2 || printf 'not installed\n' >&2
  fi
  printf 'If the module is installed but cannot load, check DKMS and Secure Boot module signing.\n' >&2
  return 1
}

open_camera(){
  local device=''
  show_virtual_camera >/dev/null || return 1
  device="$(resolve_virtual_camera)" || return 1
  if command -v cheese >/dev/null 2>&1; then nohup cheese --device="$device" >/dev/null 2>&1 & return 0; fi
  if command -v qv4l2 >/dev/null 2>&1; then nohup qv4l2 -d "$device" >/dev/null 2>&1 & return 0; fi
  if command -v guvcview >/dev/null 2>&1; then nohup guvcview -d "$device" >/dev/null 2>&1 & return 0; fi
  printf 'No desktop camera viewer (Cheese, qv4l2 or guvcview) was found; the virtual camera is ready at %s.\n' "$device"
}

set_tilt(){
  local ctl value="${1:-}"
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  if [[ -z "$value" ]]; then
    printf 'Tilt angle in degrees (-27 to 27; 0 is geometric center): '
    IFS= read -r value || return 1
  fi
  [[ "$value" =~ ^-?[0-9]+$ ]] || { printf 'Invalid value.\n'; return 1; }
  (( value < -27 )) && value=-27
  (( value > 27 )) && value=27
  local args=(); [[ -n "$TARGET_DEVICE" ]] && args+=(--device "$TARGET_DEVICE")
  "$ctl" "${args[@]}" tilt "$value"
}

startup_tilt(){
  local ctl
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  local args=(); [[ -n "$TARGET_DEVICE" ]] && args+=(--device "$TARGET_DEVICE")
  "$ctl" "${args[@]}" tilt 0
}

show_ip_status(){
  local cfg=/etc/kinect360-remold/remold.conf
  if [[ -r "$cfg" ]]; then
    grep -E '^(ip\.enabled|ip\.port|ip\.user|ip\.password)=' "$cfg" || true
  else
    printf 'IP camera configuration is protected from ordinary users.\n'
    printf 'Status can still be inspected without elevation:\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf 'camera-ip service: '
    systemctl is-active kinect360-remold-camera-ip.service 2>/dev/null || true
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '$4 ~ /:8088$/ {print "listener: "$4}' || true
  fi
}

replace_config_value(){
  local key="$1" value="$2" cfg=/etc/kinect360-remold/remold.conf tmp
  [[ -f "$cfg" ]] || { printf 'Kinect runtime configuration is not installed.\n' >&2; return 1; }
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN{done=0}
    index($0,key"=")==1 {print key"="value;done=1;next}
    {print}
    END{if(!done)print key"="value}
  ' "$cfg" > "$tmp"
  install -o root -g root -m 0640 "$tmp" "$cfg"
  rm -f "$tmp"
}

reset_ip_password_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local pass
  pass="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  replace_config_value ip.password "$pass"
  if systemctl is-active --quiet kinect360-remold-camera-ip.service 2>/dev/null; then
    systemctl restart kinect360-remold-camera-ip.service
  fi
  printf 'IP camera credentials: admin / %s\n' "$pass"
}

ip_toggle_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local cfg=/etc/kinect360-remold/remold.conf current=false next=true
  [[ -f "$cfg" ]] || { printf 'Kinect runtime configuration is not installed.\n' >&2; return 1; }
  current="$(awk -F= '$1=="ip.enabled"{gsub(/[[:space:]]/,"",$2);print tolower($2);exit}' "$cfg")"
  [[ "$current" == true || "$current" == 1 ]] && next=false
  replace_config_value ip.enabled "$next"
  if [[ "$next" == true ]]; then
    systemctl restart kinect360-remold-camera-ip.service
    printf 'IP camera enabled.\n'
  else
    systemctl stop kinect360-remold-camera-ip.service 2>/dev/null || true
    printf 'IP camera disabled.\n'
  fi
}


rgb_hq_enabled(){
  local cfg=/etc/kinect360-remold/remold.conf value=false
  if [[ -r "$cfg" ]]; then
    value="$(awk -F= '$1=="rgb.hq.enabled"{gsub(/[[:space:]]/,"",$2);print tolower($2);exit}' "$cfg")"
  fi
  [[ "$value" == true || "$value" == 1 || "$value" == yes || "$value" == on ]]
}

show_rgb_hq(){
  if rgb_hq_enabled; then
    printf 'RGB HQ: ENABLED\n'
  else
    printf 'RGB HQ: DISABLED\n'
  fi
}

rgb_hq_toggle_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local cfg=/etc/kinect360-remold/remold.conf next=true
  [[ -f "$cfg" ]] || { printf 'Kinect runtime configuration is not installed.\n' >&2; return 1; }
  if rgb_hq_enabled; then next=false; fi
  replace_config_value rgb.hq.enabled "$next"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart kinect360-remold-v4l2.service 2>/dev/null || true
    systemctl try-restart kinect360-remold-camera-ip.service 2>/dev/null || true
  fi
  if [[ "$next" == true ]]; then printf 'RGB HQ enabled.\n'; else printf 'RGB HQ disabled.\n'; fi
}

find_studio(){
  local candidates=(
    "$ROOT/studio/SynKinectStudio.sh"
    "$ROOT/../../applications/binaries/linux-x64/SynKinectStudio.sh"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

open_studio(){
  local studio user uid runtime_dir
  if ! studio="$(find_studio)"; then
    printf 'SynKinect Studio Linux launcher was not found in this distribution.\n' >&2
    printf 'Expected applications/binaries/linux-x64/SynKinectStudio.sh or studio/SynKinectStudio.sh.\n' >&2
    return 1
  fi
  chmod +x "$studio" 2>/dev/null || true
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    user="$(caller_user)"
    [[ -n "$user" && "$user" != root ]] || { printf 'Refusing to start SynKinect Studio as root; launch it from the desktop user session.\n' >&2; return 1; }
    uid="$(id -u "$user")"
    runtime_dir="/run/user/$uid"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$user" -- env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" bash "$studio" >/dev/null 2>&1 &
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$user" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" bash "$studio" >/dev/null 2>&1 &
    else
      printf 'Cannot drop root privileges because neither runuser nor sudo is available.\n' >&2
      return 1
    fi
  else
    bash "$studio" >/dev/null 2>&1 &
  fi
  printf 'SynKinect Studio opened as the standard desktop user: %s\n' "$studio"
}

run_action(){
  case "$1" in
    Install)
      header
      if ! distribution_ready; then
        printf 'Complete compiled V1 distribution not found; running the dependency/bootstrap build first.\n'
        REMOLD_NO_PAUSE=1 bash "$ROOT/BUILD.sh" || return $?
      fi
      printf 'Build complete. Administrator permission is now requested only for runtime installation/system changes.\n'
      run_root bash "$ROOT/INSTALL.sh" --direct
      ;;
    Status) header; show_status ;;
    OpenCamera) header; open_camera ;;
    Tilt) header; set_tilt ;;
    StartupTilt) header; startup_tilt ;;
    IpStatus) header; show_ip_status ;;
    IpReset) header; printf 'Resetting the protected IP-camera password requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-reset ;;
    IpToggle) header; printf 'Changing the IP-camera service requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-toggle ;;
    RgbHqToggle) header; printf 'Changing RGB HQ requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-rgb-hq-toggle ;;
    OpenStudio) header; open_studio ;;
    Uninstall) header; printf 'Type REMOVE to confirm: '; IFS= read -r confirm || true; if [[ "$confirm" == REMOVE ]]; then run_root bash "$ROOT/UNINSTALL.sh"; else printf 'Canceled.\n'; fi ;;
    *) printf 'Unknown action: %s\n' "$1" >&2; return 2 ;;
  esac
}

# Private root-only entry points used after sudo/pkexec. They never launch Studio.
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-reset" ]]; then reset_ip_password_root; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-toggle" ]]; then ip_toggle_root; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-rgb-hq-toggle" ]]; then rgb_hq_toggle_root; exit $?; fi

if [[ "$ACTION" != Menu ]]; then
  run_action "$ACTION"
  exit $?
fi

while true; do
  header
  printf '%s\n' \
    '1  Install / Reinstall' \
    '2  Status' \
    '3  Open / show virtual camera device' \
    '4  Set manual Tilt' \
    '5  Return Tilt to startup pose (0 degrees)' \
    '6  Show IP camera configuration / status' \
    '7  Restart Kinect runtime' \
    '8  Stop / Start Kinect runtime' \
    '9  Uninstall' \
    '10 Open SynKinect Studio (Linux)' \
    '11 Reset IP camera password' \
    '12 Enable / Disable IP camera' \
    '13 Enable / Disable RGB HQ' \
    '0  Exit'
  printf '\nChoose: '
  IFS= read -r choice || exit 0
  case "${choice//[[:space:]]/}" in
    1) run_action Install || true; pause_menu ;;
    2) run_action Status; pause_menu ;;
    3) run_action OpenCamera || true; pause_menu ;;
    4) run_action Tilt || true; pause_menu ;;
    5) run_action StartupTilt || true; pause_menu ;;
    6) run_action IpStatus; pause_menu ;;
    7) header; run_root systemctl restart kinect360-remold.target || true; show_status; pause_menu ;;
    8) header; if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet kinect360-remold.target; then run_root systemctl stop kinect360-remold.target || true; else run_root systemctl start kinect360-remold.target || true; fi; pause_menu ;;
    9) run_action Uninstall || true; pause_menu ;;
    10) run_action OpenStudio || true; sleep 0.5 ;;
    11) run_action IpReset || true; pause_menu ;;
    12) run_action IpToggle || true; pause_menu ;;
    13) run_action RgbHqToggle || true; pause_menu ;;
    0) exit 0 ;;
    *) printf 'Invalid option.\n'; sleep 0.7 ;;
  esac
done
