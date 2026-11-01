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
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_HELPER="${REMOLD_ENV_HELPER:-}"
for candidate in "$HERE/remold-env.sh" "$HERE/kinect-remold-env.sh"; do [[ -n "$ENV_HELPER" ]] || { [[ -r "$candidate" ]] && ENV_HELPER="$candidate"; }; done
if [[ -z "$ENV_HELPER" ]]; then scan="$HERE"; for _ in {1..16}; do candidate="$scan/scripts/linux/lib/remold-env.sh"; [[ -r "$candidate" ]] && { ENV_HELPER="$candidate"; break; }; parent="$(dirname "$scan")"; [[ "$parent" != "$scan" ]] || break; scan="$parent"; done; fi
[[ -r "$ENV_HELPER" ]] || { echo 'Kinect Remold environment resolver was not found.' >&2; exit 2; }
source "$ENV_HELPER"
remold_install_paths || { echo 'Could not resolve Linux installation directories.' >&2; exit 2; }
MODULE_ID='kinect360-remold'
LIBEXEC_DIR="$REMOLD_LIBEXECDIR/$MODULE_ID"
DATA_DIR="$REMOLD_DATADIR/$MODULE_ID"
STATE_DIR="$REMOLD_LOCALSTATEDIR/$MODULE_ID"
RUN_DIR="$REMOLD_RUNDIR/$MODULE_ID"
CONFIG_DIR="$REMOLD_SYSCONFDIR/$MODULE_ID"
CONTROL_PATH="$REMOLD_BINDIR/kinect360-remoldctl"
MODPROBE_DIR="$REMOLD_SYSCONFDIR/modprobe.d"
MODULES_LOAD_DIR="$REMOLD_SYSCONFDIR/modules-load.d"
KERNEL_MODULES_ROOT="$(remold_kernel_modules_root "$(uname -r)" 2>/dev/null || true)"
LINUX_CONFIG=''
for candidate in "$HERE/linux.env" "$DATA_DIR/linux.env"; do [[ -r "$candidate" ]] && { LINUX_CONFIG="$candidate"; break; }; done
if [[ -n "$LINUX_CONFIG" ]]; then while IFS='=' read -r key value; do [[ "$key" =~ ^REMOLD_[A-Z0-9_]+$ ]] || continue; [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$value"; done < "$LINUX_CONFIG"; fi
IP_SERVICE_USER="${REMOLD_K360_IP_SERVICE_USER:-$MODULE_ID-ip}"

OWNED_V4L2="$(cat "$DATA_DIR/v4l2loopback-owned-path" 2>/dev/null || true)"

RUNTIME_UNITS=(
  kinect360-remold-broker.service
  kinect360-remold-camera.service
  kinect360-remold-audio.service
  kinect360-remold-v4l2.service
  kinect360-remold-camera-ip.service
)

systemctl disable --now kinect360-remold-camera-ip.service 2>/dev/null || true
systemctl disable --now kinect360-remold.target 2>/dev/null || true
for unit in "${RUNTIME_UNITS[@]}"; do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl kill --kill-who=all --signal=TERM "$unit" 2>/dev/null || true
done
systemctl stop kinect360-remold.target 2>/dev/null || true
sleep 0.25
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

# A second sweep closes helpers that may have been respawned while devices were
# being detached. This mirrors the Windows bounded teardown semantics.
if command -v pkill >/dev/null 2>&1; then
  pkill -TERM -f "^$LIBEXEC_DIR/" 2>/dev/null || true
  sleep 0.10
  pkill -KILL -f "^$LIBEXEC_DIR/" 2>/dev/null || true
fi

remove_tree_bounded() {
  local path="$1" label="$2" attempt
  [[ -e "$path" ]] || return 0
  for attempt in 1 2 3 4; do
    rm -rf -- "$path" 2>/dev/null || true
    [[ ! -e "$path" ]] && return 0
    sleep "0.$((attempt * 2))"
  done
  printf 'WARNING: %s remains in use: %s. A reboot may be required to finish cleanup.\n' "$label" "$path" >&2
  return 1
}

# Remove the virtual-camera kernel module while its ownership marker still
# exists. Only a module installed by this project is deleted.
modprobe -r v4l2loopback 2>/dev/null || true
modprobe -r snd-aloop 2>/dev/null || true
if [[ -n "$KERNEL_MODULES_ROOT" && "$OWNED_V4L2" == "$KERNEL_MODULES_ROOT"/*/updates/kinect360-remold/v4l2loopback.ko && -f "$OWNED_V4L2" ]]; then
  OWNED_KERNEL="${OWNED_V4L2#${KERNEL_MODULES_ROOT}/}"
  OWNED_KERNEL="${OWNED_KERNEL%%/*}"
  rm -f "$OWNED_V4L2"
  rmdir "$(dirname "$OWNED_V4L2")" 2>/dev/null || true
  depmod -a "$OWNED_KERNEL" 2>/dev/null || true
fi

rm -f -- "$REMOLD_SYSTEMD_UNIT_DIR"/kinect360-remold*.service "$REMOLD_SYSTEMD_UNIT_DIR/kinect360-remold.target"
rm -rf -- "$REMOLD_SYSTEMD_UNIT_DIR"/kinect360-remold*.service.d "$REMOLD_SYSTEMD_UNIT_DIR/kinect360-remold.target.d"
rm -f -- "$REMOLD_UDEV_RULES_DIR/60-kinect360-remold.rules"
rm -f -- "$MODPROBE_DIR/kinect360-remold-v4l2.conf" "$MODPROBE_DIR/kinect360-remold-camera.conf" "$MODPROBE_DIR/kinect360-remold-audio.conf" "$MODULES_LOAD_DIR/kinect360-remold.conf"
rm -f -- "$CONTROL_PATH"
remove_tree_bounded "$LIBEXEC_DIR" 'Runtime folder' || true
remove_tree_bounded "$DATA_DIR" 'Runtime data folder' || true
remove_tree_bounded "$RUN_DIR" 'Runtime state folder' || true
remove_tree_bounded "$STATE_DIR" 'Persistent runtime folder' || true
remove_tree_bounded "$CONFIG_DIR" 'Runtime configuration folder' || true

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
# Restore the stock Linux Kinect camera driver after removing the Remold blacklist.
modprobe gspca_kinect 2>/dev/null || true
udevadm trigger --subsystem-match=usb 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

if id -u "$IP_SERVICE_USER" >/dev/null 2>&1; then userdel "$IP_SERVICE_USER" 2>/dev/null || true; fi
if getent group "$IP_SERVICE_USER" >/dev/null 2>&1; then groupdel "$IP_SERVICE_USER" 2>/dev/null || true; fi

if [[ ! -e "$REMOLD_BINDIR/kinect-one-remoldctl" ]]; then rm -f -- "$REMOLD_BINDIR/kinect-remold-env.sh"; fi
echo 'Kinect Remold — Xbox 360 removed.'
