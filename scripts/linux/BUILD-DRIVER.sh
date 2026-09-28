#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULES="$ROOT/drivers/modules"
found=0
for module in "$MODULES"/*; do
  [[ -d "$module" && -f "$module/linux/BUILD.sh" ]] || continue
  found=1
  printf '[module] %s\n' "$(basename "$module")"
  bash "$module/linux/BUILD.sh" "$@"
done
(( found )) || { echo 'No Linux driver module build entry point was found.' >&2; exit 2; }
