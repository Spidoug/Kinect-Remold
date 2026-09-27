#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '============================================================'
printf '%s\n' ' Kinect One Remold - Linux build'
printf '%s\n' ' by Douglas Santana - @spidoug'
printf '%s\n' '============================================================'
printf '\n'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
USER_HOME="${HOME:-}"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || USER_HOME="/tmp"
CACHE_ROOT="${REMOLD_CACHE_ROOT:-${XDG_CACHE_HOME:-$USER_HOME/.cache}/Kinect Remold}"
BUILD="$CACHE_ROOT/build/linux/drivers/kinect-one-remold"
cmake -S "$(dirname "$0")/source" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"
OUT="$ROOT/binaries/linux/drivers/kinect-one-remold"
mkdir -p "$OUT"
cp "$BUILD/kinect-one-remold" "$OUT/"
cp "$(dirname "$0")/KINECT.sh" "$(dirname "$0")/INSTALL.sh" "$(dirname "$0")/UNINSTALL.sh" "$OUT/"
cp "$(dirname "$0")/source/90-kinect-one-remold.rules" "$(dirname "$0")/source/kinect-one-remold.service" "$OUT/"
chmod +x "$OUT/kinect-one-remold" "$OUT/KINECT.sh" "$OUT/INSTALL.sh" "$OUT/UNINSTALL.sh"
