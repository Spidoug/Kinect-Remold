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

stage '[1/4] Stopping and removing runtime service...'
systemctl disable --now kinect-one-remold.service 2>/dev/null || true
systemctl stop kinect-one-remold.service 2>/dev/null || true
systemctl kill --kill-who=all --signal=TERM kinect-one-remold.service 2>/dev/null || true
sleep 0.20
if systemctl is-active --quiet kinect-one-remold.service 2>/dev/null; then
  systemctl kill --kill-who=all --signal=KILL kinect-one-remold.service 2>/dev/null || true
fi
if command -v pkill >/dev/null 2>&1; then
  pkill -TERM -f '^/usr/libexec/kinect-one-remold/kinect-one-remold$' 2>/dev/null || true
  sleep 0.05
  pkill -KILL -f '^/usr/libexec/kinect-one-remold/kinect-one-remold$' 2>/dev/null || true
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
rm -f /etc/systemd/system/kinect-one-remold.service
rm -f /etc/udev/rules.d/90-kinect-one-remold.rules
rm -f /usr/bin/kinect-one-remoldctl
stage '[3/4] Removing persistent runtime files...'
remove_tree_bounded /usr/libexec/kinect-one-remold 'Runtime folder' || true
remove_tree_bounded /usr/share/kinect-one-remold 'Runtime data folder' || true
remove_tree_bounded /run/kinect-one-remold 'Runtime state folder' || true
systemctl daemon-reload
systemctl reset-failed kinect-one-remold.service 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=045e 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

stage '[4/4] Verifying removal...'
if systemctl cat kinect-one-remold.service >/dev/null 2>&1 || [[ -e /usr/libexec/kinect-one-remold || -e /usr/share/kinect-one-remold ]]; then
  echo 'Kinect Remold - Xbox One removal is incomplete.' >&2; exit 3
fi
echo 'Runtime service: NOT INSTALLED'
