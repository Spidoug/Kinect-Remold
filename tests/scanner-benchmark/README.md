# Scanner ground-truth benchmark

This tool measures the 3D Scanner's reconstruction quality without a Kinect, and makes it possible to check future changes for regressions.

`ScanHarness.java` renders a synthetic **Kinect Xbox 360** depth stream of an analytic scene: a figurine standing on a turntable plate, a table, and a wall behind it. It then feeds that stream to the **unmodified** Scanner pipeline (`processScanFrame()` → lightweight tracking/keyframes → explicit *Build Mesh* / *Refine HQ*) and compares the reconstructed result with the exact signed-distance ground truth. Dense fusion is intentionally absent during the capture phase.

## Sensor model

| Effect | Model |
|---|---|
| Geometry | Starts from the pipeline lens-corrected rays; `kinect360`/`stress` then add a small residual ray-calibration mismatch so renderer and reconstruction are not mathematically identical |
| Depth core | Structured-light disparity from a 7.5 cm IR baseline (f = 580 px), 1/8 px disparity quantisation and range-dependent axial noise (depth sigma grows approximately with z²) |
| Fixed-pattern error | Pixel-fixed disparity component, weak vertical striping and radial/image-position dependence |
| Temporal noise | Frame-correlated disparity drift plus weak row-correlated wobble; deterministic for a given seed |
| Calibration residual | The renderer and reconstruction no longer share a mathematically perfect camera: a small residual focal/principal-point/radial ray mismatch is injected |
| Missing data | IR projector shadows, grazing-angle failures, edge dropouts, sparse and clustered speckle holes |
| Edge failures | Some depth discontinuities become mixed foreground/background “flying pixels”, not only missing pixels |
| Accelerometer | Gravity in Kinect coordinates (819 counts/g), quantisation, bias and noise |
| Timing | 30 fps capture, sub-millisecond timestamp jitter, plus the Studio capture cadence (`fusion.maxFps`, adaptive interval, newest-frame worker) driven by measured tracking/keyframe processing time |


### Sensor profiles

The harness deliberately has three profiles so algorithm regressions can be separated from sensor-model difficulty:

* `kinect360` (**default**) – realistic first-generation Kinect structured-light imperfections.
* `ideal` – the older cleaner synthetic model. Useful only as a geometric/control baseline.
* `stress` – pessimistic Kinect-v1-like noise, edge failures and calibration residuals. A good robustness gate, but not a claim that every physical Kinect behaves this badly.

Select one with `-Dharness.sensor=...`. The random sequence remains deterministic for a fixed seed. The default numerical amplitudes are engineering approximations grounded in published Kinect-v1 error behaviour (not a cycle-accurate emulator): depth uncertainty grows roughly quadratically with range, and error also varies with image position / structured-light pattern.

## Scenarios

* `turntable [seconds]`: static Kinect 0.8 m from the figure, 15° downward tilt. The plate turns 10°/s (360° in 36 s).
* `fusion [seconds]`: hand-held 250° arc around the static figure at ~0.8 m, moving at ~12 cm/s, with height variation, roll and hand jitter.
* `focus`: fast deterministic idle-preview stress test. A stable 0.90 m subject is alternately crossed by a significant 0.65 m foreground mode; the temporal target/ROI must not hunt, jump or disappear before Scan.

Both start with 0.6 s of idle preview (as when the operator frames the subject before pressing **Scan**).

## Output

```
TRAJECTORY object-probe error: mean=… max=… | 45deg:… 90deg:…
BUILD MESH (… ms): tris=… | err mean=… p50=… p90=… p99=… >5mm=… | completeness @2mm=… @4mm=… @8mm=…
REFINE HQ  (… ms): …                                  (with -Dharness.hq=true)
```

* **err**: distance from each mesh vertex on the figure to the true surface.
* **shell95**: 95 % signed-distance shell thickness (p97.5 − p2.5). It is intentionally sensitive to duplicate/laminated surfaces even when mean absolute error still looks acceptable.
* **bias**: mean signed surface offset. A large value indicates the whole reconstruction is systematically inside/outside the true surface.
* **completeness @X mm**: fraction of the visible true surface with a mesh vertex within X mm.
* **TRAJECTORY**: pose error, measured as the displacement of points on the figure along the scan.

Meshes are written as OBJ to `binaries/benchmark/` (or to `HARNESS_OUT`).

## Running

The script needs the Processing/JOGL jars that `scripts/linux/BUILD-STUDIO.sh` stages:

```bash
tests/scanner-benchmark/run-benchmark.sh turntable        # ~40 s scene
tests/scanner-benchmark/run-benchmark.sh fusion           # ~30 s scene
tests/scanner-benchmark/run-benchmark.sh focus            # fast autofocus/ROI regression
JOPTS="-Dharness.sensor=ideal" tests/scanner-benchmark/run-benchmark.sh turntable 8
JOPTS="-Dharness.sensor=kinect360" tests/scanner-benchmark/run-benchmark.sh turntable 8
JOPTS="-Dharness.sensor=stress" tests/scanner-benchmark/run-benchmark.sh fusion 8
JOPTS="-Dharness.hq=true" tests/scanner-benchmark/run-benchmark.sh turntable
JOPTS="-Dharness.cfg=voxelSizeM=0.002,truncationM=0.006" tests/scanner-benchmark/run-benchmark.sh turntable
```

Other options: `-Dharness.verbose=true` (per-frame tracking diagnostics), `-Dharness.stopAfter=5` (stop early while keeping the real motion speed), and `bias` mode (`run-benchmark.sh bias 0`), which isolates TSDF model bias and tracking convergence from exact poses.

The independent `sensor-model-probe.py` needs no Processing/JOGL libraries and sanity-checks that the axial error grows with range and that `stress > kinect360 > ideal` in noise severity:

```bash
python tests/scanner-benchmark/sensor-model-probe.py
```

## Legacy reference results (September 2026 revision, pre-realistic-default)

| | Original code | Current |
|---|---|---|
| Turntable, 360°: frames fused | 2 of 387 | 242 of 243 |
| Turntable: Build Mesh mean / p90 / completeness @4 mm | no reconstruction | 1.2–1.3 mm / 2.5–2.7 mm / 99 % |
| Turntable: Refine HQ mean / p50 | – | 1.12 mm / 0.81 mm |
| Fusion, 250°: frames fused | 1 of 257 | 136–145 of 137–147 |
| Fusion: Build Mesh mean / p90 / completeness @4 mm | 3.9 mm / 6.8 mm / 11.5 % | 0.7–0.9 mm / 1.3–1.8 mm / 98 % |
| Fusion: Refine HQ mean / completeness @2 mm | – | 0.69 mm / 95 % |

Results vary slightly between runs, because the number of frames processed depends on the machine's processing time. These table values were measured before `kinect360` became the default sensor profile; keep them only as historical context and establish new machine-local baselines with the three-profile gate.


## Recommended regression gate

For scanner changes, run the same seed in `ideal`, `kinect360`, and `stress` and compare trajectory error, rejected frames, `shell95`, p90/p99 surface error and completeness. A change should not be accepted merely because its mean error improves in `ideal`; the important gate is that `kinect360` remains stable and the stress profile degrades gracefully rather than creating a second surface shell.

This model is intentionally more faithful than a clean ray tracer, but it is **not an exact Kinect 360 emulator**. Material-dependent IR reflectance, sunlight/other IR interference, per-device factory calibration, USB/driver behaviour and the exact PrimeSense correspondence firmware are not reproduced exactly. Final validation still requires captures from the physical Kinect.
