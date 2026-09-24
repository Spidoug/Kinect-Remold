#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Some ZIP/extraction tools discard Unix executable bits.  The top-level launcher
# is commonly invoked as `bash Kinect-Xbox-360-Remold.sh`, so use that opportunity
# to heal all repository shell launchers before they are called later.
while IFS= read -r -d '' script; do
  chmod u+x "$script" 2>/dev/null || true
done < <(find "$ROOT" -type f -name '*.sh' -print0 2>/dev/null)
DRIVER_BUILD="$ROOT/scripts/linux/BUILD-DRIVER.sh"
STUDIO_BUILD="$ROOT/scripts/linux/BUILD-STUDIO.sh"
DRIVER_DIST="$ROOT/binaries/linux/drivers"
DRIVER_BIN="$DRIVER_DIST/bin"
DRIVER_LIBEXEC="$DRIVER_DIST/libexec/kinect360-remold"
STUDIO_HOME="$ROOT/binaries/linux/applications/SynKinectStudio"
STUDIO_LAUNCH="$STUDIO_HOME/SynKinectStudio.sh"
STATE_ROOT="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/kinect360-remold"
LOG_DIR="$STATE_ROOT/logs"
BUILD_LOG="$LOG_DIR/build.log"
FORCE_BUILD=0
BUILD_ONLY=0
args=()

for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_BUILD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    *) args+=("$arg") ;;
  esac
done

required=(
  "$DRIVER_BIN/kinect360-remoldctl"
  "$DRIVER_LIBEXEC/kinect360-remold-broker"
  "$DRIVER_LIBEXEC/kinect360-remold-camera"
  "$DRIVER_LIBEXEC/kinect360-remold-audio"
  "$DRIVER_LIBEXEC/kinect360-remold-v4l2"
  "$DRIVER_LIBEXEC/kinect360-remold-camera-ip"
  "$DRIVER_DIST/INSTALL.sh"
  "$DRIVER_DIST/UNINSTALL.sh"
  "$DRIVER_DIST/KINECT.sh"
  "$DRIVER_DIST/VERSION"
  "$DRIVER_DIST/support/udev/60-kinect360-remold.rules"
  "$DRIVER_DIST/support/systemd/kinect360-remold.target"
  "$DRIVER_DIST/support/config/remold.conf"
  "$DRIVER_DIST/support/firmware/UACFirmware-01.02.709.00"
  "$DRIVER_DIST/support/kernel/KERNEL-RELEASE"
  "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-VERSION"
  "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-SOURCE-SHA256"
  "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-MODULE-SHA256"
  "$DRIVER_DIST/support/kernel/$(uname -r)/v4l2loopback.ko"
  "$STUDIO_HOME/SynKinectStudio.sh"
  "$STUDIO_HOME/lib/SynKinectStudio.jar"
  "$STUDIO_HOME/java/bin/java"
)

ready=1
for file in "${required[@]}"; do
  [[ -e "$file" ]] || { ready=0; break; }
done
show_gui_error(){
  local message="$1"
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 1
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title='Kinect Xbox 360 Remold' --width=520 --text="$message" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title 'Kinect Xbox 360 Remold' --error "$message" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v xmessage >/dev/null 2>&1; then
    xmessage -center "$message" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

pause_failure(){
  if [[ -t 0 ]]; then
    printf '\nPress Enter to close: '
    IFS= read -r _ || true
  fi
}

fail(){
  local code="${2:-1}" message="$1"
  printf '\n============================================================\n' >&2
  printf ' FAILED\n' >&2
  printf '============================================================\n\n' >&2
  printf '%s\n' "$message" >&2
  [[ -n "${BUILD_LOG:-}" ]] && printf 'Build log: %s\n' "$BUILD_LOG" >&2
  if [[ ! -t 2 ]]; then
    show_gui_error "$message

Log: $BUILD_LOG" || true
  fi
  pause_failure
  exit "$code"
}

launch_studio(){
  if [[ ! -f "$STUDIO_LAUNCH" ]]; then
    printf 'ERROR: SynKinect Studio launcher was not found: %s\n' "$STUDIO_LAUNCH" >&2
    return 2
  fi
  chmod u+x "$STUDIO_LAUNCH" 2>/dev/null || true
  bash "$STUDIO_LAUNCH" "${args[@]}"
}

open_build_terminal(){
  local -a child=(env REMOLD_BUILD_TERMINAL=1 bash "$0" --rebuild)
  (( BUILD_ONLY )) && child+=(--build-only)
  child+=("${args[@]}")

  if command -v x-terminal-emulator >/dev/null 2>&1; then
    x-terminal-emulator -e "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal -- "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v konsole >/dev/null 2>&1; then
    konsole -e "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v mate-terminal >/dev/null 2>&1; then
    mate-terminal -- "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v kgx >/dev/null 2>&1; then
    kgx -- "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v kitty >/dev/null 2>&1; then
    kitty "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v alacritty >/dev/null 2>&1; then
    alacritty -e "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  if command -v xterm >/dev/null 2>&1; then
    xterm -e "${child[@]}" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

run_logged_stage(){
  local title="$1"; shift
  printf '\n------------------------------------------------------------\n'
  printf ' %s\n' "$title"
  printf '%s\n' '------------------------------------------------------------'
  "$@" 2>&1 | tee -a "$BUILD_LOG"
  local rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    printf '\nStage failed: %s (exit %d)\n' "$title" "$rc" | tee -a "$BUILD_LOG" >&2
    return "$rc"
  fi
  return 0
}

# Launch directly when the generated runtime is complete.
if (( ! FORCE_BUILD && ready )); then
  (( BUILD_ONLY )) && exit 0
  if launch_studio; then
    exit 0
  fi
  fail "SynKinect Studio could not be started. The generated runtime exists, but the launcher reported an error." 1
fi

[[ -f "$DRIVER_BUILD" && -f "$STUDIO_BUILD" ]] || \
  fail 'The project tree is incomplete. Extract the complete project to a normal folder and run the launcher again.' 2

# When launched from a graphical file manager, put only the build in a terminal.
# Errors remain visible there; a successful build starts Studio and then closes it.
if [[ ! -t 1 && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -z "${REMOLD_BUILD_TERMINAL:-}" ]]; then
  if open_build_terminal; then
    exit 0
  fi
  fail 'A build is required, but no supported terminal emulator was found. Install a desktop terminal or run: bash Kinect-Xbox-360-Remold.sh' 2
fi

mkdir -p "$LOG_DIR" || fail "Could not create the Linux build log directory: $LOG_DIR" 2
: > "$BUILD_LOG" || fail "Could not create the Linux build log: $BUILD_LOG" 2

{
  printf '%s\n' \
    '============================================================' \
    ' Kinect Xbox 360 Remold' \
    ' Building Linux driver/runtime and SynKinect Studio' \
    '============================================================' \
    '' \
    'One or more required binaries are missing, or a rebuild was requested.' \
    'The complete project will be compiled now.' \
    ''
} | tee -a "$BUILD_LOG"

if ! run_logged_stage 'Linux driver/runtime' bash "$DRIVER_BUILD" --clean; then
  fail 'Linux driver/runtime compilation failed. Review the error above; the window will remain open until you press Enter.' 1
fi

if ! run_logged_stage 'SynKinect Studio' env REMOLD_FULL_BUILD=1 bash "$STUDIO_BUILD"; then
  fail 'SynKinect Studio compilation failed. Review the error above; the window will remain open until you press Enter.' 1
fi

for file in "${required[@]}"; do
  if [[ ! -e "$file" ]]; then
    printf 'Missing build artifact: %s\n' "$file" | tee -a "$BUILD_LOG" >&2
    fail 'The build command finished, but one or more required Linux artifacts were not generated.' 1
  fi
done

printf '\nBuild completed successfully.\n' | tee -a "$BUILD_LOG"

if (( BUILD_ONLY )); then
  printf 'All Linux binaries are ready.\n'
  if [[ -n "${REMOLD_BUILD_TERMINAL:-}" && -t 0 ]]; then
    printf '\nPress Enter to close: '
    IFS= read -r _ || true
  fi
  exit 0
fi

printf 'Starting SynKinect Studio...\n' | tee -a "$BUILD_LOG"
if launch_studio; then
  printf 'SynKinect Studio started successfully.\n' | tee -a "$BUILD_LOG"
  exit 0
fi

fail 'Compilation completed, but SynKinect Studio could not be started. Review the Studio launcher log for the startup error.' 1
