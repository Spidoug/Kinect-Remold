#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '[module] Kinect Remold — Xbox One'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/source" && pwd)"
USER_HOME="${HOME:-}"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || USER_HOME="/tmp"
CACHE_ROOT="${REMOLD_CACHE_ROOT:-${XDG_CACHE_HOME:-$USER_HOME/.cache}/Kinect Remold}"
BUILD="$CACHE_ROOT/build/linux/drivers/kinect-one-remold"
CLEAN=0

for arg in "$@"; do
  case "$arg" in
    --clean|--rebuild) CLEAN=1 ;;
    *)
      printf 'Unknown build option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# The build directory intentionally lives outside the source tree.  A previous
# checkout/extraction may therefore leave a CMake cache containing an absolute
# source path that no longer exists.  --clean must remove it, and a relocated
# source tree must invalidate it automatically even without --clean.
if (( CLEAN )); then
  rm -rf -- "$BUILD"
elif [[ -f "$BUILD/CMakeCache.txt" ]]; then
  cached_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$BUILD/CMakeCache.txt" | tail -n 1)"
  if [[ -n "$cached_source" && "$cached_source" != "$SOURCE" ]]; then
    printf 'Discarding stale CMake cache from: %s\n' "$cached_source"
    rm -rf -- "$BUILD"
  fi
fi

cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"

OUT="$ROOT/binaries/linux/drivers/kinect-one-remold"
if ! mkdir -p -- "$OUT"; then
  printf 'ERROR: cannot create binary output inside the repository: %s\n' "$OUT" >&2
  printf 'Repository root: %s\n' "$ROOT" >&2
  printf 'Current user: %s\n' "$(id -un)" >&2
  printf 'If this checkout was previously built with sudo/root, repair its ownership and rebuild.\n' >&2
  exit 13
fi
cp "$BUILD/kinect-one-remold" "$OUT/"
cp "$(dirname "$0")/KINECT.sh" "$(dirname "$0")/INSTALL.sh" "$(dirname "$0")/UNINSTALL.sh" "$OUT/"
cp "$SOURCE/90-kinect-one-remold.rules" "$SOURCE/kinect-one-remold.service" "$OUT/"
chmod +x "$OUT/kinect-one-remold" "$OUT/KINECT.sh" "$OUT/INSTALL.sh" "$OUT/UNINSTALL.sh"
