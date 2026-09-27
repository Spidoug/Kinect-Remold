#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '============================================================'
printf '%s\n' ' Kinect One Remold - driver installation'
printf '%s\n' ' by Douglas Santana - @spidoug'
printf '%s\n' '============================================================'
printf '\n'

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Accept either the prepared distribution bundle or a source-tree invocation.
if [[ -x "$HERE/kinect-one-remold" && -f "$HERE/90-kinect-one-remold.rules" && -f "$HERE/kinect-one-remold.service" ]]; then
  BUNDLE="$HERE"
else
  PROJECT="$HERE"
  for _ in {1..12}; do
    if [[ -f "$PROJECT/VERSION" && -d "$PROJECT/drivers" && -d "$PROJECT/applications" ]]; then break; fi
    parent="$(dirname "$PROJECT")"; [[ "$parent" != "$PROJECT" ]] || break; PROJECT="$parent"
  done
  BUNDLE="$PROJECT/binaries/linux/drivers/kinect-one-remold"
fi

BIN="$BUNDLE/kinect-one-remold"
RULE="$BUNDLE/90-kinect-one-remold.rules"
SERVICE="$BUNDLE/kinect-one-remold.service"
UNINSTALL="$BUNDLE/UNINSTALL.sh"
CONTROL="$BUNDLE/KINECT.sh"

for command_name in cmp install mkdir rm sha256sum sleep systemctl udevadm; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Installation prerequisite is missing: $command_name" >&2; exit 2; }
done
[[ -x "$BIN" ]] || { echo 'Built Kinect One runtime is missing. Build the module first.' >&2; exit 2; }
[[ -f "$RULE" ]] || { echo 'Kinect One udev rule is missing.' >&2; exit 2; }
[[ -f "$SERVICE" ]] || { echo 'Kinect One systemd unit is missing.' >&2; exit 2; }
[[ -f "$UNINSTALL" ]] || { echo 'Kinect One uninstall helper is missing.' >&2; exit 2; }
[[ -f "$CONTROL" ]] || { echo 'Kinect One control helper is missing.' >&2; exit 2; }

# Stop the service before replacing the installed runtime.
systemctl disable --now kinect-one-remold.service 2>/dev/null || true
systemctl stop kinect-one-remold.service 2>/dev/null || true
systemctl kill --kill-who=all --signal=TERM kinect-one-remold.service 2>/dev/null || true
sleep 0.10
if systemctl is-active --quiet kinect-one-remold.service 2>/dev/null; then
  systemctl kill --kill-who=all --signal=KILL kinect-one-remold.service 2>/dev/null || true
fi

install -d -m 0755 /usr/libexec/kinect-one-remold /usr/share/kinect-one-remold/maintenance
install -m 0755 "$BIN" /usr/libexec/kinect-one-remold/kinect-one-remold
# Keep a self-contained maintenance snapshot outside the repository, mirroring
# the installed-runtime model used by Kinect Xbox 360 Remold. When Repair is
# invoked from that installed snapshot, do not copy files onto themselves.
if [[ "$BUNDLE" != /usr/share/kinect-one-remold/maintenance ]]; then
  install -m 0755 "$BIN" /usr/share/kinect-one-remold/maintenance/kinect-one-remold
  install -m 0755 "$BUNDLE/INSTALL.sh" /usr/share/kinect-one-remold/maintenance/INSTALL.sh
  install -m 0755 "$CONTROL" /usr/share/kinect-one-remold/maintenance/KINECT.sh
  install -m 0755 "$UNINSTALL" /usr/share/kinect-one-remold/maintenance/UNINSTALL.sh
  install -m 0644 "$RULE" /usr/share/kinect-one-remold/maintenance/90-kinect-one-remold.rules
  install -m 0644 "$SERVICE" /usr/share/kinect-one-remold/maintenance/kinect-one-remold.service
fi
install -m 0755 "$CONTROL" /usr/bin/kinect-one-remoldctl
install -m 0644 "$RULE" /etc/udev/rules.d/90-kinect-one-remold.rules
install -m 0644 "$SERVICE" /etc/systemd/system/kinect-one-remold.service

verify_file(){
  local source="$1" installed="$2"
  cmp -s "$source" "$installed" || { echo "Installed runtime verification failed: $installed" >&2; exit 3; }
}
verify_file "$BIN" /usr/libexec/kinect-one-remold/kinect-one-remold
verify_file "$RULE" /etc/udev/rules.d/90-kinect-one-remold.rules
verify_file "$SERVICE" /etc/systemd/system/kinect-one-remold.service
verify_file "$CONTROL" /usr/bin/kinect-one-remoldctl

# A service must never point back into the repository/build tree.
exec_start="$(awk -F= '$1=="ExecStart"{print $2;exit}' /etc/systemd/system/kinect-one-remold.service)"
[[ "$exec_start" == /usr/libexec/kinect-one-remold/kinect-one-remold ]] || {
  echo "Unsafe Kinect One service path: $exec_start" >&2
  exit 3
}

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=045e 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true
systemctl enable kinect-one-remold.service
systemctl restart kinect-one-remold.service

printf '\nVerifying Kinect One Remold status...\n'
if systemctl is-active --quiet kinect-one-remold.service; then
  printf '%s\n' 'Runtime service: RUNNING'
else
  printf '%s\n' 'Runtime service: NOT RUNNING' >&2
  systemctl --no-pager --full status kinect-one-remold.service || true
  exit 1
fi
if [[ -S /run/kinect-one-remold/sdk.sock ]]; then
  printf '%s\n' 'SDK socket: READY'
else
  printf '%s\n' 'SDK socket: NOT READY (no active Kinect One session yet)'
fi
printf 'Runtime path: /usr/libexec/kinect-one-remold/kinect-one-remold\n'
printf 'Source/repository tree is not required by the running service.\n'
