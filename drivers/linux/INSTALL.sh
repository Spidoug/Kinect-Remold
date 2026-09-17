#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="$(cd "$ROOT/../.." && pwd)"
while IFS= read -r -d '' script; do
  chmod u+x "$script" 2>/dev/null || true
done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -print0 2>/dev/null)

# Interactive desktop entry point: without arguments show the same control
# panel used after installation, including option 10 for SynKinect Studio.
# --direct preserves a scriptable install path for the menu and automation.
if [[ $# -eq 0 ]]; then
  exec bash "$ROOT/KINECT.sh"
fi
if [[ "${1:-}" == "--direct" ]]; then
  shift
fi
exec bash "$ROOT/source/scripts/install.sh" "$@"
