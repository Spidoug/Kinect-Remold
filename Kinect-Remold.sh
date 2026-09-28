#!/usr/bin/env bash
set -Euo pipefail
umask 022

# Resolve the real launcher location first. This keeps direct execution stable
# through desktop/file-manager symlinks and arbitrary parent directory names.
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)" || exit 2
  LINK_TARGET="$(readlink -- "$SOURCE")" || exit 2
  if [[ "$LINK_TARGET" = /* ]]; then
    SOURCE="$LINK_TARGET"
  else
    SOURCE="$SOURCE_DIR/$LINK_TARGET"
  fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)" || exit 2
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$SOURCE")"

is_project_root(){
  local dir="$1"
  [[ -f "$dir/VERSION" \
     && -f "$dir/scripts/linux/BUILD-DRIVER.sh" \
     && -f "$dir/scripts/linux/BUILD-STUDIO.sh" \
     && -d "$dir/applications/processing/SynKinectStudio" \
     && -d "$dir/drivers/modules" ]]
}

find_project_root(){
  local current="$SCRIPT_DIR" parent version_file candidate
  local depth=0

  # Normal case plus wrapper directories created by repeated archive/extract cycles.
  while (( depth < 8 )); do
    if is_project_root "$current"; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
    ((depth++))
  done

  # Also tolerate the launcher being placed in an outer archive directory while
  # the actual project tree is nested several levels below it. Choose the first
  # complete tree only; incomplete extracted copies are ignored.
  while IFS= read -r -d '' version_file; do
    candidate="$(dirname "$version_file")"
    if is_project_root "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 6 -type f -name VERSION -print0 2>/dev/null)
  return 1
}

ROOT="$(find_project_root)" || {
  printf 'Kinect Remold project tree was not found near: %s\n' "$SCRIPT_DIR" >&2
  printf 'Extract the complete archive and run Kinect-Remold.sh again.\n' >&2
  exit 2
}

# Repair executable bits if an archive utility dropped them. The distributed
# archive already stores these files as 0755, so this is only a recovery path.
while IFS= read -r -d '' script; do
  chmod u+x "$script" 2>/dev/null || true
done < <(find "$ROOT" -type f -name '*.sh' -print0 2>/dev/null)
DRIVER_BUILD="$ROOT/scripts/linux/BUILD-DRIVER.sh"
STUDIO_BUILD="$ROOT/scripts/linux/BUILD-STUDIO.sh"
DRIVER_DIST="$ROOT/binaries/linux/drivers/kinect-xbox-360-remold"

K1_DIST="$ROOT/binaries/linux/drivers/kinect-one-remold"
DRIVER_BIN="$DRIVER_DIST/bin"
DRIVER_LIBEXEC="$DRIVER_DIST/libexec/kinect360-remold"
STUDIO_HOME="$ROOT/binaries/linux/applications/SynKinectStudio"
STUDIO_LAUNCH="$STUDIO_HOME/SynKinectStudio.sh"
USER_HOME="${HOME:-}"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || USER_HOME="/tmp"
STATE_ROOT="${XDG_STATE_HOME:-$USER_HOME/.local/state}/Kinect Remold"
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
  "$K1_DIST/kinect-one-remold"
  "$K1_DIST/KINECT.sh"
  "$K1_DIST/INSTALL.sh"
  "$K1_DIST/UNINSTALL.sh"
  "$K1_DIST/90-kinect-one-remold.rules"
  "$K1_DIST/kinect-one-remold.service"
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
    zenity --error --title='Kinect Remold' --width=520 --text="$message" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title 'Kinect Remold' --error "$message" >/dev/null 2>&1 || true
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
  local -a child=(env REMOLD_BUILD_TERMINAL=1 bash "$SCRIPT_PATH" --rebuild)
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

ensure_repo_binary_output(){
  local binaries_root="$ROOT/binaries"
  local path probe
  local -a destinations=(
    "$binaries_root"
    "$ROOT/binaries/linux"
    "$ROOT/binaries/linux/drivers"
    "$ROOT/binaries/linux/applications"
    "$DRIVER_DIST"
    "$K1_DIST"
    "$STUDIO_HOME"
  )

  if [[ -L "$binaries_root" ]]; then
    printf 'ERROR: repository binary output must be a real directory, not a symlink: %s\n' "$binaries_root" | tee -a "$BUILD_LOG" >&2
    return 1
  fi
  if [[ -e "$binaries_root" && ! -d "$binaries_root" ]]; then
    printf 'ERROR: repository binary output path is not a directory: %s\n' "$binaries_root" | tee -a "$BUILD_LOG" >&2
    return 1
  fi

  for path in "${destinations[@]}"; do
    if ! mkdir -p -- "$path" 2>>"$BUILD_LOG"; then
      printf 'ERROR: cannot create repository binary output directory: %s\n' "$path" | tee -a "$BUILD_LOG" >&2
      printf 'The repository must be writable by the current user (%s).\n' "$(id -un)" | tee -a "$BUILD_LOG" >&2
      printf 'Current permissions:\n' | tee -a "$BUILD_LOG" >&2
      ls -ld -- "$ROOT" "$binaries_root" "$(dirname "$path")" 2>/dev/null | tee -a "$BUILD_LOG" >&2 || true
      printf 'If this checkout was previously created or built with sudo/root, repair its ownership and run again.\n' | tee -a "$BUILD_LOG" >&2
      printf 'Suggested command: sudo chown -R %q:%q %q\n' "$(id -un)" "$(id -gn)" "$ROOT" | tee -a "$BUILD_LOG" >&2
      return 1
    fi

    probe="$path/.kinect-remold-write-test.$$"
    if ! ( umask 077; : > "$probe" ) 2>>"$BUILD_LOG"; then
      printf 'ERROR: repository binary output directory is not writable: %s\n' "$path" | tee -a "$BUILD_LOG" >&2
      ls -ld -- "$path" 2>/dev/null | tee -a "$BUILD_LOG" >&2 || true
      printf 'Suggested command: sudo chown -R %q:%q %q\n' "$(id -un)" "$(id -gn)" "$ROOT" | tee -a "$BUILD_LOG" >&2
      return 1
    fi
    rm -f -- "$probe"
  done
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
  fail 'A build is required, but no supported terminal emulator was found. Install a desktop terminal or run: ./Kinect-Remold.sh' 2
fi

mkdir -p "$LOG_DIR" || fail "Could not create the Linux build log directory: $LOG_DIR" 2
: > "$BUILD_LOG" || fail "Could not create the Linux build log: $BUILD_LOG" 2

{
  printf '%s\n' \
    '============================================================' \
    ' Kinect Remold' \
    ' by Douglas Santana - @spidoug' \
    '============================================================' \
    '' \
    'Building Linux driver/runtime and SynKinect Studio' \
    '' \
    'One or more required binaries are missing, or a rebuild was requested.' \
    'The complete project will be compiled now.' \
    ''
} | tee -a "$BUILD_LOG"

if ! ensure_repo_binary_output; then
  fail 'The repository binary output directory is not writable. Repair the permissions shown above and run Kinect-Remold.sh again.' 1
fi

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
