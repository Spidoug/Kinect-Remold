#!/usr/bin/env bash
# Motion-capture pipeline test (Linux/Windows-Git-Bash, no Kinect needed).
#
# Feeds synthetic SynSkeleton poses through BodyFrame -> MocapRetargeter and the
# VMC / OSC / JSON-UDP / WebSocket sinks and the BVH recorder, decoding every wire
# format with independent parsers. All sockets are bound to 127.0.0.1 on
# ephemeral ports. Prints RESULT: PASS or RESULT: FAIL.
#
#   tests/mocap-test/run-test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SKETCH="$ROOT/applications/processing/SynKinectStudio"
MODULE_API_SRC="$ROOT/applications/studio-module-sdk/src/main/java"
LIB="${REMOLD_BENCH_LIB:-$ROOT/binaries/linux/applications/SynKinectStudio/lib}"
core="$(ls "$LIB"/core-*.jar 2>/dev/null | head -1 || true)"
jogl="$(ls "$LIB"/jogl-all-*.jar 2>/dev/null | grep -v natives | head -1 || true)"
glue="$(ls "$LIB"/gluegen-rt-*.jar 2>/dev/null | grep -v natives | head -1 || true)"
[[ -n "$core" && -n "$jogl" && -n "$glue" ]] || { echo "Processing/JOGL jars not found in $LIB. Run scripts/linux/BUILD-STUDIO.sh first (or set REMOLD_BENCH_LIB)." >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/api" "$WORK/classes" "$WORK/bench"
javac -nowarn -encoding UTF-8 --release 17 -cp "$core" -d "$WORK/api" $(find "$MODULE_API_SRC" -name '*.java')
strip_bom(){ LC_ALL=C sed $'1s/^\xEF\xBB\xBF//' "$1"; }
{
  printf '%s\n' 'import processing.core.*;' 'import processing.data.*;' 'import processing.event.*;' 'import processing.opengl.*;'
  strip_bom "$SKETCH/SynKinectStudio.pde" | grep '^import ' || true
  printf '%s\n' 'public class SynKinectStudio extends PApplet {'
  strip_bom "$SKETCH/SynKinectStudio.pde" | sed '/^import /d'
  while IFS= read -r f; do strip_bom "$f" | sed '/^import /d'; done < <(find "$SKETCH" -maxdepth 1 -type f -name '*.pde' ! -name 'SynKinectStudio.pde' -print | sort -f)
  printf '%s\n' 'public static void main(String[] args){PApplet.main(SynKinectStudio.class.getName());}' '}'
} > "$WORK/SynKinectStudio.java"
CP="$core:$jogl:$glue:$WORK/api"
javac -nowarn -encoding UTF-8 --release 17 -cp "$CP" -d "$WORK/classes" "$WORK/SynKinectStudio.java"
javac -nowarn -encoding UTF-8 --release 17 -cp "$CP:$WORK/classes" -d "$WORK/bench" "$HERE/MocapHarness.java"
cd "$SKETCH"
java -Djava.awt.headless=true ${JOPTS:-} -cp "$CP:$WORK/classes:$WORK/bench" MocapHarness "$@"
