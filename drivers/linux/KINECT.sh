#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_NAME="Kinect Xbox 360 Remold"
ACTION="Menu"
DEVICE_ID=""
while (($#)); do
  case "$1" in
    --action) ACTION="${2:-Menu}"; shift 2 ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done

pause_menu(){
  printf '\nPress Enter to continue'
  IFS= read -r _ || true
}

header(){
  if [[ -t 1 && -n "${TERM:-}" ]] && command -v clear >/dev/null 2>&1; then clear || true; fi
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

# Installation uses the prepared local runtime bundle.

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

find_ctl(){
  local candidates=(
    "/usr/bin/kinect360-remoldctl"
    "$ROOT/bin/kinect360-remoldctl"
    "$ROOT/../../binaries/linux/drivers/bin/kinect360-remoldctl"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

show_status(){
  local ctl
  if ctl="$(find_ctl)"; then
    "$ctl" status || true
  else
    printf 'kinect360-remoldctl was not found. Install / Reinstall the driver first.\n'
  fi
  printf '\nServices:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --plain status kinect360-remold.target 2>/dev/null | sed -n '1,12p' || true
  else
    printf 'systemctl is not available on this system.\n'
  fi
}

virtual_camera_for(){
  local id="${1:-}" manifest=/run/kinect360-remold/devices.tsv
  if [[ -n "$id" && -r "$manifest" ]]; then awk -F '\t' -v id="$id" '$1==id{print $8;exit}' "$manifest"; return; fi
  if [[ -r "$manifest" ]]; then awk -F '\t' '$8!=""{print $8;exit}' "$manifest"; return; fi
}

show_virtual_camera(){
  local manifest=/run/kinect360-remold/devices.tsv
  if [[ -r "$manifest" ]]; then
    awk -F '\t' 'BEGIN{printf "%-28s %-13s %s\n","DEVICE ID","STATE","VIRTUAL CAMERA"} $1!~/^#/{printf "%-28s %-13s %s\n",$1,$3,$8}' "$manifest"
  else
    printf 'No runtime device manifest is available.\n'
  fi
}

open_camera(){
  local node
  show_virtual_camera
  node="$(virtual_camera_for "$DEVICE_ID")"
  [[ -n "$node" && -e "$node" ]] || { printf 'Virtual camera is not ready for device %s.\n' "${DEVICE_ID:-auto}" >&2; return 1; }
  if command -v cheese >/dev/null 2>&1; then nohup cheese --device="$node" >/dev/null 2>&1 & return 0; fi
  if command -v qv4l2 >/dev/null 2>&1; then nohup qv4l2 -d "$node" >/dev/null 2>&1 & return 0; fi
  if command -v guvcview >/dev/null 2>&1; then nohup guvcview -d "$node" >/dev/null 2>&1 & return 0; fi
  printf 'No desktop camera viewer was found; the virtual device is ready at %s.\n' "$node"
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
  if [[ -n "$DEVICE_ID" ]]; then "$ctl" --device "$DEVICE_ID" tilt "$value"; else "$ctl" tilt "$value"; fi
}

# Startup pose from remold.conf; the product default is +6 degrees.
startup_tilt_degrees(){
  local cfg=/etc/kinect360-remold/remold.conf value=""
  [[ -r "$cfg" ]] && value="$(awk -F= '$1=="tilt.startup"{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$cfg")"
  [[ "$value" =~ ^-?[0-9]+$ ]] || value=6
  printf '%s' "$value"
}

startup_tilt(){
  set_tilt "$(startup_tilt_degrees)"
}

rgb_hq_action(){
  local mode="${1:-toggle}" ctl action
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  case "$mode" in
    status|on|off|toggle) action="rgb-hq-$mode" ;;
    *) printf 'Unknown RGB HQ action: %s\n' "$mode" >&2; return 2 ;;
  esac
  if [[ -n "$DEVICE_ID" ]]; then
    "$ctl" --device "$DEVICE_ID" "$action"
  else
    "$ctl" "$action"
  fi
}
rgb_hq_toggle(){ rgb_hq_action toggle; }

show_ip_status(){
  local cfg=/etc/kinect360-remold/remold.conf port=8088
  if [[ -r "$cfg" ]]; then
    grep -E '^(ip\.enabled|ip\.bind|ip\.port|ip\.user|ip\.fps|ip\.jpeg_quality|ip\.max_clients)=' "$cfg" || true
    port="$(awk -F= '$1=="ip.port"{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$cfg")"
    [[ "$port" =~ ^[0-9]+$ ]] || port=8088
  else
    printf 'IP camera configuration is protected from ordinary users. Credentials are never shown by status.\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf 'camera-ip service: '
    systemctl is-active kinect360-remold-camera-ip.service 2>/dev/null || true
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" {print "listener: "$4}' || true
  fi
  printf 'Security: IP camera is disabled by default. Local mode binds only 127.0.0.1; LAN mode accepts private/link-local peers only.\n'
  printf 'Transport is HTTP Basic and is not encrypted; for remote/untrusted networks use a VPN or TLS reverse proxy.\n'
}

show_ip_credentials_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local cfg=/etc/kinect360-remold/remold.conf user pass
  [[ -r "$cfg" ]] || { printf 'IP camera configuration is not installed.\n' >&2; return 1; }
  user="$(awk -F= '$1=="ip.user"{sub(/^[^=]*=/,"");print;exit}' "$cfg")"
  pass="$(awk -F= '$1=="ip.password"{sub(/^[^=]*=/,"");print;exit}' "$cfg")"
  [[ -n "$user" && -n "$pass" ]] || { printf 'IP camera credentials are incomplete.\n' >&2; return 1; }
  printf 'IP camera credentials (administrator-only): %s / %s\n' "$user" "$pass"
}

replace_config_value(){
  local key="$1" value="$2" cfg=/etc/kinect360-remold/remold.conf tmp
  [[ -f "$cfg" ]] || { printf 'IP camera configuration is not installed.\n' >&2; return 1; }
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  awk -v key="$key" -v value="$value" '
    BEGIN{done=0}
    index($0,key"=")==1 {print key"="value;done=1;next}
    {print}
    END{if(!done)print key"="value}
  ' "$cfg" > "$tmp"
  local cfg_group=kinect360-remold-ip; getent group "$cfg_group" >/dev/null 2>&1 || cfg_group=root
  install -o root -g "$cfg_group" -m 0640 "$tmp" "$cfg"
  rm -f "$tmp"
  trap - RETURN
}

reset_ip_password_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local pass
  pass="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
  [[ ${#pass} -ge 48 ]] || { printf 'Could not generate a strong random password.\n' >&2; return 1; }
  replace_config_value ip.password "$pass"
  if systemctl is-active --quiet kinect360-remold-camera-ip.service 2>/dev/null; then
    systemctl restart kinect360-remold-camera-ip.service
  fi
  printf 'IP camera password rotated.\n'
  show_ip_credentials_root
}

set_ip_mode_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local mode="${1:-local}" bind
  case "$mode" in
    local) bind=127.0.0.1 ;;
    lan) bind=0.0.0.0 ;;
    *) printf 'Unknown IP camera mode: %s\n' "$mode" >&2; return 2 ;;
  esac
  replace_config_value ip.bind "$bind"
  if systemctl is-active --quiet kinect360-remold-camera-ip.service 2>/dev/null; then
    systemctl restart kinect360-remold-camera-ip.service
  fi
  if [[ "$mode" == lan ]]; then
    printf 'IP camera network mode: LAN (private/link-local peers only).\n'
    printf 'WARNING: HTTP Basic is unencrypted. Use LAN mode only on a trusted network or behind a VPN/TLS reverse proxy.\n'
  else
    printf 'IP camera network mode: LOCAL ONLY (127.0.0.1).\n'
  fi
}

set_ip_device_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local id="${1:-}" manifest=/run/kinect360-remold/devices.tsv
  if [[ -z "$id" && -r "$manifest" ]]; then id="$(awk -F '\t' '$1 !~ /^#/ && $3=="Ready" && $5!="" {print $1;exit}' "$manifest")"; fi
  [[ -n "$id" ]] || { printf 'No Ready Kinect deviceId is available to bind.\n' >&2; return 1; }
  [[ "$id" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || { printf 'Invalid deviceId.\n' >&2; return 2; }
  replace_config_value ip.device_id "$id"
  if systemctl is-active --quiet kinect360-remold-camera-ip.service 2>/dev/null; then systemctl restart kinect360-remold-camera-ip.service; fi
  printf 'IP camera source pinned to Kinect %s. It will not silently switch to another Kinect.\n' "$id"
}

ip_toggle_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local cfg=/etc/kinect360-remold/remold.conf current=false next=true
  [[ -f "$cfg" ]] || { printf 'IP camera configuration is not installed.\n' >&2; return 1; }
  current="$(awk -F= '$1=="ip.enabled"{gsub(/[[:space:]]/,"",$2);print tolower($2);exit}' "$cfg")"
  [[ "$current" == true || "$current" == 1 ]] && next=false
  if [[ "$next" == true ]]; then
    local configured_id manifest_id
    configured_id="$(awk -F= '$1=="ip.device_id"{sub(/^[^=]*=/,"");print;exit}' "$cfg")"
    if [[ -z "$configured_id" && -r /run/kinect360-remold/devices.tsv ]]; then
      manifest_id="$(awk -F '\t' '$1 !~ /^#/ && $3=="Ready" && $5!="" {print $1;exit}' /run/kinect360-remold/devices.tsv)"
      if [[ -n "$manifest_id" ]]; then replace_config_value ip.device_id "$manifest_id"; printf 'IP camera source pinned to Kinect %s.\n' "$manifest_id"; fi
    fi
  fi
  replace_config_value ip.enabled "$next"
  if [[ "$next" == true ]]; then
    systemctl enable --now kinect360-remold-camera-ip.service
    printf 'IP camera enabled. Current bind mode is preserved; check option 6 before exposing it.\n'
  else
    systemctl disable --now kinect360-remold-camera-ip.service 2>/dev/null || true
    printf 'IP camera disabled.\n'
  fi
}

find_studio(){
  local candidates=(
    "$ROOT/../../binaries/linux/applications/SynKinectStudio/SynKinectStudio.sh"
    "$ROOT/../applications/SynKinectStudio/SynKinectStudio.sh"
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
    printf 'Expected binaries/linux/applications/SynKinectStudio/SynKinectStudio.sh.\n' >&2
    return 1
  fi
  chmod +x "$studio" 2>/dev/null || true
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    user="$(caller_user)"
    [[ -n "$user" && "$user" != root ]] || { printf 'Refusing to start SynKinect Studio as root; launch it from the desktop user session.\n' >&2; return 1; }
    uid="$(id -u "$user")"
    runtime_dir="/run/user/$uid"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$user" -- env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}" bash "$studio" || return $?
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$user" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}" bash "$studio" || return $?
    else
      printf 'Cannot drop root privileges because neither runuser nor sudo is available.\n' >&2
      return 1
    fi
  else
    bash "$studio" || return $?
  fi
  printf 'SynKinect Studio opened as the standard desktop user: %s\n' "$studio"
}

run_action(){
  case "$1" in
    Install) header; printf 'Installation is offline and will request administrator permission only for local system changes.\n'; run_root bash "$ROOT/INSTALL.sh" ;;
    Status) header; show_status ;;
    OpenCamera) header; open_camera ;;
    Tilt) header; set_tilt ;;
    StartupTilt) header; startup_tilt ;;
    RgbHqStatus) header; rgb_hq_action status ;;
    RgbHqOn) header; rgb_hq_action on ;;
    RgbHqOff) header; rgb_hq_action off ;;
    RgbHqToggle) header; rgb_hq_toggle ;;
    IpStatus) header; show_ip_status ;;
    IpCredentials) header; printf 'Showing IP-camera credentials requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-credentials ;;
    IpReset) header; printf 'Resetting the protected IP-camera password requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-reset ;;
    IpLocal) header; printf 'Switching IP camera to local-only mode requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-mode local ;;
    IpLan) header; printf 'Switching IP camera to LAN mode requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-mode lan ;;
    IpDevice) header; printf 'Binding IP camera to a Kinect requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-device "$DEVICE_ID" ;;
    IpToggle) header; printf 'Changing the IP-camera service requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-toggle ;;
    OpenStudio) header; open_studio ;;
    Restart) header; printf 'Restarting the Kinect runtime requires administrator permission.\n'; run_root systemctl restart kinect360-remold.target; show_status ;;
    Uninstall) header; printf 'Type REMOVE to confirm: '; IFS= read -r confirm || true; if [[ "$confirm" == REMOVE ]]; then run_root bash "$ROOT/UNINSTALL.sh"; else printf 'Canceled.\n'; fi ;;
    *) printf 'Unknown action: %s\n' "$1" >&2; return 2 ;;
  esac
}

# Private root-only entry points used after sudo/pkexec. They never launch Studio.
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-credentials" ]]; then show_ip_credentials_root; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-reset" ]]; then reset_ip_password_root; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-mode" ]]; then set_ip_mode_root "${2:-local}"; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-device" ]]; then set_ip_device_root "${2:-}"; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-toggle" ]]; then ip_toggle_root; exit $?; fi

if [[ "$ACTION" != Menu ]]; then
  run_action "$ACTION"
  exit $?
fi

while true; do
  header
  printf '%s\n' \
    '1  Install / Reinstall' \
    '2  Status' \
    '3  Open / show virtual camera device (RGB only)' \
    '4  Set manual Tilt' \
    "5  Return Tilt to startup pose ($(printf '%+d' "$(startup_tilt_degrees)") degrees)" \
    '6  RGB HQ' \
    '7  Show IP camera status / URLs (credentials hidden)' \
    '8  Show IP camera credentials (administrator)' \
    '9  Reset IP camera password' \
    '10 Set IP camera LOCAL ONLY (127.0.0.1)' \
    '11 Set IP camera LAN PRIVATE mode' \
    '12 Bind IP camera to selected Kinect (administrator)' \
    '13 Enable / Disable IP camera' \
    '14 Open SynKinect Studio' \
    '15 Restart Kinect runtime (administrator)' \
    '16 Uninstall' \
    '0  Exit'
  printf '\nChoose: '
  IFS= read -r choice || exit 0
  case "${choice//[[:space:]]/}" in
    1) run_action Install || true; pause_menu ;;
    2) run_action Status; pause_menu ;;
    3) run_action OpenCamera || true; pause_menu ;;
    4) run_action Tilt || true; pause_menu ;;
    5) run_action StartupTilt || true; pause_menu ;;
    6) run_action RgbHqToggle || true; pause_menu ;;
    7) run_action IpStatus; pause_menu ;;
    8) run_action IpCredentials || true; pause_menu ;;
    9) run_action IpReset || true; pause_menu ;;
    10) run_action IpLocal || true; pause_menu ;;
    11) run_action IpLan || true; pause_menu ;;
    12) run_action IpDevice || true; pause_menu ;;
    13) run_action IpToggle || true; pause_menu ;;
    14) if run_action OpenStudio; then exit 0; else sleep 0.5; fi ;;
    15) run_action Restart || true; pause_menu ;;
    16) run_action Uninstall || true; pause_menu ;;
    0) exit 0 ;;
    *) printf 'Invalid option.\n'; sleep 0.7 ;;
  esac
done
