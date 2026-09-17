#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../.." && pwd)"
while IFS= read -r -d '' script; do
  chmod u+x "$script" 2>/dev/null || true
done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -print0 2>/dev/null)
choose_log_dir(){
  local candidate="$PROJECT_ROOT/logs"
  if mkdir -p "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  candidate="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/kinect360-remold/logs"
  mkdir -p "$candidate"
  printf '%s' "$candidate"
}
LOG_DIR="$(choose_log_dir)"
LOG_FILE="$LOG_DIR/linux-driver-$(date +%Y%m%d-%H%M%S).log"

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

set +e
(
  set -Eeuo pipefail
  bash "$ROOT/source/scripts/build.sh" "${ARGS[@]}"
) 2>&1 | tee "$LOG_FILE"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
  echo
  echo '============================================================'
  echo " LINUX DRIVER BUILD FAILED - ERROR CODE $rc"
  echo '============================================================'
  echo "Full log: $LOG_FILE"
  echo 'The terminal will remain open so the error can be read.'
  pause_build_window
  exit "$rc"
fi

echo
echo '============================================================'
echo ' LINUX DRIVER BUILD FINISHED SUCCESSFULLY'
echo '============================================================'
echo "Full log: $LOG_FILE"
pause_build_window
exit 0
