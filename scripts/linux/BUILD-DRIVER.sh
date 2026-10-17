#!/usr/bin/env bash
set -euo pipefail
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink -- "$SOURCE")"
  [[ "$TARGET" = /* ]] && SOURCE="$TARGET" || SOURCE="$DIR/$TARGET"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
find_project_root(){
  local current="$SCRIPT_DIR" parent depth=0
  while (( depth < 8 )); do
    if [[ -f "$current/VERSION" && -d "$current/drivers/modules" && -d "$current/applications/processing/SynKinectStudio" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
    ((depth++))
  done
  return 1
}
ROOT="$(find_project_root)" || { echo "Kinect Remold project root not found from: $SCRIPT_DIR" >&2; exit 2; }
MODULES="$ROOT/drivers/modules"
found=0
for module in "$MODULES"/*; do
  [[ -d "$module" && -f "$module/linux/BUILD.sh" ]] || continue
  found=1
  printf '[module] %s\n' "$(basename "$module")"
  bash "$module/linux/BUILD.sh" "$@"
done
(( found )) || { echo 'No Linux driver module build entry point was found.' >&2; exit 2; }
