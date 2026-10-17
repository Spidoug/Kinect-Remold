#!/usr/bin/env bash
# Unified Body3D regression suite.
# Runs the dependency-free viewport test always. When Processing/JOGL jars are
# available it also executes the real SynSkeleton, Interactivity and Mocap harnesses.
# Set ALLOW_MISSING_DEPS=1 to accept a PARTIAL result on source-only trees.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${REMOLD_BENCH_LIB:-$ROOT/binaries/linux/applications/SynKinectStudio/lib}"
ALLOW="${ALLOW_MISSING_DEPS:-0}"
fail=0
run(){ echo; echo "== $1 =="; shift; "$@" || { echo "FAILED: $1" >&2; fail=1; }; }
run "Body3D viewport/framing" "$ROOT/tests/body3d-viewport-benchmark/run-benchmark.sh"
core="$(ls "$LIB"/core-*.jar 2>/dev/null | head -1 || true)"
jogl="$(ls "$LIB"/jogl-all-*.jar 2>/dev/null | grep -v natives | head -1 || true)"
glue="$(ls "$LIB"/gluegen-rt-*.jar 2>/dev/null | grep -v natives | head -1 || true)"
if [[ -z "$core" || -z "$jogl" || -z "$glue" ]]; then
  echo
  echo "Processing/JOGL jars are not staged in: $LIB" >&2
  echo "Full SynSkeleton/Interactivity/Mocap execution requires BUILD-STUDIO first." >&2
  if [[ "$ALLOW" == "1" ]]; then
    echo "BODY3D SUITE RESULT: PARTIAL (viewport PASS; runtime harnesses skipped)"
    exit "$fail"
  fi
  echo "BODY3D SUITE RESULT: FAIL (runtime dependencies missing)"
  exit 2
fi
run "SynSkeleton + real shared Body3D viewport" env JOPTS="${SKEL_JOPTS:--Dskel.fps=10 -Dskel.cacheRevision=bodyview2}" "$ROOT/tests/skeleton-benchmark/run-benchmark.sh" "${SKEL_DISTANCE:-2.6}" "${SKEL_SEED:-3}"
run "Interactivity input pipeline" env JOPTS="${INTERACTION_JOPTS:-}" "$ROOT/tests/interaction-test/run-test.sh"
run "Motion Capture retarget/sinks" env JOPTS="${MOCAP_JOPTS:-}" "$ROOT/tests/mocap-test/run-test.sh"
if [[ "$fail" -eq 0 ]]; then echo; echo "BODY3D SUITE RESULT: PASS"; else echo; echo "BODY3D SUITE RESULT: FAIL"; fi
exit "$fail"
