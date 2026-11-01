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
ENV_HELPER="${REMOLD_ENV_HELPER:-$BUNDLE/remold-env.sh}"
if [[ ! -r "$ENV_HELPER" && -n "${PROJECT:-}" ]]; then ENV_HELPER="$PROJECT/scripts/linux/lib/remold-env.sh"; fi
[[ -r "$ENV_HELPER" ]] || { echo "Kinect Remold environment resolver is missing: $ENV_HELPER" >&2; exit 2; }
source "$ENV_HELPER"
remold_install_paths || { echo 'Could not resolve Linux installation directories.' >&2; exit 2; }
MODULE_ID='kinect-one-remold'
RUNTIME_DIR="$REMOLD_LIBEXECDIR/$MODULE_ID"
DATA_DIR="$REMOLD_DATADIR/$MODULE_ID"
MAINT_DIR="$DATA_DIR/maintenance"
STATE_DIR="$REMOLD_LOCALSTATEDIR/$MODULE_ID"
RUN_DIR="$REMOLD_RUNDIR/$MODULE_ID"
CONTROL_PATH="$REMOLD_BINDIR/kinect-one-remoldctl"
RULE_PATH="$REMOLD_UDEV_RULES_DIR/90-kinect-one-remold.rules"
SERVICE_PATH="$REMOLD_SYSTEMD_UNIT_DIR/kinect-one-remold.service"

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

install -d -m 0755 "$RUNTIME_DIR" "$MAINT_DIR" "$STATE_DIR" "$(dirname "$CONTROL_PATH")" "$(dirname "$RULE_PATH")" "$(dirname "$SERVICE_PATH")"
install -m 0755 "$BIN" "$RUNTIME_DIR/kinect-one-remold"
# Keep a self-contained maintenance snapshot outside the repository, mirroring
# the installed-runtime model used by the Kinect Remold Xbox 360 module. When Repair is
# invoked from that installed snapshot, do not copy files onto themselves.
if [[ "$(readlink -f "$BUNDLE")" != "$(readlink -m "$MAINT_DIR")" ]]; then
  install -m 0755 "$BIN" "$MAINT_DIR/kinect-one-remold"
  install -m 0755 "$BUNDLE/INSTALL.sh" "$MAINT_DIR/INSTALL.sh"
  install -m 0755 "$CONTROL" "$MAINT_DIR/KINECT.sh"
  install -m 0755 "$UNINSTALL" "$MAINT_DIR/UNINSTALL.sh"
  install -m 0644 "$RULE" "$MAINT_DIR/90-kinect-one-remold.rules"
  install -m 0644 "$SERVICE" "$MAINT_DIR/kinect-one-remold.service"
  install -m 0755 "$ENV_HELPER" "$MAINT_DIR/remold-env.sh"
fi
install -m 0755 "$CONTROL" "$CONTROL_PATH"
install -m 0755 "$ENV_HELPER" "$REMOLD_BINDIR/kinect-remold-env.sh"
stage '[2/4] Installing device access policy...'
install -m 0644 "$RULE" "$RULE_PATH"
SERVICE_RENDERED="$(mktemp)"
trap 'rm -f "$SERVICE_RENDERED"' EXIT
sed -e "s|@REMOLD_LIBEXEC_DIR@|$RUNTIME_DIR|g" -e "s|@REMOLD_STATE_DIR@|$STATE_DIR|g" "$SERVICE" > "$SERVICE_RENDERED"
install -m 0644 "$SERVICE_RENDERED" "$SERVICE_PATH"

verify_file(){
  local source="$1" installed="$2"
  cmp -s "$source" "$installed" || { echo "Installed runtime verification failed: $installed" >&2; exit 3; }
}
verify_file "$BIN" "$RUNTIME_DIR/kinect-one-remold"
verify_file "$RULE" "$RULE_PATH"
verify_file "$SERVICE_RENDERED" "$SERVICE_PATH"
verify_file "$CONTROL" "$CONTROL_PATH"

# A service must never point back into the repository/build tree.
exec_start="$(awk -F= '$1=="ExecStart"{print $2;exit}' "$SERVICE_PATH")"
[[ "$exec_start" == "$RUNTIME_DIR/kinect-one-remold" ]] || {
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
      if [[ "$service_exe" == "$RUNTIME_DIR/kinect-one-remold" && "$service_cwd" == "$STATE_DIR" ]]; then break; fi
    fi
    sleep 0.05
  done
  [[ "$service_pid" =~ ^[1-9][0-9]*$ ]] || { echo 'Runtime service has no live process.' >&2; exit 3; }
  [[ "$service_exe" == "$RUNTIME_DIR/kinect-one-remold" ]] || { echo "Runtime service is not executing the installed system binary: ${service_exe:-unknown}" >&2; exit 3; }
  [[ "$service_cwd" == "$STATE_DIR" ]] || { echo "Runtime service is not using its installed state directory: ${service_cwd:-unknown}" >&2; exit 3; }
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
printf 'Runtime path   : %s\n' "$RUNTIME_DIR/kinect-one-remold"
if [[ -S "$RUN_DIR/sdk.sock" ]]; then
  printf '%s\n' 'SDK socket: READY'
else
  printf '%s\n' 'SDK socket: NOT READY'
fi
if [[ "${REMOLD_GUI:-0}" != 1 ]]; then
  printf 'Source/repository tree is not required by the running service.\n'
fi
