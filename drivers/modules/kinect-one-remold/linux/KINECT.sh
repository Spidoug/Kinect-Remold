#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '============================================================'
printf '%s\n' ' Kinect One Remold'
printf '%s\n' ' by Douglas Santana - @spidoug'
printf '%s\n' '============================================================'
printf '\n'
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

case "${ACTION,,}" in
  install|repair)
    helper="$(resolve_helper INSTALL.sh 2>/dev/null || true)"
    [[ -n "$helper" ]] || { echo 'Kinect One installer was not found in the prepared runtime.' >&2; exit 2; }
    run_root bash "$helper"
    ;;
  uninstall)
    helper="$(resolve_helper UNINSTALL.sh 2>/dev/null || true)"
    [[ -n "$helper" ]] || { echo 'Kinect One uninstall helper was not found.' >&2; exit 2; }
    run_root bash "$helper"
    ;;
  start)
    run_root systemctl start kinect-one-remold.service
    ;;
  stop)
    run_root systemctl stop kinect-one-remold.service
    ;;
  detect)
    found=0
    for path in /sys/bus/usb/devices/*; do
      [[ -r "$path/idVendor" && -r "$path/idProduct" ]] || continue
      vendor="$(tr '[:upper:]' '[:lower:]' < "$path/idVendor")"
      product="$(tr '[:upper:]' '[:lower:]' < "$path/idProduct")"
      if [[ "$vendor" == 045e && ( "$product" == 02c4 || "$product" == 02d8 ) ]]; then
        printf 'Device: detected (%s:%s)\n' "$vendor" "$product"; found=1
      fi
    done
    (( found )) || { echo 'Device: not detected'; exit 1; }
    ;;
  status)
    status_rc=0
    if systemctl is-active --quiet kinect-one-remold.service; then
      echo 'Runtime service: RUNNING'
    else
      if systemctl cat kinect-one-remold.service >/dev/null 2>&1; then echo 'Runtime service: NOT RUNNING' >&2; else echo 'Runtime service: NOT INSTALLED' >&2; fi
      status_rc=1
    fi
    if systemctl cat kinect-one-remold.service >/dev/null 2>&1; then
      exec_start="$(systemctl show -p ExecStart --value kinect-one-remold.service 2>/dev/null || true)"
      printf 'Runtime image  : %s\n' "${exec_start:-unknown}"
    fi
    if [[ -S /run/kinect-one-remold/sdk.sock ]]; then echo 'SDK socket: READY'; else echo 'SDK socket: NOT READY (no active Kinect One session yet)'; fi
    exit "$status_rc"
    ;;
  *)
    echo "Unsupported Kinect One action: $ACTION" >&2
    exit 2
    ;;
esac
