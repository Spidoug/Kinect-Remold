#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
found=0
for module in "$ROOT/drivers/modules"/*; do
  [[ -d "$module" && -x "$module/linux/INSTALL.sh" ]] || continue
  found=1
  printf '[module] %s\n' "$(basename "$module")"
  bash "$module/linux/INSTALL.sh" "$@"
done
(( found )) || { echo 'No Linux driver module installer was found.' >&2; exit 2; }
