#!/usr/bin/env bash
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

OWNED_V4L2="$(cat /usr/share/kinect360-remold/v4l2loopback-owned-path 2>/dev/null || true)"

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

# Remove the virtual-camera kernel module while its ownership marker still
# exists. Only a module installed by this project is deleted.
modprobe -r v4l2loopback 2>/dev/null || true
if [[ "$OWNED_V4L2" == /lib/modules/*/updates/kinect360-remold/v4l2loopback.ko && -f "$OWNED_V4L2" ]]; then
  OWNED_KERNEL="${OWNED_V4L2#/lib/modules/}"
  OWNED_KERNEL="${OWNED_KERNEL%%/*}"
  rm -f "$OWNED_V4L2"
  rmdir "$(dirname "$OWNED_V4L2")" 2>/dev/null || true
  depmod -a "$OWNED_KERNEL" 2>/dev/null || true
fi

rm -f /etc/systemd/system/kinect360-remold*.service /etc/systemd/system/kinect360-remold.target
rm -rf /etc/systemd/system/kinect360-remold*.service.d /etc/systemd/system/kinect360-remold.target.d
rm -f /etc/udev/rules.d/60-kinect360-remold.rules
rm -f /etc/modprobe.d/kinect360-remold-v4l2.conf /etc/modprobe.d/kinect360-remold-camera.conf /etc/modules-load.d/kinect360-remold.conf
rm -f /usr/bin/kinect360-remoldctl
rm -rf /usr/libexec/kinect360-remold /usr/share/kinect360-remold /run/kinect360-remold /var/lib/kinect360-remold /etc/kinect360-remold

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
# Restore the stock Linux Kinect camera driver after removing the Remold blacklist.
modprobe gspca_kinect 2>/dev/null || true
udevadm trigger --subsystem-match=usb 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

if id -u kinect360-remold-ip >/dev/null 2>&1; then userdel kinect360-remold-ip 2>/dev/null || true; fi
if getent group kinect360-remold-ip >/dev/null 2>&1; then groupdel kinect360-remold-ip 2>/dev/null || true; fi

echo 'Kinect Xbox 360 Remold removed.'
