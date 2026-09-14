#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
choose_log_dir(){
  local candidate="$ROOT/logs"
  if mkdir -p "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  candidate="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/kinect360-remold/logs"
  mkdir -p "$candidate"
  printf '%s' "$candidate"
}
LOG_DIR="$(choose_log_dir)"
LOG_FILE="$LOG_DIR/build-linux-$(date +%Y%m%d-%H%M%S).log"

PAUSE_AT_END=0
if [[ "${REMOLD_NO_PAUSE:-0}" != 1 && -t 1 && -r /dev/tty ]]; then
  PAUSE_AT_END=1
fi

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-pause) PAUSE_AT_END=0 ;;
    *) ARGS+=("$arg") ;;
  esac
done

pause_build_window(){
  (( PAUSE_AT_END )) || return 0
  printf '\nPress Enter to close this build window...'
  IFS= read -r _ </dev/tty || true
}

resolved_driver_dist(){
  if [[ -n "${REMOLD_DIST_DIR:-}" ]]; then printf '%s' "$REMOLD_DIST_DIR"; return 0; fi
  local arch project_dist state_file saved
  arch="$(uname -m)"
  project_dist="$ROOT/.cache/linux-driver/dist/$arch"
  if [[ -x "$project_dist/bin/kinect360-remoldctl" ]]; then printf '%s' "$project_dist"; return 0; fi
  state_file="${HOME:-/tmp}/.local/state/kinect360-remold/linux-driver-dist-$arch.path"
  if [[ -r "$state_file" ]]; then
    IFS= read -r saved < "$state_file" || true
    if [[ -n "$saved" ]]; then printf '%s' "$saved"; return 0; fi
  fi
  printf '%s' "$project_dist"
}

build_all(){
  set -Eeuo pipefail
  echo '============================================================'
  echo ' Kinect Xbox 360 Remold v1.0'
  echo ' BUILD - SynKinect Studio + Linux Driver and Runtime'
  echo '============================================================'
  echo "Log: $LOG_FILE"
  echo

  echo '[1/2] Building self-contained SynKinect Studio...'
  REMOLD_NO_PAUSE=1 bash "$ROOT/scripts/linux/BUILD-STUDIO.sh"

  echo
  echo '[2/2] Building Linux native driver/runtime...'
  REMOLD_NO_PAUSE=1 bash "$ROOT/scripts/linux/BUILD-DRIVER.sh" --clean "${ARGS[@]}"

  echo
  echo '============================================================'
  echo ' BUILD FINISHED SUCCESSFULLY'
  echo '============================================================'
  echo "Studio: $ROOT/applications/binaries/linux-x64"
  echo "Driver: $(resolved_driver_dist)"
}

set +e
(
  build_all
) 2>&1 | tee "$LOG_FILE"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
  echo
  echo '============================================================'
  echo " BUILD FAILED - ERROR CODE $rc"
  echo '============================================================'
  echo "Full log: $LOG_FILE"
  echo 'The terminal will remain open so the error can be read.'
  pause_build_window
  exit "$rc"
fi

printf '\nFull log: %s\n' "$LOG_FILE"
pause_build_window
exit 0
