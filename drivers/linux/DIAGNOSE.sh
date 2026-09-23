#!/usr/bin/env bash
set -uo pipefail

section(){ printf '\n============================================================\n%s\n============================================================\n' "$1"; }
read_hex(){ [[ -r "$1" ]] && tr '[:lower:]' '[:upper:]' < "$1" 2>/dev/null || true; }
classify(){
  local pid="${1^^}" bcd="${2^^}"
  case "$pid" in
    02AE) [[ "$bcd" == 010B ]] && printf 'Xbox 360 model 1414 camera' || printf 'Xbox 360 model 1473 camera' ;;
    02B0) printf '1414 dedicated motor/control' ;;
    02C2) printf '1473 parent USB hub/controller (must not be claimed/reset)' ;;
    02AD) printf 'Kinect audio bootloader (UAC firmware pending)' ;;
    02BB|02C3) printf 'Kinect UAC runtime composite (MI_00 control on 1473; MI_02 audio)' ;;
    *) printf 'other Microsoft USB function' ;;
  esac
}

section 'Kinect Xbox 360 Remold - Linux diagnostics'
printf 'date=%s\n' "$(date -Is 2>/dev/null || date)"
printf 'kernel=%s\n' "$(uname -a)"
printf 'user=%s uid=%s\n' "$(id -un)" "$(id -u)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf 'installed_version=%s\n' "$(cat /usr/share/kinect360-remold/VERSION 2>/dev/null || printf 'not installed')"
printf 'installed_build=%s\n' "$(cat /usr/share/kinect360-remold/BUILD-FINGERPRINT 2>/dev/null || printf 'unknown')"
printf 'built_kernel=%s\n' "$(cat /usr/share/kinect360-remold/KERNEL-RELEASE 2>/dev/null || printf 'unknown')"
printf 'v4l2loopback_built_version=%s\n' "$(cat /usr/share/kinect360-remold/V4L2LOOPBACK-VERSION 2>/dev/null || printf 'unknown')"
printf 'v4l2loopback_source_sha256=%s\n' "$(cat /usr/share/kinect360-remold/V4L2LOOPBACK-SOURCE-SHA256 2>/dev/null || printf 'unknown')"
printf 'v4l2loopback_module_sha256=%s\n' "$(cat /usr/share/kinect360-remold/V4L2LOOPBACK-MODULE-SHA256 2>/dev/null || printf 'unknown')"
for fingerprint in "$HERE/FINGERPRINT.sh" "$HERE/../../../drivers/linux/FINGERPRINT.sh"; do
  if [[ -f "$fingerprint" ]]; then
    source_build="$(bash "$fingerprint" 2>/dev/null || true)"
    printf 'source_build=%s\n' "$source_build"
    if [[ "$source_build" == "$(cat /usr/share/kinect360-remold/BUILD-FINGERPRINT 2>/dev/null)" ]]; then
      printf 'installed runtime matches the current driver sources\n'
    else
      printf 'WARNING: installed runtime was NOT built from the current driver sources; run bash Kinect-Xbox-360-Remold.sh --build-only, then Install\n'
    fi
    break
  fi
done
if command -v lsmod >/dev/null 2>&1 && lsmod | grep -q '^gspca_kinect'; then
  printf 'WARNING: kernel module gspca_kinect is loaded and competes for the Kinect camera; reinstall or run: sudo modprobe -r gspca_kinect\n'
fi

owned_v4l2="$(cat /usr/share/kinect360-remold/v4l2loopback-owned-path 2>/dev/null || true)"
if [[ -n "$owned_v4l2" && -f "$owned_v4l2" && -r /usr/share/kinect360-remold/V4L2LOOPBACK-MODULE-SHA256 ]]; then
  expected_module_sha="$(tr -d '[:space:]' </usr/share/kinect360-remold/V4L2LOOPBACK-MODULE-SHA256 | tr '[:upper:]' '[:lower:]')"
  actual_module_sha="$(sha256sum "$owned_v4l2" 2>/dev/null | awk '{print tolower($1)}')"
  if [[ -n "$actual_module_sha" && "$actual_module_sha" == "$expected_module_sha" ]]; then
    printf 'installed v4l2loopback integrity: PASS (%s)\n' "$owned_v4l2"
  else
    printf 'WARNING: installed v4l2loopback integrity mismatch: %s\n' "$owned_v4l2"
  fi
fi

section 'USB model/topology'
found=0
for d in /sys/bus/usb/devices/*; do
  [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
  vid="$(read_hex "$d/idVendor")"; [[ "$vid" == 045E ]] || continue
  pid="$(read_hex "$d/idProduct")"; bcd="$(read_hex "$d/bcdDevice")"
  case "$pid" in 02AE|02B0|02C2|02AD|02BB|02C3) ;; *) continue ;; esac
  found=1
  printf '%-16s VID:PID=045E:%s bcd=%-4s driver=%-18s %s\n' \
    "$(basename "$d")" "$pid" "${bcd:-????}" \
    "$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true)" \
    "$(classify "$pid" "$bcd")"
done
(( found )) || printf 'No supported Kinect 1414/1473 USB functions found in sysfs.\n'

if command -v lsusb >/dev/null 2>&1; then
  printf '\nlsusb 045e:\n'; lsusb -d 045e: 2>&1 || true
  printf '\nlsusb tree:\n'; lsusb -t 2>&1 || true
fi

section 'ALSA Kinect capture'
if command -v arecord >/dev/null 2>&1; then arecord -l 2>&1 || true; else printf 'arecord not installed.\n'; fi
[[ -r /proc/asound/cards ]] && cat /proc/asound/cards || true
for card in /proc/asound/card[0-9]*; do
  usbid="$(cat "$card/usbid" 2>/dev/null || true)"
  case "${usbid,,}" in
    045e:02bb|045e:02c3)
      printf '\n--- %s (%s) ---\n' "$card" "$usbid"
      cat "$card"/stream* 2>/dev/null || true
      ;;
  esac
done

section 'Remold runtime'
if command -v systemctl >/dev/null 2>&1; then
  for unit in broker camera audio v4l2 sdk; do
    printf '%-34s ' "kinect360-remold-$unit.service"
    systemctl is-active "kinect360-remold-$unit.service" 2>/dev/null || true
  done
fi
if command -v kinect360-remoldctl >/dev/null 2>&1; then
  printf '\nkinect360-remoldctl status:\n'; kinect360-remoldctl status 2>&1 || true
fi
for f in /run/kinect360-remold/devices.tsv /run/kinect360-remold/audio-bridge-status.txt; do
  if [[ -r "$f" ]]; then printf '\n--- %s ---\n' "$f"; cat "$f"; fi
done

section 'Camera self-test (ScannerPort, same path as Studio and V4L2)'
if command -v kinect360-remoldctl >/dev/null 2>&1 && [[ -r /run/kinect360-remold/devices.tsv ]]; then
  while IFS=$'\t' read -r id label state _control camera _rest; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    printf '\n%s (%s) state=%s\n' "$label" "$id" "$state"
    [[ -n "$camera" ]] || { printf '  camera endpoint not published\n'; continue; }
    kinect360-remoldctl --device "$id" probe rgb+depth 5 2>&1 || true
    kinect360-remoldctl --device "$id" probe ir 4 2>&1 || true
  done </run/kinect360-remold/devices.tsv
else
  printf 'kinect360-remoldctl or devices.tsv not available.\n'
fi

section 'Virtual cameras'
cat /run/kinect360-remold/virtual-cameras.tsv 2>/dev/null || printf 'virtual-cameras.tsv not published\n'
ls -l /dev/video* 2>/dev/null || true
if command -v lsmod >/dev/null 2>&1; then lsmod | grep -E '^(v4l2loopback|gspca_kinect|gspca_main)' || true; fi
modinfo -F version v4l2loopback 2>/dev/null | sed 's/^/v4l2loopback version: /' || true
if command -v v4l2-ctl >/dev/null 2>&1; then v4l2-ctl --list-devices 2>&1 || true; fi

section 'Recent service logs'
if command -v journalctl >/dev/null 2>&1; then
  for unit in broker camera audio v4l2; do
    printf '\n--- kinect360-remold-%s.service ---\n' "$unit"
    journalctl --no-pager -n 120 -u "kinect360-remold-$unit.service" 2>&1 || true
  done
else
  printf 'journalctl not available.\n'
fi
