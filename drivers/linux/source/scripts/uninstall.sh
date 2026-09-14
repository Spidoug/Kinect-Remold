#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
systemctl disable --now kinect360-remold.target 2>/dev/null || true
rm -f /etc/systemd/system/kinect360-remold*.service /etc/systemd/system/kinect360-remold.target
rm -f /etc/udev/rules.d/60-kinect360-remold.rules /etc/modprobe.d/kinect360-remold-v4l2.conf /etc/modules-load.d/kinect360-remold.conf
rm -f /usr/bin/kinect360-remoldctl
rm -rf /usr/libexec/kinect360-remold /usr/share/kinect360-remold
systemctl daemon-reload; udevadm control --reload-rules
rm -rf /run/kinect360-remold
# model.conf is generated installation state, not a user preference.
rm -f /etc/kinect360-remold/model.conf
echo 'Kinect Xbox 360 Remold Linux runtime removed. User settings in /etc/kinect360-remold/remold.conf were preserved.'
