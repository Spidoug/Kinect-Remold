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
[[ -x "$BIN" ]] || { echo 'Built Kinect Remold Xbox One runtime is missing. Build the module first.' >&2; exit 2; }
[[ -f "$RULE" ]] || { echo 'Kinect Remold Xbox One udev rule is missing.' >&2; exit 2; }
[[ -f "$SERVICE" ]] || { echo 'Kinect Remold Xbox One systemd unit is missing.' >&2; exit 2; }
[[ -f "$UNINSTALL" ]] || { echo 'Kinect One uninstall helper is missing.' >&2; exit 2; }
[[ -f "$CONTROL" ]] || { echo 'Kinect One control helper is missing.' >&2; exit 2; }

stage '[1/4] Installing Kinect Remold - Xbox One runtime files...'
# Stop the service before replacing the installed runtime.
systemctl disable --now kinect-one-remold.service 2>/dev/null || true
systemctl stop kinect-one-remold.service 2>/dev/null || true
systemctl kill --kill-who=all --signal=TERM kinect-one-remold.service 2>/dev/null || true
sleep 0.10
if systemctl is-active --quiet kinect-one-remold.service 2>/dev/null; then
  systemctl kill --kill-who=all --signal=KILL kinect-one-remold.service 2>/dev/null || true
fi

install -d -m 0755 /usr/libexec/kinect-one-remold /usr/share/kinect-one-remold/maintenance /var/lib/kinect-one-remold
install -m 0755 "$BIN" /usr/libexec/kinect-one-remold/kinect-one-remold
# Keep a self-contained maintenance snapshot outside the repository, mirroring
# the installed-runtime model used by the Kinect Remold Xbox 360 module. When Repair is
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
stage '[2/4] Installing device access policy...'
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

stage '[3/4] Registering and starting runtime service...'
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=045e 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true
systemctl enable --quiet kinect-one-remold.service
systemctl restart kinect-one-remold.service

stage '[4/4] Verifying installed runtime...'
if [[ "${REMOLD_GUI:-0}" != 1 ]]; then printf '\nVerifying Kinect Remold status...\n'; fi
if systemctl is-active --quiet kinect-one-remold.service; then
  printf '%s\n' 'Runtime service: RUNNING'
  # systemd may briefly expose systemd-executor as MainPID between fork and
  # execve(). Wait for the service process to settle on the installed runtime
  # instead of turning that harmless transition into a false installation failure.
  service_pid=''; service_exe=''; service_cwd=''
  for _ in {1..40}; do
    service_pid="$(systemctl show -p MainPID --value kinect-one-remold.service 2>/dev/null || true)"
    if [[ "$service_pid" =~ ^[1-9][0-9]*$ ]]; then
      service_exe="$(readlink -f "/proc/$service_pid/exe" 2>/dev/null || true)"
      service_cwd="$(readlink -f "/proc/$service_pid/cwd" 2>/dev/null || true)"
      if [[ "$service_exe" == /usr/libexec/kinect-one-remold/kinect-one-remold && "$service_cwd" == /var/lib/kinect-one-remold ]]; then break; fi
    fi
    sleep 0.05
  done
  [[ "$service_pid" =~ ^[1-9][0-9]*$ ]] || { echo 'Runtime service has no live process.' >&2; exit 3; }
  [[ "$service_exe" == /usr/libexec/kinect-one-remold/kinect-one-remold ]] || { echo "Runtime service is not executing the installed system binary: ${service_exe:-unknown}" >&2; exit 3; }
  [[ "$service_cwd" == /var/lib/kinect-one-remold ]] || { echo "Runtime service is not using its installed state directory: ${service_cwd:-unknown}" >&2; exit 3; }
  case "$service_exe:$service_cwd" in
    "$BUNDLE"*) echo 'Runtime service is attached to the build/distribution tree.' >&2; exit 3 ;;
  esac
  if [[ -n "${PROJECT:-}" ]]; then
    case "$service_exe:$service_cwd" in
      "$PROJECT"*) echo 'Runtime service is attached to the repository tree.' >&2; exit 3 ;;
    esac
  fi
else
  printf '%s\n' 'Runtime service: NOT RUNNING' >&2
  systemctl --no-pager --full status kinect-one-remold.service || true
  exit 1
fi
printf 'Runtime path   : /usr/libexec/kinect-one-remold/kinect-one-remold\n'
if [[ -S /run/kinect-one-remold/sdk.sock ]]; then
  printf '%s\n' 'SDK socket: READY'
else
  printf '%s\n' 'SDK socket: NOT READY'
fi
if [[ "${REMOLD_GUI:-0}" != 1 ]]; then
  printf 'Source/repository tree is not required by the running service.\n'
fi
