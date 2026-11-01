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
ENV_HELPER="${REMOLD_ENV_HELPER:-}"
if [[ -z "$ENV_HELPER" ]]; then
  for candidate in "$ROOT/remold-env.sh" "$ROOT/kinect-remold-env.sh"; do [[ -r "$candidate" ]] && { ENV_HELPER="$candidate"; break; }; done
fi
if [[ -z "$ENV_HELPER" ]]; then
  scan="$ROOT"
  for _ in {1..12}; do candidate="$scan/scripts/linux/lib/remold-env.sh"; [[ -r "$candidate" ]] && { ENV_HELPER="$candidate"; break; }; parent="$(dirname "$scan")"; [[ "$parent" != "$scan" ]] || break; scan="$parent"; done
fi
[[ -r "$ENV_HELPER" ]] || { echo 'Kinect Remold environment resolver was not found.' >&2; exit 2; }
source "$ENV_HELPER"
remold_install_paths || { echo 'Could not resolve Linux installation directories.' >&2; exit 2; }
MODULE_ID='kinect-one-remold'
RUNTIME_DIR="$REMOLD_LIBEXECDIR/$MODULE_ID"
DATA_DIR="$REMOLD_DATADIR/$MODULE_ID"
MAINT_DIR="$DATA_DIR/maintenance"
RUN_DIR="$REMOLD_RUNDIR/$MODULE_ID"
SYSFS_ROOT="$(remold_sysfs_root 2>/dev/null || true)"
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
  if [[ -f "$MAINT_DIR/$name" ]]; then printf '%s\n' "$MAINT_DIR/$name"; return 0; fi
  return 1
}

show_state(){
  local label="$1" ready="$2" detail="${3:-}" state='NOT READY'
  [[ "$ready" == 1 ]] && state='READY'
  if [[ -n "$detail" ]]; then printf '%-26s : %s - %s\n' "$label" "$state" "$detail"; else printf '%-26s : %s\n' "$label" "$state"; fi
}

device_present(){
  local path vendor product
  [[ -n "$SYSFS_ROOT" ]] || return 1
  for path in "$SYSFS_ROOT"/bus/usb/devices/*; do
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
  [[ -x "$RUNTIME_DIR/kinect-one-remold" ]] && path_ready=1
  device_present && device_ready=1 || true
  [[ -S "$RUN_DIR/sdk.sock" ]] && sdk_ready=1
  show_state 'Runtime service' "$service_ready" "$service_detail"
  show_state 'Runtime path' "$path_ready" "$RUNTIME_DIR/kinect-one-remold"
  show_state 'Device' "$device_ready" "$([[ "$device_ready" == 1 ]] && printf 'detected' || printf 'not detected')"
  show_state 'SDK socket' "$sdk_ready" "$RUN_DIR/sdk.sock"
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
