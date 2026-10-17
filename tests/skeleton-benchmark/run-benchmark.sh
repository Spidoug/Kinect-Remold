#!/usr/bin/env bash
# SynSkeleton ground-truth benchmark (Linux).
#
# Renders a synthetic Kinect Xbox 360 depth stream of an articulated person doing a
# sequence of poses (rest, T-pose, wave, reach, typing, crossed arms, knee raise,
# turn, arms overhead), runs every frame through the unmodified SynSkeleton session
# and prints the per-joint-group error against the exact joint positions.
#
#   tests/skeleton-benchmark/run-benchmark.sh [distanceM=2.6] [seed=3]
#
# Options through JOPTS, e.g.
#   JOPTS="-Dskel.fps=10"                     render/evaluate at 10 fps (faster)
#   JOPTS="-Dskel.solver=legacy"              previous Body3D solver, for comparison
#   JOPTS="-Dskel.scene=near -Dskel.camH=1.15 -Dskel.lookH=1.2" 1.6   close range
#   JOPTS="-Dskel.verbose=true -Dskel.stopAfter=12"
# Rendered frames are cached in $SKEL_CACHE (default binaries/benchmark/skelcache).
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
javac -nowarn -encoding UTF-8 --release 17 -cp "$CP:$WORK/classes" -d "$WORK/bench" "$HERE/SkeletonHarness.java"
CACHE="${SKEL_CACHE:-$ROOT/binaries/benchmark/skelcache}";mkdir -p "$CACHE"
cd "$SKETCH"
java -Xmx4g -Djava.awt.headless=true -Dskel.cache="$CACHE" ${JOPTS:-} -cp "$CP:$WORK/classes:$WORK/bench" SkeletonHarness "$@"
