#!/usr/bin/env bash
set -euo pipefail
if [[ "${REMOLD_GUI:-0}" != 1 ]]; then
  printf '%s\n' '============================================================'
  printf '%s\n' ' Kinect Remold'
  printf '%s\n' ' by Douglas Santana - @spidoug'
  printf '%s\n' '============================================================'
  printf '%s\n' ' Control panel - Linux'
  printf '\n'
fi
stage(){ printf '%s\n' "$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_HELPER="${REMOLD_ENV_HELPER:-}"
for candidate in "$HERE/remold-env.sh" "$HERE/kinect-remold-env.sh"; do [[ -n "$ENV_HELPER" ]] || { [[ -r "$candidate" ]] && ENV_HELPER="$candidate"; }; done
if [[ -z "$ENV_HELPER" ]]; then scan="$HERE"; for _ in {1..12}; do candidate="$scan/scripts/linux/lib/remold-env.sh"; [[ -r "$candidate" ]] && { ENV_HELPER="$candidate"; break; }; parent="$(dirname "$scan")"; [[ "$parent" != "$scan" ]] || break; scan="$parent"; done; fi
[[ -r "$ENV_HELPER" ]] || { echo 'Kinect Remold environment resolver was not found.' >&2; exit 2; }
source "$ENV_HELPER"
remold_install_paths || { echo 'Could not resolve Linux installation directories.' >&2; exit 2; }
MODULE_ID='kinect-one-remold'
RUNTIME_DIR="$REMOLD_LIBEXECDIR/$MODULE_ID"
DATA_DIR="$REMOLD_DATADIR/$MODULE_ID"
RUN_DIR="$REMOLD_RUNDIR/$MODULE_ID"
SERVICE_PATH="$REMOLD_SYSTEMD_UNIT_DIR/kinect-one-remold.service"
RULE_PATH="$REMOLD_UDEV_RULES_DIR/90-kinect-one-remold.rules"
CONTROL_PATH="$REMOLD_BINDIR/kinect-one-remoldctl"

stage '[1/4] Stopping and removing runtime service...'
systemctl disable --now kinect-one-remold.service 2>/dev/null || true
systemctl stop kinect-one-remold.service 2>/dev/null || true
systemctl kill --kill-who=all --signal=TERM kinect-one-remold.service 2>/dev/null || true
sleep 0.20
if systemctl is-active --quiet kinect-one-remold.service 2>/dev/null; then
  systemctl kill --kill-who=all --signal=KILL kinect-one-remold.service 2>/dev/null || true
fi
if command -v pkill >/dev/null 2>&1; then
  pkill -TERM -f "^$RUNTIME_DIR/kinect-one-remold$" 2>/dev/null || true
  sleep 0.05
  pkill -KILL -f "^$RUNTIME_DIR/kinect-one-remold$" 2>/dev/null || true
fi

remove_tree_bounded(){
  local path="$1" label="$2" attempt
  [[ -e "$path" ]] || return 0
  for attempt in 1 2 3 4; do
    rm -rf -- "$path" 2>/dev/null || true
    [[ ! -e "$path" ]] && return 0
    sleep "0.$((attempt*2))"
  done
  printf 'WARNING: %s remains in use: %s. A reboot may be required to finish cleanup.\n' "$label" "$path" >&2
  return 1
}

stage '[2/4] Removing Kinect Remold - Xbox One device access policy...'
rm -f -- "$SERVICE_PATH"
rm -f -- "$RULE_PATH"
rm -f -- "$CONTROL_PATH"
stage '[3/4] Removing persistent runtime files...'
remove_tree_bounded "$RUNTIME_DIR" 'Runtime folder' || true
remove_tree_bounded "$DATA_DIR" 'Runtime data folder' || true
remove_tree_bounded "$RUN_DIR" 'Runtime state folder' || true
systemctl daemon-reload
systemctl reset-failed kinect-one-remold.service 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=045e 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

stage '[4/4] Verifying removal...'
if systemctl cat kinect-one-remold.service >/dev/null 2>&1 || [[ -e "$RUNTIME_DIR" || -e "$DATA_DIR" ]]; then
  echo 'Kinect Remold - Xbox One removal is incomplete.' >&2; exit 3
fi
if [[ ! -e "$REMOLD_BINDIR/kinect360-remoldctl" ]]; then rm -f -- "$REMOLD_BINDIR/kinect-remold-env.sh"; fi
echo 'Runtime service: NOT INSTALLED'
