# Depth calibration ground-truth benchmark

This tool measures the metric depth calibration (Sensor Calibration window) without a Kinect and checks future changes for regressions.

`CalibHarness.java` synthesises flat-wall captures from a **Kinect Xbox 360**-like depth camera, drives them through the **unmodified** `DepthCalibrationSession` exactly as the calibration window does (without Swing), and compares the corrected depth of held-out planes with ground truth. The legacy per-pixel affine method (profile v2) is reproduced verbatim from the previous implementation for comparison.

## Sensor and distortion model

| Effect | Model |
|---|---|
| Geometry | The pipeline's own undistorted depth rays (`Calibration.rays()`, `config.properties` intrinsics) |
| Depth | Raw 11-bit disparity, `z = 1/(3.33 − 0.00307·raw)`, integer quantisation |
| Global scale | Measured depth = 1.02 × true depth (not observable from planes alone) |
| Spatial distortion | Herrera-style `D(u,v)·exp(−α₁·(raw − raw(0.7 m)))` in raw disparity units: radial bowl + low-frequency pattern, decaying with distance |
| Fixed pattern | Per-pixel static bias, σ = 0.1 raw units |
| Noise | Per frame, σ_w = 1.4·10⁻³ m⁻¹ (σ_z ≈ 1.4·10⁻³·z² m), 1 % dropouts, random holes, finite 4.4 × 3.2 m wall |

Calibration: 8 stations at 0.7–3.5 m with random tilts up to ±20°, 30 frames per station (default). Evaluation: 12 held-out planes at random distances (0.75–3.45 m) and tilts, 30-frame averages. Tape references carry σ = 2 mm error.

## Usage

```
tests/calibration-benchmark/run-benchmark.sh [seed=7] [testPlanes=12]
JOPTS="-Dcal.frames=18" tests/calibration-benchmark/run-benchmark.sh     # frames per station
JOPTS="-Dcal.rho=0.3"   tests/calibration-benchmark/run-benchmark.sh     # fixed regularisation
```

The harness also runs self-checks: profile v3 save/load round-trip, legacy v2 load, `projectDepth(deproject(u,v))` round-trip and identity correction without a profile.

## Results

Error of corrected depth against ground truth on held-out planes, mm (seed 7). *Scale-free* removes the best single global scale factor, i.e. it measures the shape error that plane-only calibration can observe.

| Method | RMS | MAE | p95 | RMS < 1.5 m | RMS 1.5–2.5 m | RMS > 2.5 m | RMS, scale-free |
|---|---|---|---|---|---|---|---|
| Raw (no correction) | 42.26 | 39.24 | 65.50 | 22.53 | 43.89 | 58.86 | 6.15 |
| Old per-pixel affine (v2) | 34.53 | 30.86 | 58.02 | 24.44 | 34.48 | 46.14 | 21.88 |
| New grid, no reference | 41.23 | 38.72 | 60.97 | 22.18 | 43.01 | 56.99 | **2.39** |
| New grid, 1 tape reference | **3.83** | 3.04 | 7.63 | 1.84 | 3.89 | 5.60 | 2.39 |
| New grid, 2 tape references | **2.66** | 2.04 | 5.36 | 1.65 | 2.40 | 4.11 | 2.65 |

Seeds 11 and 23 give the same picture. Scale-free RMS is raw 5.96 / 6.33, old affine 22.42 / 25.66, new 2.32 / 2.50 mm. Absolute RMS with one reference is 5.93 / 2.56 mm, and with two references 3.61 / 2.84 mm.

Reading the table:

* Without an absolute reference, neither method can recover the 2 % global scale, so absolute error stays near the raw value. The old affine fit lowers absolute RMS only by accident: it distorts shape to 3–4× the raw error.
* The new model reduces shape error to about 40 % of raw. The remaining ~2.4 mm is mostly temporal noise, quantisation and the fixed per-pixel pattern, which a smooth model deliberately does not fit.
* One tape-measured distance removes the scale error. Two references at different distances also estimate a disparity offset.

Leave-one-station-out planarity RMS reported by the window, averaged over the stations: 7.70 → 3.53 mm. The fit takes about 3 s on a 2-core machine; it runs on a background thread and its folds run in parallel.
