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
print_banner
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="Status"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="${2:-}"; shift 2 ;;
    --action=*) ACTION="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

run_root(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; return; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return; fi
  if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return; fi
  echo 'Administrator permission is required; neither sudo nor pkexec is available.' >&2
  return 1
}

resolve_helper(){
  local name="$1"
  if [[ -f "$ROOT/$name" ]]; then printf '%s\n' "$ROOT/$name"; return 0; fi
  if [[ -f "/usr/share/kinect-one-remold/maintenance/$name" ]]; then printf '%s\n' "/usr/share/kinect-one-remold/maintenance/$name"; return 0; fi
  return 1
}

show_state(){
  local label="$1" ready="$2" detail="${3:-}" state='NOT READY'
  [[ "$ready" == 1 ]] && state='READY'
  if [[ -n "$detail" ]]; then printf '%-26s : %s - %s\n' "$label" "$state" "$detail"; else printf '%-26s : %s\n' "$label" "$state"; fi
}

device_present(){
  local path vendor product
  for path in /sys/bus/usb/devices/*; do
    [[ -r "$path/idVendor" && -r "$path/idProduct" ]] || continue
    vendor="$(tr '[:upper:]' '[:lower:]' < "$path/idVendor")"; product="$(tr '[:upper:]' '[:lower:]' < "$path/idProduct")"
    [[ "$vendor" == 045e && ( "$product" == 02c4 || "$product" == 02d8 ) ]] && return 0
  done
  return 1
}

show_status(){
  local service_ready=0 service_detail='NOT INSTALLED' path_ready=0 device_ready=0 sdk_ready=0
  if systemctl cat kinect-one-remold.service >/dev/null 2>&1; then
    if systemctl is-active --quiet kinect-one-remold.service; then service_ready=1; service_detail='RUNNING'; else service_detail='STOPPED'; fi
  fi
  [[ -x /usr/libexec/kinect-one-remold/kinect-one-remold ]] && path_ready=1
  device_present && device_ready=1 || true
  [[ -S /run/kinect-one-remold/sdk.sock ]] && sdk_ready=1
  show_state 'Runtime service' "$service_ready" "$service_detail"
  show_state 'Runtime path' "$path_ready" '/usr/libexec/kinect-one-remold/kinect-one-remold'
  show_state 'Device' "$device_ready" "$([[ "$device_ready" == 1 ]] && printf 'detected' || printf 'not detected')"
  show_state 'SDK socket' "$sdk_ready" '/run/kinect-one-remold/sdk.sock'
}

case "${ACTION,,}" in
  install|repair)
    helper="$(resolve_helper INSTALL.sh 2>/dev/null || true)"
    [[ -n "$helper" ]] || { echo 'Kinect One installer was not found in the prepared runtime.' >&2; exit 2; }
    run_root env REMOLD_GUI=1 bash "$helper"
    ;;
  uninstall)
    helper="$(resolve_helper UNINSTALL.sh 2>/dev/null || true)"
    [[ -n "$helper" ]] || { echo 'Kinect One uninstall helper was not found.' >&2; exit 2; }
    run_root env REMOLD_GUI=1 bash "$helper"
    ;;
  start)
    run_root systemctl start kinect-one-remold.service
    ;;
  stop)
    run_root systemctl stop kinect-one-remold.service
    ;;
  detect)
    if device_present; then echo 'Device: detected'; else echo 'Device: not detected'; exit 1; fi
    ;;
  status)
    show_status
    ;;
  *)
    echo "Unsupported Kinect One action: $ACTION" >&2
    exit 2
    ;;
esac
