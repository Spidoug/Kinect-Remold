#!/usr/bin/env bash
# SynKinect 3D Scanner ground-truth benchmark (Linux).
#
# Renders a synthetic Kinect Xbox 360 depth stream of an analytic scene, runs it
# through the unmodified Scanner pipeline and prints the reconstruction error
# against the exact surface. Needs the Processing/JOGL jars that
# scripts/linux/BUILD-STUDIO.sh stages into binaries/linux/applications/SynKinectStudio/lib.
#
#   tests/scanner-benchmark/run-benchmark.sh turntable [seconds=40]
#   tests/scanner-benchmark/run-benchmark.sh fusion    [seconds=30]
#
# Options through JOPTS, e.g. JOPTS="-Dharness.hq=true" (also run Refine HQ),
# "-Dharness.verbose=true", "-Dharness.cfg=voxelSizeM=0.002,truncationM=0.006".
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
javac -nowarn -encoding UTF-8 --release 17 -cp "$CP:$WORK/classes" -d "$WORK/bench" "$HERE/ScanHarness.java"
cd "$SKETCH"
java -Xmx6g -Djava.awt.headless=true -Dharness.out="${HARNESS_OUT:-$ROOT/binaries/benchmark}" ${JOPTS:-} -cp "$CP:$WORK/classes:$WORK/bench" ScanHarness "$@"
