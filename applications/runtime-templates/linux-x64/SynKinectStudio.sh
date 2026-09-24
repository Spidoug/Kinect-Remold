#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$0" ]] || chmod u+x "$0" 2>/dev/null || true
LOG_DIR="$HERE/logs"
LOG_FILE="$LOG_DIR/SynKinectStudio.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

show_gui_error(){
  local message="$1"
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 1
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title='SynKinect Studio' --width=520 --text="$message" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title 'SynKinect Studio' --error "$message" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v xmessage >/dev/null 2>&1; then
    xmessage -center "$message" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

fail(){
  local message="$1" code="${2:-1}"
  printf '[launcher] ERROR: %s\n' "$message" >>"$LOG_FILE" 2>/dev/null || true
  printf '%s\nLog: %s\n' "$message" "$LOG_FILE" >&2
  if [[ ! -t 2 ]]; then
    show_gui_error "$message

Log:
$LOG_FILE" || true
  fi
  exit "$code"
}

# Studio is always a desktop/user process. System changes are delegated to
# KINECT.sh, which requests administrator permission only when required.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  target_user="${REMOLD_CALLER_USER:-${SUDO_USER:-}}"
  if [[ -z "$target_user" && -n "${PKEXEC_UID:-}" ]] && command -v getent >/dev/null 2>&1; then
    target_user="$(getent passwd "$PKEXEC_UID" | awk -F: '$1!="root"{print $1;exit}')"
  fi
  if [[ -z "$target_user" || "$target_user" == root ]]; then
    fail 'SynKinect Studio must be started from the normal desktop user session.' 1
  fi
  uid="$(id -u "$target_user")"
  runtime_dir="/run/user/$uid"
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$target_user" -- env \
      DISPLAY="${DISPLAY:-:0}" \
      WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
      XAUTHORITY="${XAUTHORITY:-}" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}" \
      bash "$0" "$@"
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -u "$target_user" env \
      DISPLAY="${DISPLAY:-:0}" \
      WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
      XAUTHORITY="${XAUTHORITY:-}" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}" \
      bash "$0" "$@"
  fi
  fail 'Cannot drop administrator privileges because neither runuser nor sudo is available.' 1
fi

cd "$HERE" || fail "Could not enter the Studio directory: $HERE" 1
: >"$LOG_FILE" 2>/dev/null || fail "Could not create the Studio log: $LOG_FILE" 1
printf '[launcher] SynKinect Studio\n' >>"$LOG_FILE"

[[ -f "$HERE/lib/SynKinectStudio.jar" ]] || fail "SynKinectStudio.jar is missing from $HERE/lib." 1

JAVA="$HERE/java/bin/java"
if [[ -d "$HERE/java" ]]; then
  chmod u+x "$HERE"/java/bin/* "$HERE/java/lib/jspawnhelper" "$HERE/java/lib/jexec" 2>/dev/null || true
fi
if [[ ! -x "$JAVA" ]]; then
  JAVA="$(command -v java || true)"
fi
[[ -n "$JAVA" ]] || fail 'Java 17 or newer was not found. Rebuild the Studio with: bash scripts/linux/BUILD-STUDIO.sh' 1

version="$("$JAVA" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
feature="${version%%.*}"
if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
[[ "$feature" =~ ^[0-9]+$ && "$feature" -ge 17 ]] || fail "Java 17 or newer is required; found: ${version:-unknown}." 1

printf '[launcher] Java: %s\n' "$JAVA" >>"$LOG_FILE"
printf '[launcher] Java version: %s\n' "${version:-unknown}" >>"$LOG_FILE"

STUDIO_PID=""
start_java(){
  if command -v setsid >/dev/null 2>&1; then
    setsid "$JAVA" \
      -Dfile.encoding=UTF-8 \
      -cp "$HERE/lib/SynKinectStudio.jar:$HERE/lib/*" \
      SynKinectStudio "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    nohup "$JAVA" \
      -Dfile.encoding=UTF-8 \
      -cp "$HERE/lib/SynKinectStudio.jar:$HERE/lib/*" \
      SynKinectStudio "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  fi
  STUDIO_PID=$!
}

start_java "$@"
pid="$STUDIO_PID"
[[ "$pid" =~ ^[0-9]+$ ]] || fail 'The Studio process could not be created.' 1

# Do not report success merely because the process was forked. Most launcher,
# Java, display and native-library failures happen immediately.
sleep 1.2
if ! kill -0 "$pid" 2>/dev/null; then
  if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
  tail_text="$(tail -n 18 "$LOG_FILE" 2>/dev/null || true)"
  fail "SynKinect Studio failed during startup (exit $rc).

$tail_text" "${rc:-1}"
fi

disown "$pid" 2>/dev/null || true
printf '[launcher] Studio started (pid %s).\n' "$pid" >>"$LOG_FILE"
exit 0
